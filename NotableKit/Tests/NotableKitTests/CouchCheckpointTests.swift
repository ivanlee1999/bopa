import XCTest
@testable import NotableKit

/// The checkpoint must never go backwards.
///
/// `CouchSyncEngine` is an actor and actors are reentrant: it suspends at the feed request, so a
/// second `pull` — a foreground catch-up while the longpoll waits — runs to completion in that gap.
/// The longpoll's answer then describes an earlier moment than the checkpoint now does, and writing
/// it over the newer one sends the feed backwards and replays everything in between, on every pull
/// from then on. The rows are still applied either way; only the checkpoint has to refuse to move.
final class CouchCheckpointTests: XCTestCase {

    /// Resumes waiters once opened, and stays open for anyone arriving later.
    private actor Gate {
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var isOpen = false

        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func open() {
            isOpen = true
            let resuming = waiters
            waiters = []
            for continuation in resuming { continuation.resume() }
        }
    }

    /// Answers the longpoll from the state at the moment it was *asked*, then holds it until
    /// released — which is what a longpoll does, and what makes its answer stale by the time it
    /// lands. Every other request passes straight through.
    private final class StaleFeedTransport: HTTPTransport, @unchecked Sendable {
        private let inner: HTTPTransport
        let arrived = Gate()
        let release = Gate()

        init(_ inner: HTTPTransport) { self.inner = inner }

        func send(_ request: HTTPRequest) async throws -> HTTPResponse {
            let isLongpoll = request.path.hasSuffix("_changes")
                && request.query.contains { $0.name == "feed" && $0.value == "longpoll" }
            guard isLongpoll else { return try await inner.send(request) }

            // Captured now, delivered later: the response describes the server as it was when the
            // request went out.
            let response = try await inner.send(request)
            await arrived.open()
            await release.wait()
            return response
        }
    }

    private func makeEngine(_ transport: HTTPTransport, _ store: FakeLocalStore) -> CouchSyncEngine {
        CouchSyncEngine(
            client: CouchDBClient(transport: transport, database: "notes"),
            store: store,
            deviceID: "ipad",
            state: CouchSyncState())
    }

    func testACatchUpDuringALongpollIsNotUndoneByIt() async throws {
        let server = MockCouchServer()
        let transport = StaleFeedTransport(server)
        let engine = makeEngine(transport, FakeLocalStore())

        // The longpoll goes out against an empty server and is held there.
        let longpoll = Task { try await engine.pull(longpoll: true) }
        await transport.arrived.wait()

        // While it waits, the server gains a document and a catch-up pull takes it.
        server.seedRaw(CouchDocID.notebook("nb1"), ["type": "notebook", "schema": 1])
        _ = try await engine.pull(longpoll: false)
        let afterCatchUp = await engine.currentState.lastSeq

        // Now the longpoll lands, describing the server before that document existed.
        await transport.release.open()
        _ = try await longpoll.value
        let afterLongpoll = await engine.currentState.lastSeq

        XCTAssertEqual(
            afterLongpoll, afterCatchUp,
            "a longpoll answering for an earlier moment must not drag the checkpoint back to it")
    }

    /// The checkpoint was already protected. The revision cache was not, and it is the reason the
    /// whole batch — not merely its `last_seq` — has to be dropped.
    ///
    /// `state.revs` records "the revision the next push must build on". Writing an older revision
    /// into it moves it backwards, and the next push then quotes a stale `_rev`, takes a 409 it did
    /// not need, and stops recognising this device's own writes as echoes. Merges being idempotent
    /// says nothing about that: the argument for re-applying rows was about *content*.
    func testALongpollThatLostTheRaceDoesNotRegressARevision() async throws {
        let server = MockCouchServer()
        let store = FakeLocalStore()
        let transport = StaleFeedTransport(server)
        let engine = makeEngine(transport, store)

        let notebook = CouchDocID.notebook("nb1")
        server.seedRaw(notebook, ["type": "notebook", "schema": 1, "title": "first"])
        let staleRev = try XCTUnwrap(server.revision(notebook))

        // The longpoll reads the server as it is now — nb1 at its first revision — and is held.
        let longpoll = Task { try await engine.pull(longpoll: true) }
        await transport.arrived.wait()

        // While it waits, nb1 is edited and a catch-up pull takes the newer revision.
        server.seedRaw(notebook, ["type": "notebook", "schema": 1, "title": "second"])
        let freshRev = try XCTUnwrap(server.revision(notebook))
        XCTAssertNotEqual(staleRev, freshRev)
        _ = try await engine.pull(longpoll: false)
        let stateAfterCatchUp = await engine.currentState
        XCTAssertEqual(stateAfterCatchUp.revs[notebook], freshRev)

        // Now the held longpoll lands, carrying the first revision.
        await transport.release.open()
        let report = try await longpoll.value
        let finalState = await engine.currentState

        XCTAssertEqual(
            finalState.revs[notebook], freshRev,
            "the losing batch must not write its older revision over the winner's")
        XCTAssertEqual(finalState.lastSeq, stateAfterCatchUp.lastSeq)
        XCTAssertEqual(report.discardedStaleBatches, 1)
        XCTAssertTrue(report.applied.isEmpty, "a discarded batch applied nothing")
    }

    /// The reverse order — no race at all — must still apply normally, or the guard above would be
    /// indistinguishable from a client that never pulls.
    func testAPullThatWonTheRaceAppliesItsRows() async throws {
        let server = MockCouchServer()
        let engine = makeEngine(server, FakeLocalStore())

        let notebook = CouchDocID.notebook("nb1")
        server.seedRaw(notebook, ["type": "notebook", "schema": 1])
        let report = try await engine.pull(longpoll: false)
        let state = await engine.currentState

        XCTAssertEqual(report.discardedStaleBatches, 0)
        XCTAssertEqual(state.revs[notebook], server.revision(notebook))
    }

    /// The ordinary case still has to work, or the feed would ask the same question forever.
    func testAPullOnItsOwnStillAdvancesTheCheckpoint() async throws {
        let server = MockCouchServer()
        let engine = makeEngine(server, FakeLocalStore())

        let before = await engine.currentState.lastSeq
        server.seedRaw(CouchDocID.notebook("nb1"), ["type": "notebook", "schema": 1])
        _ = try await engine.pull(longpoll: false)
        let after = await engine.currentState.lastSeq

        XCTAssertNotEqual(before, after, "a pull that applied a document must move the checkpoint")
    }
}
