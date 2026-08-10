import Foundation
import NotableKit
import SwiftUI

/// Drives CouchDB sync for the app: a debounced push after writing stops, and a change-feed
/// loop that keeps the library current while bopa is in the foreground.
///
/// Separate from `SyncCoordinator` rather than folded into it. That one is built around a WebDAV
/// run — a whole-tree reconcile with a report and a conflict list — while this is two independent
/// pumps over a document outbox. Keeping them apart also means WebDAV keeps working untouched
/// while the backend switch is still live.
@MainActor
final class CouchSyncController: ObservableObject {
    /// Pushes queued documents. Injectable so the pumps can be tested without a server.
    typealias Flush = @Sendable () async -> CouchSyncEngine.FlushReport
    /// Waits for the server to report a change, or returns when the wait times out.
    typealias Pull = @Sendable (_ longpoll: Bool) async throws -> CouchSyncEngine.PullReport
    typealias Sleeper = @Sendable (TimeInterval) async throws -> Void

    enum Status: Equatable {
        case idle
        case syncing
        /// Offline or rejected. `pending` says how much is waiting, which is the number that
        /// actually answers "have I lost anything?".
        case failed(String)
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var pendingCount = 0
    @Published private(set) var lastSyncedAt: Date?
    /// Documents this build could not understand, materialized alongside the local copy.
    @Published private(set) var conflictCopies: [String] = []

    /// How long after the last edit to push. Short because a flush sends only the documents that
    /// changed — unlike the WebDAV engine, which re-sent a whole notebook and so needed 20s.
    private let editQuietPeriod: TimeInterval
    private let retryFloor: TimeInterval
    private let retryCeiling: TimeInterval
    /// Shortest gap between two change-feed requests that both came back with nothing.
    private let idleFloor: TimeInterval

    private let flush: Flush
    private let pull: Pull
    private let sleeper: Sleeper
    private let now: @MainActor () -> Date

    private var pullTask: Task<Void, Never>?
    private var pushTask: Task<Void, Never>?

    init(
        editQuietPeriod: TimeInterval = 3,
        retryFloor: TimeInterval = 1,
        retryCeiling: TimeInterval = 60,
        idleFloor: TimeInterval = 0.5,
        now: @escaping @MainActor () -> Date = Date.init,
        sleeper: @escaping Sleeper = { try await Task.sleep(for: .seconds($0)) },
        flush: @escaping Flush,
        pull: @escaping Pull
    ) {
        self.editQuietPeriod = editQuietPeriod
        self.retryFloor = retryFloor
        self.retryCeiling = retryCeiling
        self.idleFloor = idleFloor
        self.now = now
        self.sleeper = sleeper
        self.flush = flush
        self.pull = pull
    }

    /// Wires the controller to a real engine.
    convenience init(
        engine: CouchSyncEngine,
        editQuietPeriod: TimeInterval = 3,
        sleeper: @escaping Sleeper = { try await Task.sleep(for: .seconds($0)) }
    ) {
        self.init(
            editQuietPeriod: editQuietPeriod,
            sleeper: sleeper,
            flush: { await engine.flush() },
            pull: { longpoll in try await engine.pull(longpoll: longpoll) })
    }

    var isRunning: Bool { pullTask != nil }

    // MARK: Lifecycle

    /// Starts the change-feed loop. Idempotent.
    ///
    /// Catches up with a plain request first, then holds a long poll open. The catch-up matters:
    /// the long poll only reports what happens *after* it starts, so entering it directly would
    /// miss everything that changed while bopa was closed.
    func start() {
        guard pullTask == nil else { return }
        pullTask = Task { [weak self] in
            var backoff = self?.retryFloor ?? 1
            var caughtUp = false
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    let report = try await self.pull(caughtUp)
                    caughtUp = true
                    backoff = self.retryFloor
                    self.apply(report)
                    // Anything the server lacked is now queued; send it without waiting for the
                    // edit timer, which will not fire because the user is not writing.
                    if !report.pushBack.isEmpty { await self.pushNow() }

                    // A long poll is supposed to block until something happens, so an empty
                    // result should be rare and slow. When it is neither — a proxy that answers
                    // immediately, a server that ignores the timeout — re-issuing at once turns
                    // this loop into a hot spin against the server. Pausing only in that case
                    // costs nothing when the feed behaves.
                    if report.applied.isEmpty && report.conflictCopies.isEmpty {
                        try await self.sleeper(self.idleFloor)
                    }
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    self.status = .failed(Self.describe(error))
                    // A dead connection should not become a request flood.
                    try? await self.sleeper(backoff)
                    backoff = min(backoff * 2, self.retryCeiling)
                }
            }
        }
    }

    func stop() {
        pullTask?.cancel()
        pullTask = nil
        pushTask?.cancel()
        pushTask = nil
        if status == .syncing { status = .idle }
    }

    // MARK: Push

    /// Signals a local edit. Coalesces: only the last call's timer survives, so a burst of
    /// autosaves while someone is writing costs one push once they stop.
    func noteEdited() {
        pushTask?.cancel()
        let quiet = editQuietPeriod
        pushTask = Task { [weak self] in
            do {
                guard let sleeper = self?.sleeper else { return }
                try await sleeper(quiet)
            } catch {
                return  // superseded by a later edit, or cancelled
            }
            guard let self, !Task.isCancelled else { return }
            await self.pushNow()
        }
    }

    /// Pushes immediately — leaving the editor, backgrounding, reconnecting, or "Sync now".
    func pushNow() async {
        pushTask?.cancel()
        pushTask = nil
        status = .syncing
        let report = await flush()
        pendingCount = report.stillDirty.count

        if report.blockedByDeletionGuard {
            status = .failed(
                "Refusing to delete \(report.stillDirty.count) notebooks at once. "
                    + "If that is really what you want, confirm in Sync settings.")
        } else if let firstFailure = report.failures.values.sorted().first {
            status = .failed(firstFailure)
        } else {
            lastSyncedAt = now()
            status = .idle
        }
    }

    /// One catch-up pass plus a push, for foregrounding and "Sync now" — no long poll, so it
    /// returns rather than waiting for someone else to write something.
    func syncNow() async {
        status = .syncing
        do {
            apply(try await pull(false))
        } catch {
            status = .failed(Self.describe(error))
            return
        }
        await pushNow()
    }

    private func apply(_ report: CouchSyncEngine.PullReport) {
        if !report.applied.isEmpty { lastSyncedAt = now() }
        if !report.conflictCopies.isEmpty {
            conflictCopies.append(contentsOf: report.conflictCopies)
        }
        // A pull that returned at all clears any previous failure: the server is demonstrably
        // reachable again, whether or not it had anything to say.
        status = .idle
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case CouchError.unauthorized:
            return "Sync rejected the username or password."
        case CouchError.transport:
            return "Offline — changes are saved and will sync when you reconnect."
        case CouchError.server(let status, _):
            return "The sync server returned an error (\(status))."
        default:
            return String(describing: error)
        }
    }

    /// One-line status for the settings footer and the capsule.
    var statusDetail: String? {
        switch status {
        case .syncing:
            return "Syncing…"
        case .failed(let message):
            return pendingCount > 0 ? "\(message) \(pendingCount) waiting to sync." : message
        case .idle:
            if pendingCount > 0 { return "\(pendingCount) waiting to sync" }
            guard let lastSyncedAt else { return nil }
            return "Last synced \(lastSyncedAt.formatted(.relative(presentation: .named)))"
        }
    }
}
