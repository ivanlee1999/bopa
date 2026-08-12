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
