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
        var result = SyncReport()
        var blocking = false
        private var gates: [CheckedContinuation<Void, Never>] = []

        func run() async -> SyncReport {
            callCount += 1
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
        settings: SyncSettings? = nil
    ) -> SyncCoordinator {
        let settings = settings ?? configuredSettings()
        return SyncCoordinator(
            now: { clock?.now ?? Date() },
            loadSettings: { settings },
            performSync: { _, _ in await spy.run() })
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
            performSync: { _, rootURL in
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
