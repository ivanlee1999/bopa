import XCTest
@testable import NotableKit

/// The exact shape of the change-feed request, pinned because one of its parameters is a trap.
///
/// notable found this the hard way (its PR #22): CouchDB treats `heartbeat` as *overriding*
/// `timeout` — given both, it holds the connection open until something actually changes, however
/// long that takes, and the keep-alive bytes reset the client's idle timer in turn, so the call
/// never returns on its own. Sync goes quietly dead until something happens to change on the
/// server. The parameter must not creep back in with a well-meaning "keep proxies from dropping
/// the connection" comment, which is exactly how it got there the first time — on both sides.
final class ChangesFeedRequestTests: XCTestCase {

    private final class RecordingTransport: HTTPTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var _requests: [HTTPRequest] = []
        var requests: [HTTPRequest] { lock.withLock { _requests } }

        func send(_ request: HTTPRequest) async throws -> HTTPResponse {
            lock.withLock { _requests.append(request) }
            return HTTPResponse(
                status: 200, body: Data(#"{"results": [], "last_seq": "0"}"#.utf8))
        }
    }

    func testALongpollAsksForATimeoutAndNeverAHeartbeat() async throws {
        let transport = RecordingTransport()
        let client = CouchDBClient(transport: transport, database: "notes")

        _ = try await client.changes(since: "0", longpoll: true, timeoutMs: 55_000)

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertTrue(request.query.contains(HTTPQueryItem("timeout", "55000")))
        XCTAssertFalse(
            request.query.contains { $0.name == "heartbeat" },
            "heartbeat overrides timeout on the server — the feed would never come back")
        // And the client outlasts the window it asked the server to hold: without a per-request
        // deadline the session default (60s) leaves five seconds of margin over a 55s park.
        XCTAssertEqual(request.timeout, 70)
    }

    /// A long poll used to be sent with no `limit` at all, on the reasoning that it is one wait for
    /// one notification. But the batch that follows a wait is everything that changed *while* it
    /// waited: after a day offline, or behind a proxy that buffered, that is the whole backlog in
    /// one response with every page's base64 ink inlined — the response paging exists to prevent.
    func testALongpollIsBoundedByTheSameBatchLimitAsACatchUp() async throws {
        let transport = RecordingTransport()
        let client = CouchDBClient(transport: transport, database: "notes")

        _ = try await client.changes(
            since: "0", longpoll: true, timeoutMs: 55_000,
            limit: CouchSyncEngine.catchUpBatchSize)

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertTrue(request.query.contains(HTTPQueryItem("limit", "100")))
    }

    func testACatchUpReadCarriesNeitherTimeoutNorDeadline() async throws {
        let transport = RecordingTransport()
        let client = CouchDBClient(transport: transport, database: "notes")

        _ = try await client.changes(since: "0", longpoll: false)

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertFalse(request.query.contains { $0.name == "timeout" || $0.name == "heartbeat" })
        XCTAssertNil(request.timeout, "a normal read returns at once; the default is right")
    }
}
