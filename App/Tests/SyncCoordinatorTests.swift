import Foundation
import NotableKit
import XCTest

@testable import Bopa

@MainActor
final class SyncCoordinatorTests: XCTestCase {

    /// Records sync invocations and optionally blocks each run until released,
    /// so tests can hold a sync "in flight".
    @MainActor
    private final class SyncSpy {
        private(set) var callCount = 0
        /// The `uploadOnly` set each run was handed, newest last.
        private(set) var uploadOnlyPerCall: [Set<String>] = []
        var result = SyncReport()
        var blocking = false
        private var gates: [CheckedContinuation<Void, Never>] = []

        func run(uploadOnly: Set<String> = []) async -> SyncReport {
            callCount += 1
            uploadOnlyPerCall.append(uploadOnly)
            if blocking {
                await withCheckedContinuation { gates.append($0) }
            }
            return result
        }

        func releaseAll() {
            gates.forEach { $0.resume() }
            gates.removeAll()
        }
    }

    /// Stands in for `Task.sleep` so the poll loop runs at test speed. Returns immediately for
    /// `allowedTicks` calls, then throws to end the loop — otherwise a bug would spin forever.
    private final class FakeSleeper: @unchecked Sendable {
        private let lock = NSLock()
        private var remaining: Int
        private(set) var calls = 0

        init(allowedTicks: Int) { self.remaining = allowedTicks }

        struct Stop: Error {}

        func sleep(_ seconds: TimeInterval) async throws {
            try lock.withLock {
                calls += 1
                guard remaining > 0 else { throw Stop() }
                remaining -= 1
            }
            await Task.yield()
        }
    }

    /// Mutable clock injected as the coordinator's `now`.
    @MainActor
    private final class Clock {
        var now = Date(timeIntervalSince1970: 1_000_000)
    }

    private func makeStore() -> NotebookStore {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("bopa-sync-test-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: tmp)
        }
        return NotebookStore(rootURL: tmp)
    }

    private func configuredSettings() -> SyncSettings {
        SyncSettings(serverURL: "https://example.com/dav", username: "u", password: "p")
    }

    private func makeCoordinator(
        spy: SyncSpy,
        clock: Clock? = nil,
        settings: SyncSettings? = nil,
        automatic: Bool = true,
        selected: Bool = true,
        sleeper: FakeSleeper? = nil
    ) -> SyncCoordinator {
        let settings = settings ?? configuredSettings()
        return SyncCoordinator(
            now: { clock?.now ?? Date() },
            loadSettings: { settings },
            isAutomaticEnabled: { automatic },
            isSelectedBackend: { selected },
            sleeper: { seconds in
                guard let sleeper else { throw FakeSleeper.Stop() }
                try await sleeper.sleep(seconds)
            },
            performSync: { _, _, uploadOnly in await spy.run(uploadOnly: uploadOnly) })
    }

    /// Spins the main actor until `condition` holds (bounded so a bug fails the
    /// test instead of hanging it).
    private func spinUntil(_ condition: () -> Bool) async {
        for _ in 0..<1000 where !condition() {
            await Task.yield()
        }
        XCTAssertTrue(condition(), "condition never became true")
    }

    // MARK: - Basic lifecycle

    func testSyncNowSuccessUpdatesStatusAndLastSyncedAt() async {
        let store = makeStore()
        let spy = SyncSpy()
        var report = SyncReport()
        report.uploaded = ["a"]
        report.downloaded = ["b", "c"]
        spy.result = report

        let coordinator = makeCoordinator(spy: spy)
        XCTAssertEqual(coordinator.status, .idle)
        XCTAssertNil(coordinator.lastSyncedAt)

        await coordinator.syncNow(store: store)

        XCTAssertEqual(spy.callCount, 1)
        guard case .success(let got, let at) = coordinator.status else {
            return XCTFail("expected success, got \(coordinator.status)")
        }
        XCTAssertEqual(got, report)
        XCTAssertEqual(coordinator.lastSyncedAt, at)
    }

    /// The whole point of the backend switch: WebDAV goes quiet the moment it stops being the
    /// selected backend, no matter which path asks for a run. A configured server is not consent
    /// — two engines writing the same notebooks is what this prevents.
    func testNoWebDAVRunHappensWhenWebDAVIsNotTheSelectedBackend() async {
        let store = makeStore()
        let spy = SyncSpy()
        let coordinator = makeCoordinator(
            spy: spy, selected: false, sleeper: FakeSleeper(allowedTicks: 5))

        await coordinator.syncNow(store: store)
        await coordinator.syncIfStale(store: store)
        await coordinator.syncIfAutomatic(store: store)

        // The edit-driven push and the poll loop go through `syncNow` too, so their timers still
        // fire — what must not happen is a run at the end of one.
        coordinator.noteEdited(store: store)
        coordinator.startAutoSync(store: store)
        for _ in 0..<200 { await Task.yield() }
        coordinator.stopAutoSync()

        XCTAssertEqual(spy.callCount, 0)
        XCTAssertEqual(coordinator.status, .idle)
        XCTAssertNil(coordinator.lastSyncedAt)
    }

    /// A conflict decision outlives a backend switch — the list is not cleared by one. Applying it
    /// would write to a server bopa has been told to leave alone, so it fails loudly instead.
    func testApplyingAConflictResolutionFailsWhenWebDAVIsNotSelected() async {
        let store = makeStore()
        let spy = SyncSpy()
        let coordinator = makeCoordinator(spy: spy, selected: false)

        do {
            try await coordinator.applyResolution(store: store) { _ in
                XCTFail("the resolution body must not run")
            }
            XCTFail("expected the resolution to be refused")
        } catch is SyncCoordinator.BackendNotSelected {
            // expected
        } catch {
            XCTFail("expected BackendNotSelected, got \(error)")
        }

        XCTAssertEqual(spy.callCount, 0)
        XCTAssertEqual(coordinator.status, .idle)
    }

    func testSyncNowIsNoOpWhenNotConfigured() async {
        let store = makeStore()
        let spy = SyncSpy()
        let empty = SyncSettings(serverURL: "", username: "", password: "")
        let coordinator = makeCoordinator(spy: spy, settings: empty)

        await coordinator.syncNow(store: store)
        await coordinator.syncIfStale(store: store)

        XCTAssertEqual(spy.callCount, 0)
        XCTAssertEqual(coordinator.status, .idle)
        XCTAssertNil(coordinator.lastAttemptAt)
    }

    func testErrorOnlyReportBecomesFailure() async {
        let store = makeStore()
        let spy = SyncSpy()
        spy.result.errors = ["server: cannot prepare directories (timeout)"]

        let coordinator = makeCoordinator(spy: spy)
        await coordinator.syncNow(store: store)

        guard case .failure(let message, _) = coordinator.status else {
            return XCTFail("expected failure, got \(coordinator.status)")
        }
        XCTAssertTrue(message.contains("timeout"))
        XCTAssertNil(coordinator.lastSyncedAt)
    }

    func testPartialErrorsWithTransfersStillCountAsSuccess() async {
        let store = makeStore()
        let spy = SyncSpy()
        spy.result.downloaded = ["nb1"]
        spy.result.errors = ["nb2: upload failed"]

        let coordinator = makeCoordinator(spy: spy)
        await coordinator.syncNow(store: store)

        guard case .success(let report, _) = coordinator.status else {
            return XCTFail("expected success, got \(coordinator.status)")
        }
        XCTAssertEqual(report.errors, ["nb2: upload failed"])
        XCTAssertNotNil(coordinator.lastSyncedAt)
    }

    func testSuccessfulSyncRefreshesStore() async {
        let store = makeStore()
        XCTAssertTrue(store.notebooks.isEmpty)

        let coordinator = SyncCoordinator(
            loadSettings: { self.configuredSettings() },
            performSync: { _, rootURL, _ in
                // Simulate the engine downloading a notebook into the local tree.
                let now = NotableDate.format(Date())
                let manifest = NotebookManifest(
                    notebookId: "nb1", title: "Downloaded", pageIds: [],
                    createdAt: now, updatedAt: now, serverTimestamp: now)
                let dir = rootURL.appendingPathComponent("notebooks/nb1", isDirectory: true)
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try? JSONEncoder().encode(manifest).write(to: dir.appendingPathComponent("manifest.json"))
                var report = SyncReport()
                report.downloaded = ["nb1"]
                return report
            })

        await coordinator.syncNow(store: store)
        XCTAssertEqual(store.notebooks.map(\.notebookId), ["nb1"])
    }

    // MARK: - Single flight

    func testConcurrentSyncNowRunsEngineOnce() async {
        let store = makeStore()
        let spy = SyncSpy()
        spy.blocking = true
        let coordinator = makeCoordinator(spy: spy)

        let first = Task { await coordinator.syncNow(store: store) }
        await spinUntil { spy.callCount == 1 }
        XCTAssertTrue(coordinator.isSyncing)

        // Re-entrant calls while a run is in flight are no-ops.
        await coordinator.syncNow(store: store)
        await coordinator.syncIfStale(store: store)
        XCTAssertEqual(spy.callCount, 1)
        XCTAssertTrue(coordinator.isSyncing)

        spy.releaseAll()
        await first.value

        XCTAssertEqual(spy.callCount, 1)
        guard case .success = coordinator.status else {
            return XCTFail("expected success, got \(coordinator.status)")
        }
    }

    // MARK: - Staleness

    func testSyncIfStaleRespectsInterval() async {
        let store = makeStore()
        let spy = SyncSpy()
        let clock = Clock()
        let coordinator = makeCoordinator(spy: spy, clock: clock)

        await coordinator.syncIfStale(store: store)   // never attempted: runs
        XCTAssertEqual(spy.callCount, 1)

        clock.now += 59
        await coordinator.syncIfStale(store: store)   // within 60s window: skipped
        XCTAssertEqual(spy.callCount, 1)

        clock.now += 2                                // 61s after the attempt
        await coordinator.syncIfStale(store: store)
        XCTAssertEqual(spy.callCount, 2)
    }

    func testFailedAttemptStillThrottlesSyncIfStaleButNotSyncNow() async {
        let store = makeStore()
        let spy = SyncSpy()
        spy.result.errors = ["boom"]
        let clock = Clock()
        let coordinator = makeCoordinator(spy: spy, clock: clock)

        await coordinator.syncIfStale(store: store)
        XCTAssertEqual(spy.callCount, 1)
        guard case .failure = coordinator.status else {
            return XCTFail("expected failure, got \(coordinator.status)")
        }

        clock.now += 30
        await coordinator.syncIfStale(store: store)   // failed attempt still throttles
        XCTAssertEqual(spy.callCount, 1)

        await coordinator.syncNow(store: store)       // manual sync bypasses staleness
        XCTAssertEqual(spy.callCount, 2)
    }

    // MARK: Empty-run reporting

    /// "Nothing to sync" is the right words for an up-to-date library and the wrong words for a
    /// wrong folder, and the second is the far likelier reason a library looks empty.
    func testEmptyRunNamesWhatItFound() {
        XCTAssertEqual(
            SyncCoordinator.emptyRunSummary(for: .populated), "Nothing to sync")
        XCTAssertEqual(
            SyncCoordinator.emptyRunSummary(for: .unknown), "Nothing to sync")
        XCTAssertTrue(
            SyncCoordinator.emptyRunSummary(for: .absent).contains("created the shared tree"))
        XCTAssertTrue(
            SyncCoordinator.emptyRunSummary(for: .empty).contains("nothing in the shared folder"))
    }

    /// An empty tree is not a failure: a genuinely new setup looks exactly the same, and crying
    /// "sync failed" on day one would be a false alarm.
    func testAbsentTreeStaysASuccess() async {
        let store = makeStore()
        let spy = SyncSpy()
        spy.result.remoteTree = .absent

        let coordinator = makeCoordinator(spy: spy)
        await coordinator.syncNow(store: store)

        guard case .success = coordinator.status else {
            return XCTFail("expected success, got \(coordinator.status)")
        }
        XCTAssertTrue(coordinator.lastRunFoundNothing)
        XCTAssertEqual(
            coordinator.statusDetail, SyncCoordinator.emptyRunSummary(for: .absent))
    }

    /// Pushing our own notes into a tree we just created says nothing about whether the *other*
    /// device's notes are there — that is the exact shape of a wrong-folder setup, so the summary
    /// reports the transfer while the hint stays up.
    func testTransfersOutrankTheSummaryButNotTheHint() async {
        let store = makeStore()
        let spy = SyncSpy()
        spy.result.remoteTree = .absent
        spy.result.uploaded = ["nb1"]

        let coordinator = makeCoordinator(spy: spy)
        await coordinator.syncNow(store: store)

        XCTAssertEqual(coordinator.statusDetail, "↑1")
        XCTAssertTrue(coordinator.lastRunFoundNothing)
    }

    // MARK: - Automatic sync

    func testPollLoopSyncsOnEachTick() async {
        let store = makeStore()
        let spy = SyncSpy()
        let sleeper = FakeSleeper(allowedTicks: 3)
        let coordinator = makeCoordinator(spy: spy, sleeper: sleeper)

        coordinator.startAutoSync(store: store)
        await spinUntil { spy.callCount == 3 }

        XCTAssertEqual(spy.callCount, 3)
    }

    func testStartAutoSyncIsIdempotent() async {
        let store = makeStore()
        let spy = SyncSpy()
        let sleeper = FakeSleeper(allowedTicks: 1)
        let coordinator = makeCoordinator(spy: spy, sleeper: sleeper)

        coordinator.startAutoSync(store: store)
        coordinator.startAutoSync(store: store)   // second call must not add a loop
        await spinUntil { spy.callCount == 1 }

        XCTAssertEqual(spy.callCount, 1, "a second start spawned another loop")
        XCTAssertTrue(coordinator.isAutoSyncRunning)
    }

    func testStopAutoSyncEndsThePolling() async {
        let store = makeStore()
        let spy = SyncSpy()
        let coordinator = makeCoordinator(spy: spy, sleeper: FakeSleeper(allowedTicks: 100))

        coordinator.startAutoSync(store: store)
        await spinUntil { spy.callCount >= 1 }
        coordinator.stopAutoSync()
        let afterStop = spy.callCount
        for _ in 0..<200 { await Task.yield() }

        XCTAssertFalse(coordinator.isAutoSyncRunning)
        XCTAssertEqual(spy.callCount, afterStop, "loop kept running after stop")
    }

    /// The toggle gates automatic runs only — "Sync now" must still work when it is off.
    func testAutomaticDisabledSuppressesPollingButNotManualSync() async {
        let store = makeStore()
        let spy = SyncSpy()
        let coordinator = makeCoordinator(
            spy: spy, automatic: false, sleeper: FakeSleeper(allowedTicks: 5))

        coordinator.startAutoSync(store: store)
        for _ in 0..<200 { await Task.yield() }
        XCTAssertEqual(spy.callCount, 0, "polled while automatic sync was off")

        await coordinator.syncNow(store: store)
        XCTAssertEqual(spy.callCount, 1)
    }

    func testNoteEditedDoesNothingWhenAutomaticIsOff() async {
        let store = makeStore()
        let spy = SyncSpy()
        let coordinator = makeCoordinator(
            spy: spy, automatic: false, sleeper: FakeSleeper(allowedTicks: 5))

        coordinator.noteEdited(store: store)
        for _ in 0..<200 { await Task.yield() }

        XCTAssertEqual(spy.callCount, 0)
    }

    /// Writing is continuous; pushing must not be. Successive edits collapse into one sync.
    func testRepeatedEditsCoalesceIntoASinglePush() async {
        let store = makeStore()
        let spy = SyncSpy()
        let coordinator = makeCoordinator(spy: spy, sleeper: FakeSleeper(allowedTicks: 100))

        coordinator.noteEdited(store: store)
        coordinator.noteEdited(store: store)
        coordinator.noteEdited(store: store)
        await spinUntil { spy.callCount == 1 }
        for _ in 0..<200 { await Task.yield() }

        XCTAssertEqual(spy.callCount, 1, "each edit pushed separately")
    }

    // MARK: - Conflict resolution wiring

    /// The decision must be applied *and* followed by a sync, in that order and without a poll
    /// slipping between them — a run that started earlier holds pre-decision sync state and would
    /// write it back over the rebaseline.
    func testApplyResolutionRunsTheDecisionThenSyncs() async throws {
        let store = makeStore()
        let spy = SyncSpy()
        let coordinator = makeCoordinator(spy: spy)
        var order: [String] = []

        try await coordinator.applyResolution(store: store) { _ in
            order.append("decision")
        }

        order.append("after")
        XCTAssertEqual(order, ["decision", "after"])
        XCTAssertEqual(spy.callCount, 1, "the decision was not followed by a sync")
    }

    /// A resolution while a sync is running is refused loudly rather than silently dropped.
    func testApplyResolutionRefusesWhileASyncIsInFlight() async throws {
        let store = makeStore()
        let spy = SyncSpy()
        spy.blocking = true
        let coordinator = makeCoordinator(spy: spy)

        let first = Task { await coordinator.syncNow(store: store) }
        await spinUntil { spy.callCount == 1 }

        do {
            try await coordinator.applyResolution(store: store) { _ in
                XCTFail("decision ran during an in-flight sync")
            }
            XCTFail("expected the resolution to be refused")
        } catch {
            XCTAssertTrue(error is SyncCoordinator.ResolutionBusy)
        }

        spy.releaseAll()
        await first.value
    }

    func testApplyResolutionPropagatesAFailedDecision() async {
        let store = makeStore()
        let spy = SyncSpy()
        let coordinator = makeCoordinator(spy: spy)
        struct Boom: Error {}

        do {
            try await coordinator.applyResolution(store: store) { _ in throw Boom() }
            XCTFail("expected the decision's error to surface")
        } catch {
            XCTAssertTrue(error is Boom)
        }
        XCTAssertEqual(spy.callCount, 0, "synced despite the decision failing")
    }

    // MARK: - Open notebook exclusion

    func testOpenNotebookIsHandedToTheEngineAsUploadOnly() async {
        let store = makeStore()
        let spy = SyncSpy()
        let coordinator = makeCoordinator(spy: spy)
        coordinator.openNotebookId = "nb-open"

        await coordinator.syncNow(store: store)

        XCTAssertEqual(spy.uploadOnlyPerCall, [["nb-open"]])
    }

    func testNoOpenNotebookMeansNoExclusions() async {
        let store = makeStore()
        let spy = SyncSpy()
        let coordinator = makeCoordinator(spy: spy)

        await coordinator.syncNow(store: store)

        XCTAssertEqual(spy.uploadOnlyPerCall, [[]])
    }

    /// The set is captured before the run starts: closing the editor mid-sync must not let a
    /// download land on the notebook this run already decided to protect.
    func testExclusionIsFixedForTheDurationOfARun() async {
        let store = makeStore()
        let spy = SyncSpy()
        spy.blocking = true
        let coordinator = makeCoordinator(spy: spy)
        coordinator.openNotebookId = "nb-open"

        let run = Task { await coordinator.syncNow(store: store) }
        await spinUntil { spy.callCount == 1 }
        coordinator.openNotebookId = nil          // editor closes mid-run
        spy.releaseAll()
        await run.value

        XCTAssertEqual(spy.uploadOnlyPerCall, [["nb-open"]])
    }

    func testPopulatedTreeKeepsTheOriginalWording() async {
        let store = makeStore()
        let spy = SyncSpy()
        spy.result.remoteTree = .populated

        let coordinator = makeCoordinator(spy: spy)
        await coordinator.syncNow(store: store)

        XCTAssertEqual(coordinator.statusDetail, "Nothing to sync")
        XCTAssertFalse(coordinator.lastRunFoundNothing)
    }
}
