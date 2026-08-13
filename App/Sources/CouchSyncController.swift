import Foundation
import NotableKit
import SwiftUI
import os

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
    /// The last significant disagreement between this iPad's clock and the server's (protocol §7),
    /// or nil. A warning, never a failure: sync runs normally throughout, and the message exists
    /// because a wrong clock changes *which version wins* a merge without anything looking broken.
    @Published private(set) var clockSkew: ClockSkew?
    /// Notebook tombstones the mass-deletion guard is holding, by document id (protocol §6.7).
    /// Published as the ids rather than a count because the settings screen answers for exactly
    /// this set: whatever else reaches the outbox while the user is deciding is not covered.
    @Published private(set) var heldDeletions: [String] = []
    /// Images referenced by synced pages that have not arrived, phrased for the settings footer, or
    /// nil. A note, never a failure: the notes and the ink are already here, and the store retries
    /// the blobs on every pull.
    @Published private(set) var assetWarning: String?

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

    /// The push loop's own backoff, deliberately separate from the feed loop's.
    ///
    /// The two fail independently, and the feed is the one that recovers first: a pull succeeds as
    /// soon as the network is back, while an outbox can keep failing for its own reasons — a
    /// document the server keeps rejecting, a rate limit that applies to writes. Sharing one
    /// counter meant every successful pull reset the push delay to a second, so a persistently
    /// failing outbox retried at full speed forever, which is precisely the request flood the
    /// backoff exists to prevent.
    private var pushBackoff: TimeInterval
    /// Whether the current `pushTask` is a scheduled retry rather than an edit timer. Only a retry
    /// may schedule another one, so an edit arriving mid-backoff replaces it with a normal push
    /// instead of adding a second timer.
    private var isRetryingPush = false

    private static let log = Logger(subsystem: "dev.ivan.bopa", category: "couch-sync")

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
        self.pushBackoff = retryFloor
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
        isRetryingPush = false
        // The backoff is deliberately *not* reset here. Stopping is what happens when sync is
        // switched off or the app backgrounds, and a device that comes straight back to a server
        // that is still rate-limiting it should not arrive at full speed.
        if status == .syncing { status = .idle }
    }

    // MARK: Push

    /// Signals a local edit. Coalesces: only the last call's timer survives, so a burst of
    /// autosaves while someone is writing costs one push once they stop.
    func noteEdited() {
        pushTask?.cancel()
        isRetryingPush = false
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

    /// Waits out the push backoff and tries the outbox again.
    ///
    /// Scheduled only after a flush that failed in a way waiting could fix. A terminal failure — a
    /// page the server will not accept at any size, a malformed request — leaves the documents
    /// queued and the message standing, but does not put the device in a retry loop that cannot
    /// end: the next edit, foreground, or manual "Sync now" tries again, by which point something
    /// may have changed.
    private func schedulePushRetry(after delay: TimeInterval) {
        pushTask?.cancel()
        isRetryingPush = true
        // Jitter so a household of devices that all lost the same Wi-Fi does not come back in
        // lockstep and rebuild the thundering herd the backoff exists to break up.
        let wait = delay * Double.random(in: 0.85...1.15)
        pushTask = Task { [weak self] in
            do {
                guard let sleeper = self?.sleeper else { return }
                try await sleeper(wait)
            } catch {
                return  // superseded by an edit, or cancelled by stop()
            }
            guard let self, !Task.isCancelled else { return }
            await self.pushNow()
        }
    }

    /// Pushes immediately — leaving the editor, backgrounding, reconnecting, or "Sync now".
    func pushNow() async {
        pushTask?.cancel()
        pushTask = nil
        let wasRetry = isRetryingPush
        isRetryingPush = false
        status = .syncing
        let report = await flush()
        pendingCount = report.stillDirty.count

        if report.failures.isEmpty {
            // Reset on a push that actually succeeded, and on nothing else. A successful *pull*
            // used to do it, which is how an outbox that had been failing for ten minutes went back
            // to retrying every second.
            pushBackoff = retryFloor
        } else if report.hasRetriableFailure {
            // The server's own answer wins when it gave one; §5 of the hardening plan, RFC 9110
            // §10.2.3. `CouchDBClient` has already clamped it to something sane.
            schedulePushRetry(after: report.retryAfter ?? pushBackoff)
            pushBackoff = min(pushBackoff * 2, retryCeiling)
        } else if wasRetry {
            // A retry that came back terminal: stop climbing, and let the next edit or foreground
            // start from the floor rather than from wherever this sequence had reached.
            pushBackoff = retryFloor
        }
        noteClockSkew(report.clockSkew)
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
        noteClockSkew(report.clockSkew)
        if !report.applied.isEmpty { lastSyncedAt = now() }
        if !report.conflictCopies.isEmpty {
            conflictCopies.append(contentsOf: report.conflictCopies)
        }
        noteAssetProblems(report)
        // A pull that returned at all clears any previous failure: the server is demonstrably
        // reachable again, whether or not it had anything to say.
        status = .idle
    }

    /// Images that have not arrived, as a note beside the status rather than as a failure.
    ///
    /// Deliberately not `.failed`: the notes and the ink are synced, and calling that a sync
    /// failure would have people waiting for a state that has already arrived — or worse, deleting
    /// and re-downloading a library over a picture that is still uploading from the other device.
    ///
    /// Assigned from each report rather than accumulated, and derived from the store's own list of
    /// what is missing, so a blob that lands on a later pull clears the message without anything
    /// having to remember it was set.
    private func noteAssetProblems(_ report: CouchSyncEngine.PullReport) {
        let corrupt = report.corruptAssets.count
        // A corrupt asset is recorded in both `corruptAssets` and `assetFailures`, so it is
        // subtracted back out rather than counted twice. A 404 is only in `missingAssets` — it is
        // not a failure, it is a peer that has not finished uploading.
        let waiting = report.missingAssets.count + max(0, report.assetFailures.count - corrupt)
        for (assetID, reason) in report.assetFailures {
            Self.log.warning("asset \(assetID, privacy: .public) unavailable: \(reason, privacy: .public)")
        }

        switch (waiting, corrupt) {
        case (0, 0):
            assetWarning = nil
        case (let waiting, 0):
            assetWarning = "\(waiting) image\(waiting == 1 ? "" : "s") still downloading. "
                + "Notes and ink are synced."
        case (_, let corrupt):
            // Distinct wording because this one does not fix itself by waiting: the bytes the
            // server holds do not match the name they are filed under.
            assetWarning = "\(corrupt) image\(corrupt == 1 ? "" : "s") could not be verified and "
                + "will be retried. Notes and ink are synced."
        }
    }

    /// Records a skew observation and logs the transitions.
    ///
    /// Only when it changes: the pull loop runs a request every few seconds, and a warning
    /// repeated on every lap buries the one line that matters. Clearing is logged too — that is
    /// the message saying the clock was fixed.
    private func noteClockSkew(_ skew: ClockSkew?) {
        guard skew != clockSkew else { return }
        clockSkew = skew
        if let skew {
            Self.log.warning(
                "Clock skew \(Int(skew.seconds))s vs server: \(skew.summary, privacy: .public)")
        } else {
            Self.log.notice("Clock skew back within tolerance")
        }
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case CouchError.unauthorized:
            return "Sync rejected the username or password."
        case CouchError.transport:
            return "Offline — changes are saved and will sync when you reconnect."
        case CouchError.server(let status, _, _) where status == 413:
            // The one terminal status with an answer the user can act on. Everything else in this
            // class is a server or configuration fault they can only report.
            return "A page is too large for the sync server to accept."
        case CouchError.server(let status, _, _):
            return status < 500
                ? "The sync server refused the request (\(status)). Check the sync settings."
                : "The sync server returned an error (\(status))."
        default:
            return String(describing: error)
        }
    }

    /// One-line status for the settings footer and the capsule.
    ///
    /// A skew warning rides along with whatever else is being said rather than replacing it: the
    /// sync is not failing, and the clock is not the reason anything is queued. It is the sentence
    /// that explains why the wrong version of a page may have won.
    ///
    /// The image note rides along on the same terms, and for the same reason — the ink is synced,
    /// so it must not replace a status that says so, and it must not read as a failure.
    var statusDetail: String? {
        let parts = [syncDetail, assetWarning, clockSkew?.summary].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private var syncDetail: String? {
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
