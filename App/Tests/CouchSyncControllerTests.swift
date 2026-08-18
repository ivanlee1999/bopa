import Foundation
import NotableKit
import XCTest

@testable import Bopa

@MainActor
final class CouchSyncControllerTests: XCTestCase {

    /// Stands in for the engine. Records calls, can block, and can be told to fail.
    private final class EngineSpy: @unchecked Sendable {
        private let lock = NSLock()
        private var _flushCount = 0
        private var _pullCalls: [Bool] = []
        private var _flushReport = CouchSyncEngine.FlushReport()
        private var _pullReport = CouchSyncEngine.PullReport()
        private var _pullError: Error?
        private var _pendingCount = 0

        var flushCount: Int { lock.withLock { _flushCount } }
        /// The `longpoll` flag of each pull, newest last.
        var pullCalls: [Bool] { lock.withLock { _pullCalls } }

        /// Documents left in the outbox — what a flush that failed while offline leaves behind.
        func setPendingCount(_ count: Int) { lock.withLock { _pendingCount = count } }
        func pendingCount() async -> Int { lock.withLock { _pendingCount } }

        func setFlushReport(_ report: CouchSyncEngine.FlushReport) {
            lock.withLock { _flushReport = report }
        }
        func setPullReport(_ report: CouchSyncEngine.PullReport) {
            lock.withLock { _pullReport = report }
        }
        func setPullError(_ error: Error?) { lock.withLock { _pullError = error } }

        func flush() async -> CouchSyncEngine.FlushReport {
            lock.withLock { _flushCount += 1; return _flushReport }
        }

        /// The ids each answer to the mass-deletion guard carried, newest last.
        private var _approved: [[String]] = []
        private var _discarded: [[String]] = []
        var approved: [[String]] { lock.withLock { _approved } }
        var discarded: [[String]] { lock.withLock { _discarded } }

        func approveDeletions(_ ids: [String]) async { lock.withLock { _approved.append(ids) } }
        func discardDeletions(_ ids: [String]) async { lock.withLock { _discarded.append(ids) } }

        func pull(longpoll: Bool) async throws -> CouchSyncEngine.PullReport {
            let (error, report): (Error?, CouchSyncEngine.PullReport) = lock.withLock {
                _pullCalls.append(longpoll)
                return (_pullError, _pullReport)
            }
            if let error { throw error }
            return report
        }
    }

    /// Runs the loops at test speed. Returns immediately for `allowedTicks` calls, then throws so
    /// a runaway loop fails fast instead of spinning.
    private final class FakeSleeper: @unchecked Sendable {
        private let lock = NSLock()
        private var remaining: Int
        private(set) var durations: [TimeInterval] = []

        init(allowedTicks: Int) { remaining = allowedTicks }

        func sleep(_ duration: TimeInterval) async throws {
            try lock.withLock {
                durations.append(duration)
                guard remaining > 0 else { throw CancellationError() }
                remaining -= 1
            }
        }

        var recorded: [TimeInterval] { lock.withLock { durations } }
    }

    private func makeController(
        engine: EngineSpy, sleeper: FakeSleeper, quiet: TimeInterval = 3
    ) -> CouchSyncController {
        CouchSyncController(
            editQuietPeriod: quiet,
            sleeper: { try await sleeper.sleep($0) },
            flush: { await engine.flush() },
            pull: { try await engine.pull(longpoll: $0) },
            pending: { await engine.pendingCount() },
            approveDeletions: { await engine.approveDeletions($0) },
            discardDeletions: { await engine.discardDeletions($0) })
    }

    // MARK: Push

    func testEditsCoalesceIntoASinglePush() async throws {
        let engine = EngineSpy()
        let sleeper = FakeSleeper(allowedTicks: 10)
        let controller = makeController(engine: engine, sleeper: sleeper)

        controller.noteEdited()
        controller.noteEdited()
        controller.noteEdited()
        // Each call cancels the previous timer, so only the last one survives.
        try await Task.sleep(for: .milliseconds(60))

        XCTAssertEqual(engine.flushCount, 1, "a burst of edits should cost one push")
    }

    func testPushNowSendsImmediatelyAndClearsAPendingTimer() async throws {
        let engine = EngineSpy()
        let sleeper = FakeSleeper(allowedTicks: 10)
        let controller = makeController(engine: engine, sleeper: sleeper)

        controller.noteEdited()
        await controller.pushNow()
        try await Task.sleep(for: .milliseconds(60))

        XCTAssertEqual(engine.flushCount, 1, "the debounced push should not also fire")
    }

    /// Offline is the normal case on an iPad, not an error state: work stays queued and the
    /// message says so rather than implying loss.
    func testOfflineLeavesWorkQueuedAndSaysSo() async {
        let engine = EngineSpy()
        var report = CouchSyncEngine.FlushReport()
        report.stillDirty = ["page:a", "page:b"]
        report.failures = ["page:a": "transport(offline)"]
        engine.setFlushReport(report)

        let controller = makeController(engine: engine, sleeper: FakeSleeper(allowedTicks: 10))
        await controller.pushNow()

        XCTAssertEqual(controller.pendingCount, 2)
        XCTAssertEqual(controller.statusDetail, "transport(offline) 2 waiting to sync.")
    }

    func testASuccessfulPushClearsPendingAndStamps() async {
        let engine = EngineSpy()
        var report = CouchSyncEngine.FlushReport()
        report.pushed = ["page:a"]
        engine.setFlushReport(report)

        let controller = makeController(engine: engine, sleeper: FakeSleeper(allowedTicks: 10))
        await controller.pushNow()

        XCTAssertEqual(controller.pendingCount, 0)
        XCTAssertEqual(controller.status, .idle)
        XCTAssertNotNil(controller.lastSyncedAt)
    }

    func testTheMassDeletionGuardSurfacesAsAnActionableMessage() async {
        let engine = EngineSpy()
        var report = CouchSyncEngine.FlushReport()
        report.blockedByDeletionGuard = true
        // The deletions are what is held back; the rest of the queue went out as usual, which is
        // why the message counts these and not everything that was waiting.
        report.stillDirty = (0..<12).map { "notebook:n\($0)" }
        report.heldDeletions = report.stillDirty
        engine.setFlushReport(report)

        let controller = makeController(engine: engine, sleeper: FakeSleeper(allowedTicks: 10))
        await controller.pushNow()

        guard case .failed(let message) = controller.status else {
            return XCTFail("the guard should surface as a failure, got \(controller.status)")
        }
        XCTAssertTrue(message.contains("12"), "the message should name the count: \(message)")
        // A warning about something the user cannot act on is worse than none, so the message has
        // to name both ways out and where they are.
        XCTAssertTrue(message.contains("Settings"), "say where the choice lives: \(message)")
        XCTAssertTrue(message.contains("Delete them on the server too"), message)
        XCTAssertTrue(message.contains("Keep them on the server"), message)
        XCTAssertEqual(controller.heldDeletions, report.heldDeletions,
                       "the settings screen answers for exactly the ids that were held")
    }

    /// Both answers are scoped to the batch that was shown. Sending "everything currently dirty"
    /// instead would approve deletions that arrived while the user was reading the question.
    func testAnsweringTheDeletionGuardCarriesExactlyTheHeldIDs() async {
        let engine = EngineSpy()
        var blocked = CouchSyncEngine.FlushReport()
        blocked.blockedByDeletionGuard = true
        blocked.heldDeletions = ["notebook:a", "notebook:b"]
        blocked.stillDirty = blocked.heldDeletions
        engine.setFlushReport(blocked)

        let controller = makeController(engine: engine, sleeper: FakeSleeper(allowedTicks: 10))
        await controller.pushNow()

        // Answering re-flushes, and this time the guard lets the batch through.
        engine.setFlushReport(CouchSyncEngine.FlushReport())
        await controller.approveHeldDeletions()
        XCTAssertEqual(engine.approved, [["notebook:a", "notebook:b"]])
        XCTAssertTrue(controller.heldDeletions.isEmpty, "the question is answered, so it goes away")
        XCTAssertEqual(controller.status, .idle)

        // And with nothing held, neither answer has anything to say to the engine.
        await controller.discardHeldDeletions()
        XCTAssertTrue(engine.discarded.isEmpty)
    }

    func testKeepingNotebooksOnTheServerDiscardsExactlyTheHeldTombstones() async {
        let engine = EngineSpy()
        var blocked = CouchSyncEngine.FlushReport()
        blocked.blockedByDeletionGuard = true
        blocked.heldDeletions = ["notebook:a", "notebook:b"]
        blocked.stillDirty = blocked.heldDeletions
        engine.setFlushReport(blocked)

        let controller = makeController(engine: engine, sleeper: FakeSleeper(allowedTicks: 10))
        await controller.pushNow()

        engine.setFlushReport(CouchSyncEngine.FlushReport())
        await controller.discardHeldDeletions()

        XCTAssertEqual(engine.discarded, [["notebook:a", "notebook:b"]])
        XCTAssertTrue(engine.approved.isEmpty, "keeping them must not also publish them")
        XCTAssertTrue(controller.heldDeletions.isEmpty)
        XCTAssertEqual(controller.pendingCount, 0)
    }

    /// A wrong clock is not a sync failure — everything pushes as usual — but it changes which
    /// version of a page wins a merge, so it has to be said out loud alongside whatever else the
    /// status is reporting.
    func testAClockSkewWarningRidesAlongsideTheStatusWithoutFailingTheSync() async {
        let engine = EngineSpy()
        var report = CouchSyncEngine.FlushReport()
        report.pushed = ["page:a"]
        report.clockSkew = ClockSkew(seconds: 3_600)
        engine.setFlushReport(report)

        let controller = makeController(engine: engine, sleeper: FakeSleeper(allowedTicks: 10))
        await controller.pushNow()

        XCTAssertEqual(controller.status, .idle, "skew is advisory, not a failure")
        XCTAssertEqual(controller.clockSkew?.seconds, 3_600)
        guard let detail = controller.statusDetail else {
            return XCTFail("the warning should reach the status line")
        }
        XCTAssertTrue(detail.contains("ahead of"), detail)

        // And it clears when the clocks agree again, rather than sitting there until a restart.
        engine.setFlushReport({
            var healthy = CouchSyncEngine.FlushReport()
            healthy.pushed = ["page:b"]
            return healthy
        }())
        await controller.pushNow()
        XCTAssertNil(controller.clockSkew)
    }

    // MARK: Pull loop

    /// The first pull must not be a long poll: a long poll only reports what happens after it
    /// starts, so opening with one would miss everything that changed while bopa was closed.
    func testTheLoopCatchesUpBeforeItWaits() async throws {
        let engine = EngineSpy()
        let controller = makeController(engine: engine, sleeper: FakeSleeper(allowedTicks: 10))

        controller.start()
        try await Task.sleep(for: .milliseconds(80))
        controller.stop()

        let calls = engine.pullCalls
        XCTAssertGreaterThanOrEqual(calls.count, 2, "the loop should keep pulling")
        XCTAssertEqual(calls.first, false, "the first pull should be a catch-up, not a long poll")
        XCTAssertEqual(calls[1], true, "subsequent pulls should hold the connection open")
    }

    func testContentTheServerLacksIsPushedBackWithoutWaitingForTheEditTimer() async throws {
        let engine = EngineSpy()
        var pullReport = CouchSyncEngine.PullReport()
        pullReport.applied = ["page:a"]
        pullReport.pushBack = ["page:a"]
        engine.setPullReport(pullReport)

        let controller = makeController(engine: engine, sleeper: FakeSleeper(allowedTicks: 10))
        controller.start()
        try await Task.sleep(for: .milliseconds(80))
        controller.stop()

        XCTAssertGreaterThanOrEqual(
            engine.flushCount, 1,
            "a pull that found local-only content should push it without waiting")
    }

    /// Reconnecting has to drain the outbox, not just deliver what the feed carried. Edits made
    /// while offline stayed dirty because their flush failed; the pull that succeeds afterwards is
    /// the first sign the network is back, and nothing else will retry them until the user writes
    /// again or taps Sync now.
    func testAPullThatBringsNothingBackStillPushesWorkLeftPendingByAnOfflineFlush() async throws {
        let engine = EngineSpy()
        engine.setPendingCount(2)  // two documents a flush could not send while offline
        // The feed has nothing for us: no applied rows, and so nothing to push back either.
        engine.setPullReport(CouchSyncEngine.PullReport())

        let controller = makeController(engine: engine, sleeper: FakeSleeper(allowedTicks: 10))
        controller.start()
        try await Task.sleep(for: .milliseconds(80))
        controller.stop()

        XCTAssertGreaterThanOrEqual(
            engine.flushCount, 1,
            "a successful pull with documents still pending should flush the outbox")
    }

    /// The converse: an idle feed with an empty outbox must not push on every pass.
    func testAnIdlePullWithNothingPendingDoesNotPush() async throws {
        let engine = EngineSpy()
        let controller = makeController(engine: engine, sleeper: FakeSleeper(allowedTicks: 10))

        controller.start()
        try await Task.sleep(for: .milliseconds(80))
        controller.stop()

        XCTAssertEqual(engine.flushCount, 0, "nothing queued means nothing to send")
    }

    func testAFailingPullBacksOffInsteadOfSpinning() async throws {
        let engine = EngineSpy()
        engine.setPullError(CouchError.transport("offline"))
        let sleeper = FakeSleeper(allowedTicks: 4)

        let controller = makeController(engine: engine, sleeper: sleeper)
        controller.start()
        try await Task.sleep(for: .milliseconds(100))
        controller.stop()

        let waits = sleeper.recorded
        XCTAssertFalse(waits.isEmpty, "a failing pull should wait before retrying")
        // Doubling, so a server that is down does not become a request flood.
        if waits.count >= 2 {
            XCTAssertGreaterThan(waits[1], waits[0], "backoff should grow: \(waits)")
        }
        guard case .failed(let message) = controller.status else {
            return XCTFail("expected a failure status, got \(controller.status)")
        }
        XCTAssertTrue(message.lowercased().contains("offline"), message)
    }

    // MARK: Image warnings

    /// Images that have not arrived are a note, not a failure. Reporting them as a failed sync
    /// would have people waiting for a state that has already arrived — the notes and the ink are
    /// synced — or deleting a library over a picture that is still uploading from the other device.
    func testWaitingImagesAreReportedBesideTheStatusRatherThanAsAFailure() async throws {
        let engine = EngineSpy()
        var report = CouchSyncEngine.PullReport()
        report.applied = ["page:p1"]
        report.missingAssets = ["asset:a1", "asset:a2"]
        engine.setPullReport(report)
        let controller = makeController(engine: engine, sleeper: FakeSleeper(allowedTicks: 4))

        controller.start()
        try await Task.sleep(for: .milliseconds(80))
        controller.stop()

        XCTAssertEqual(controller.status, .idle, "images are not a sync failure")
        let warning = try XCTUnwrap(controller.assetWarning)
        XCTAssertTrue(warning.contains("2 images"), warning)
        XCTAssertTrue(warning.lowercased().contains("ink are synced"), warning)
        XCTAssertTrue(
            controller.statusDetail?.contains("2 images") == true,
            "the note should ride along with the status: \(controller.statusDetail ?? "nil")")
    }

    /// Distinct wording, because this one does not fix itself by waiting.
    func testCorruptImagesAreDescribedAsUnverifiedRatherThanAsStillDownloading() async throws {
        let engine = EngineSpy()
        var report = CouchSyncEngine.PullReport()
        report.corruptAssets = ["asset:a1"]
        report.assetFailures = ["asset:a1": "downloaded bytes did not match the asset digest"]
        engine.setPullReport(report)
        let controller = makeController(engine: engine, sleeper: FakeSleeper(allowedTicks: 4))

        controller.start()
        try await Task.sleep(for: .milliseconds(80))
        controller.stop()

        let warning = try XCTUnwrap(controller.assetWarning)
        XCTAssertTrue(warning.contains("could not be verified"), warning)
        XCTAssertEqual(controller.status, .idle)
    }

    /// The note is assigned from each report, never accumulated, so it clears itself when the
    /// blobs land — nothing has to remember it was ever set.
    func testTheImageNoteClearsOnceTheBlobsArrive() async throws {
        let engine = EngineSpy()
        var report = CouchSyncEngine.PullReport()
        // `applied` is non-empty so the loop keeps pulling rather than parking on the idle floor
        // and spending its sleeper budget before the second report is in place.
        report.applied = ["page:p1"]
        report.missingAssets = ["asset:a1"]
        engine.setPullReport(report)
        let controller = makeController(engine: engine, sleeper: FakeSleeper(allowedTicks: 10))

        controller.start()
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertNotNil(controller.assetWarning)

        var resolved = CouchSyncEngine.PullReport()
        resolved.applied = ["page:p1"]
        resolved.fetchedAssets = ["asset:a1"]
        engine.setPullReport(resolved)
        try await Task.sleep(for: .milliseconds(80))
        controller.stop()

        XCTAssertNil(controller.assetWarning, "a pull with nothing owed should clear the note")
    }

    // MARK: Push backoff

    private func failingFlush(
        retriable: Bool, retryAfter: TimeInterval? = nil
    ) -> CouchSyncEngine.FlushReport {
        var report = CouchSyncEngine.FlushReport()
        report.failures = ["page:p1": "server(503)"]
        report.stillDirty = ["page:p1"]
        report.hasRetriableFailure = retriable
        report.retryAfter = retryAfter
        return report
    }

    /// A failing outbox has to retry itself. Before this it flushed once, reported the failure, and
    /// then waited for the user to edit something else or tap Sync now — on a server that was
    /// briefly down, the queued pages simply sat there.
    func testAFailedPushRetriesItselfWithGrowingDelays() async throws {
        let engine = EngineSpy()
        engine.setFlushReport(failingFlush(retriable: true))
        let sleeper = FakeSleeper(allowedTicks: 4)
        let controller = makeController(engine: engine, sleeper: sleeper, quiet: 0.01)

        await controller.pushNow()
        try await Task.sleep(for: .milliseconds(120))
        controller.stop()

        XCTAssertGreaterThan(engine.flushCount, 1, "the outbox should have been tried again")
        let waits = sleeper.recorded
        XCTAssertGreaterThanOrEqual(waits.count, 2, "expected several retries: \(waits)")
        // Jittered, so compare across a doubling rather than between neighbours.
        XCTAssertGreaterThan(waits[1], waits[0] * 1.2, "backoff should grow: \(waits)")
    }

    /// The trap the plan calls out: pull and push fail independently, and the pull recovers first.
    /// One shared counter meant every successful pull reset the push delay to a second, so an
    /// outbox that kept failing retried at full speed forever.
    func testASuccessfulPullDoesNotResetPushBackoff() async throws {
        let engine = EngineSpy()
        engine.setFlushReport(failingFlush(retriable: true))
        let sleeper = FakeSleeper(allowedTicks: 8)
        let controller = makeController(engine: engine, sleeper: sleeper, quiet: 0.01)

        // Climb the backoff a few steps.
        await controller.pushNow()
        try await Task.sleep(for: .milliseconds(120))
        let climbed = sleeper.recorded.last ?? 0
        controller.stop()

        // A pull succeeds — the network is back for reads — and the outbox keeps failing.
        engine.setPullReport(CouchSyncEngine.PullReport())
        engine.setPendingCount(1)
        await controller.pushNow()
        try await Task.sleep(for: .milliseconds(40))
        controller.stop()

        let resumed = sleeper.recorded.last ?? 0
        XCTAssertGreaterThan(
            resumed, climbed * 0.5,
            "the push delay should have carried on from where it was, not restarted: "
                + "\(sleeper.recorded)")
    }

    func testASuccessfulPushResetsTheBackoff() async throws {
        let engine = EngineSpy()
        engine.setFlushReport(failingFlush(retriable: true))
        let sleeper = FakeSleeper(allowedTicks: 8)
        let controller = makeController(engine: engine, sleeper: sleeper, quiet: 0.01)

        await controller.pushNow()
        try await Task.sleep(for: .milliseconds(120))
        controller.stop()
        let climbed = sleeper.recorded.last ?? 0
        XCTAssertGreaterThan(climbed, 1, "the backoff should have grown past the floor first")

        // The outbox drains, and then something fails again from scratch.
        engine.setFlushReport(CouchSyncEngine.FlushReport())
        await controller.pushNow()
        engine.setFlushReport(failingFlush(retriable: true))
        let before = sleeper.recorded.count
        await controller.pushNow()
        try await Task.sleep(for: .milliseconds(30))
        controller.stop()

        let afterReset = Array(sleeper.recorded.dropFirst(before))
        XCTAssertFalse(afterReset.isEmpty, "the new failure should have scheduled a retry")
        XCTAssertLessThan(
            afterReset[0], climbed,
            "a push that succeeded should have put the delay back at the floor: \(afterReset)")
    }

    /// A terminal failure is left queued and reported, but must not put the device into a retry
    /// loop that cannot end. Nothing about waiting makes a 413 acceptable to the server.
    func testATerminalPushFailureIsNotRetriedOnATimer() async throws {
        let engine = EngineSpy()
        engine.setFlushReport(failingFlush(retriable: false))
        let sleeper = FakeSleeper(allowedTicks: 8)
        let controller = makeController(engine: engine, sleeper: sleeper, quiet: 0.01)

        await controller.pushNow()
        try await Task.sleep(for: .milliseconds(120))
        controller.stop()

        XCTAssertEqual(engine.flushCount, 1, "a refusal on the merits should not be re-sent on a timer")
        XCTAssertEqual(controller.pendingCount, 1, "and the document stays queued")
        guard case .failed = controller.status else {
            return XCTFail("expected the failure to be reported, got \(controller.status)")
        }
    }

    /// The feed loop used to re-trigger the outbox on every pull while anything was queued — so a
    /// document the server kept refusing was retried at feed speed and the push backoff never
    /// actually held. A scheduled retry owns the outbox until it fires or an edit replaces it.
    func testTheFeedLoopDoesNotStampedeAScheduledPushRetry() async throws {
        let engine = EngineSpy()
        engine.setFlushReport(failingFlush(retriable: true))
        engine.setPendingCount(1)
        // Retry waits (jittered off the 1s floor) park; the feed's own idle pacing (0.5s)
        // returns instantly — so the loop keeps lapping while the retry timer is pending, which
        // is exactly the race under test.
        let controller = CouchSyncController(
            editQuietPeriod: 0.01,
            sleeper: { duration in
                if duration > 0.6 { try await Task.sleep(for: .seconds(10)) }
            },
            flush: { await engine.flush() },
            pull: { try await engine.pull(longpoll: $0) },
            pending: { await engine.pendingCount() })

        await controller.pushNow()
        XCTAssertEqual(engine.flushCount, 1, "the failing push itself ran once")

        controller.start()
        try await Task.sleep(for: .milliseconds(120))
        controller.stop()

        XCTAssertGreaterThanOrEqual(engine.pullCalls.count, 2, "the feed loop was lapping")
        XCTAssertEqual(
            engine.flushCount, 1,
            "the queued outbox belongs to the scheduled retry, not to every pull")
    }

    /// RFC 9110 §10.2.3: when the server says when to come back, that answer beats the client's
    /// own guess.
    func testARetryAfterOverridesTheClientsOwnDelay() async throws {
        let engine = EngineSpy()
        engine.setFlushReport(failingFlush(retriable: true, retryAfter: 30))
        let sleeper = FakeSleeper(allowedTicks: 2)
        let controller = makeController(engine: engine, sleeper: sleeper, quiet: 0.01)

        await controller.pushNow()
        try await Task.sleep(for: .milliseconds(40))
        controller.stop()

        let first = try XCTUnwrap(sleeper.recorded.first)
        // Jittered ±15%, so assert the band rather than the number.
        XCTAssertGreaterThan(first, 24, "should have waited the 30s the server asked for: \(first)")
        XCTAssertLessThan(first, 36)
    }

    func testARecoveredPullClearsThePreviousFailure() async throws {
        let engine = EngineSpy()
        engine.setPullError(CouchError.transport("offline"))
        let controller = makeController(engine: engine, sleeper: FakeSleeper(allowedTicks: 10))

        controller.start()
        try await Task.sleep(for: .milliseconds(50))
        guard case .failed = controller.status else {
            controller.stop()
            return XCTFail("expected the loop to report a failure first")
        }

        engine.setPullError(nil)
        try await Task.sleep(for: .milliseconds(80))
        controller.stop()

        XCTAssertEqual(controller.status, .idle, "reaching the server again should clear the error")
    }

    func testStartIsIdempotentAndStopEndsTheLoop() async throws {
        let engine = EngineSpy()
        let controller = makeController(engine: engine, sleeper: FakeSleeper(allowedTicks: 20))

        controller.start()
        controller.start()
        XCTAssertTrue(controller.isRunning)
        try await Task.sleep(for: .milliseconds(50))
        controller.stop()
        XCTAssertFalse(controller.isRunning)

        // A request already in flight when stop lands still completes, so allow for one more —
        // what must not happen is the count continuing to climb.
        let afterStop = engine.pullCalls.count
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertLessThanOrEqual(
            engine.pullCalls.count, afterStop + 1, "stop should really stop it")
    }

    /// A long poll is meant to block until something happens. When it does not — a proxy that
    /// answers immediately, a server ignoring the timeout — re-issuing at once turns the loop into
    /// a hot spin against the server.
    func testAnImmediatelyReturningFeedDoesNotBecomeAHotLoop() async throws {
        let engine = EngineSpy()  // returns an empty report instantly
        let sleeper = FakeSleeper(allowedTicks: 3)
        let controller = makeController(engine: engine, sleeper: sleeper)

        controller.start()
        try await Task.sleep(for: .milliseconds(100))
        controller.stop()

        // Bounded by the sleeper's ticks rather than by how fast the machine is.
        XCTAssertLessThanOrEqual(
            engine.pullCalls.count, 5,
            "an idle feed should pace itself, got \(engine.pullCalls.count) requests")
        XCTAssertFalse(sleeper.recorded.isEmpty, "it should have waited between empty results")
    }

    func testUnauthorizedIsReportedAsCredentialsRatherThanAsBeingOffline() async throws {
        let engine = EngineSpy()
        engine.setPullError(CouchError.unauthorized)
        let controller = makeController(engine: engine, sleeper: FakeSleeper(allowedTicks: 3))

        controller.start()
        try await Task.sleep(for: .milliseconds(60))
        controller.stop()

        guard case .failed(let message) = controller.status else {
            return XCTFail("expected a failure, got \(controller.status)")
        }
        XCTAssertTrue(
            message.lowercased().contains("username") || message.lowercased().contains("password"),
            "retrying cannot fix bad credentials, so say that: \(message)")
    }

    func testSyncNowCatchesUpAndPushesWithoutHoldingAConnectionOpen() async {
        let engine = EngineSpy()
        let controller = makeController(engine: engine, sleeper: FakeSleeper(allowedTicks: 10))

        await controller.syncNow()

        XCTAssertEqual(engine.pullCalls, [false], "Sync now should not wait on a long poll")
        XCTAssertEqual(engine.flushCount, 1)
    }
}
