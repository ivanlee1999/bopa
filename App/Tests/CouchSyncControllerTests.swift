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
