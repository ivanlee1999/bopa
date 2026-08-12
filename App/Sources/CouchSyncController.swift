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
    /// How many documents are still waiting in the engine's outbox.
    typealias Pending = @Sendable () async -> Int
    /// Answers the mass-deletion guard for a named set of tombstones — approve or discard.
    typealias ResolveDeletions = @Sendable ([String]) async -> Void
    typealias Sleeper = @Sendable (TimeInterval) async throws -> Void

    enum Status: Equatable {
        case idle
        case syncing
        /// Offline or rejected. `pending` says how much is waiting, which is the number that
        /// actually answers "have I lost anything?".
        case failed(String)
    }

    @Published private(set) var status: Status = .idle

    /// Mirrors `SyncCoordinator.isSyncing`, so the library's one sync button can ask the same
    /// question of either backend.
    var isSyncing: Bool {
        if case .syncing = status { return true }
        return false
    }

    @Published private(set) var pendingCount = 0
    @Published private(set) var lastSyncedAt: Date?
    /// Documents this build could not understand, materialized alongside the local copy.
    @Published private(set) var conflictCopies: [String] = []
    /// Notebook tombstones the mass-deletion guard is holding, by document id (protocol §6.7).
    /// Published as the ids rather than a count because the settings screen answers for exactly
    /// this set: whatever else reaches the outbox while the user is deciding is not covered.
    @Published private(set) var heldDeletions: [String] = []

    /// How long after the last edit to push. Short because a flush sends only the documents that
    /// changed — unlike the WebDAV engine, which re-sent a whole notebook and so needed 20s.
    private let editQuietPeriod: TimeInterval
    private let retryFloor: TimeInterval
    private let retryCeiling: TimeInterval
    /// Shortest gap between two change-feed requests that both came back with nothing.
    private let idleFloor: TimeInterval

    private let flush: Flush
    private let pull: Pull
    private let pending: Pending
    private let approveDeletions: ResolveDeletions
    private let discardDeletions: ResolveDeletions
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
        pull: @escaping Pull,
        pending: @escaping Pending = { 0 },
        approveDeletions: @escaping ResolveDeletions = { _ in },
        discardDeletions: @escaping ResolveDeletions = { _ in }
    ) {
        self.editQuietPeriod = editQuietPeriod
        self.retryFloor = retryFloor
        self.retryCeiling = retryCeiling
        self.idleFloor = idleFloor
        self.now = now
        self.sleeper = sleeper
        self.flush = flush
        self.pull = pull
        self.pending = pending
        self.approveDeletions = approveDeletions
        self.discardDeletions = discardDeletions
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
            pull: { longpoll in try await engine.pull(longpoll: longpoll) },
            pending: { await engine.pendingCount },
            approveDeletions: { await engine.approveHeldDeletions($0) },
            discardDeletions: { await engine.discardHeldDeletions($0) })
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
                    //
                    // The outbox is checked too, not just what this pull brought back. A pull that
                    // succeeds is the first proof the network returned, and edits made while it was
                    // gone are still sitting dirty from a flush that failed offline. Pushing only
                    // on `pushBack` would leave them there until the user typed something else or
                    // tapped Sync now — a reconnect has to drain the outbox, not merely deliver
                    // what the feed happened to carry.
                    let stillQueued = await self.pending()
                    if !report.pushBack.isEmpty || stillQueued > 0 { await self.pushNow() }

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
        // Always assigned, never merged: the guard re-decides from scratch on every flush, so a
        // set that is no longer held has been resolved — by the user, or by the deletions ceasing
        // to be most of the library — and offering the choice again would be offering it about
        // documents nothing is waiting on.
        heldDeletions = report.heldDeletions

        if report.blockedByDeletionGuard {
            status = .failed(Self.deletionGuardMessage(count: report.heldDeletions.count))
        } else if let firstFailure = report.failures.values.sorted().first {
            status = .failed(firstFailure)
        } else {
            lastSyncedAt = now()
            status = .idle
        }
    }

    /// Names both ways out and where they live. A warning about a batch the user cannot act on is
    /// worse than none: it reads as a fault to wait through, and the wait never ends.
    private static func deletionGuardMessage(count: Int) -> String {
        "Holding back \(count) notebook deletion\(count == 1 ? "" : "s") that would remove most of "
            + "this library. In Settings › Sync, choose “Delete them on the server too” or “Keep "
            + "them on the server”. Everything else is still syncing."
    }

    // MARK: Answering the mass-deletion guard

    /// "Delete them on the server too": the held batch goes out on the flush that follows, and the
    /// guard stays armed for everything else.
    func approveHeldDeletions() async {
        let ids = heldDeletions
        guard !ids.isEmpty else { return }
        await approveDeletions(ids)
        await pushNow()
    }

    /// "Keep them on the server": the tombstones are dropped instead of published. The notebooks
    /// are still on the server, so they return to this iPad on the next pull — which is what makes
    /// this the undo for a wiped device rather than merely a dismissal.
    func discardHeldDeletions() async {
        let ids = heldDeletions
        guard !ids.isEmpty else { return }
        await discardDeletions(ids)
        // Push rather than just clearing the banner: the outbox has changed, the guard has to
        // re-decide over what is left, and `pushNow` is the one place that reads its answer.
        await pushNow()
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
