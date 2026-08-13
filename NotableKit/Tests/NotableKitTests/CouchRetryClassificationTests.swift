import XCTest
@testable import NotableKit

/// Which failures are worth trying again, and when.
///
/// Every `server` status used to answer "retriable", so a request the server had already refused on
/// its merits — a document over the configured maximum, a malformed request, a database this
/// account may not write to — was retried on the same escalating schedule as a dropped connection,
/// forever. The user saw a sync that never settled and never explained itself.
///
/// The line is whether *waiting* is plausibly part of the answer.
final class CouchRetryClassificationTests: XCTestCase {

    private func server(_ status: Int, retryAfter: TimeInterval? = nil) -> CouchError {
        .server(status: status, path: "/notes/doc", retryAfter: retryAfter)
    }

    // MARK: Classification

    func testTransientStatusesAreWorthRetrying() {
        for status in [408, 425, 429, 500, 502, 503, 504, 599] {
            XCTAssertTrue(
                server(status).isRetriable, "\(status) says come back later, or is the server's own")
        }
    }

    func testTerminalStatusesAreNot() {
        // 400 malformed, 405 wrong method, 412 precondition, 413 too large, 415 wrong type,
        // 422 unprocessable, 431 headers too large. None improves by asking again.
        for status in [400, 402, 405, 406, 410, 412, 413, 415, 422, 431] {
            XCTAssertFalse(
                server(status).isRetriable, "\(status) will be refused again on the same terms")
        }
    }

    func testATransportFailureIsAlwaysWorthRetrying() {
        XCTAssertTrue(CouchError.transport("offline").isRetriable)
    }

    func testTheErrorsWithTheirOwnHandlingAreNotBlindlyRetried() {
        XCTAssertFalse(CouchError.unauthorized.isRetriable, "a wrong password does not age out")
        XCTAssertFalse(CouchError.conflict(documentID: "d").isRetriable, "the merge loop owns this")
        XCTAssertFalse(CouchError.notFound(path: "/notes/d").isRetriable)
        XCTAssertFalse(CouchError.malformedResponse("bad").isRetriable)
    }

    // MARK: Retry-After

    func testADelayInSecondsIsRead() {
        XCTAssertEqual(CouchDBClient.retryAfter("30"), 30)
    }

    func testAnHTTPDateIsReadAsTheIntervalUntilIt() throws {
        let soon = Date().addingTimeInterval(20)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"

        let parsed = try XCTUnwrap(CouchDBClient.retryAfter(formatter.string(from: soon)))
        XCTAssertEqual(parsed, 20, accuracy: 2)
    }

    /// The server gets to slow this device down, not to switch it off: a misconfigured proxy
    /// answering with a day would otherwise park sync until the app was relaunched.
    func testAnAbsurdDelayIsClampedToTheRetryCeiling() {
        XCTAssertEqual(CouchDBClient.retryAfter("86400"), CouchDBClient.maxRetryAfter)
    }

    /// A date that has already passed means "now", not a negative sleep.
    func testAPastDateIsClampedToZero() {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let past = formatter.string(from: Date().addingTimeInterval(-3600))

        XCTAssertEqual(CouchDBClient.retryAfter(past), 0)
    }

    func testAnUnparsableOrAbsentHeaderIsSimplyNoAnswer() {
        XCTAssertNil(CouchDBClient.retryAfter(nil))
        XCTAssertNil(CouchDBClient.retryAfter(""))
        XCTAssertNil(CouchDBClient.retryAfter("   "))
        XCTAssertNil(CouchDBClient.retryAfter("soon please"))
    }

    func testTheHeaderReachesTheErrorTheCallerSees() async throws {
        let transport = RetryAfterTransport(status: 429, header: "12")
        let client = CouchDBClient(transport: transport, database: "notes")

        do {
            _ = try await client.changes(since: "0", longpoll: false)
            XCTFail("a 429 should have thrown")
        } catch let error as CouchError {
            XCTAssertTrue(error.isRetriable)
            XCTAssertEqual(error.retryAfter, 12)
        }
    }

    func testOnlyServerErrorsCarryARetryAfter() {
        XCTAssertNil(CouchError.transport("offline").retryAfter)
        XCTAssertNil(server(503).retryAfter, "absent header, not a defaulted one")
    }

    private struct RetryAfterTransport: HTTPTransport {
        let status: Int
        let header: String

        func send(_ request: HTTPRequest) async throws -> HTTPResponse {
            HTTPResponse(status: status, headers: ["Retry-After": header], body: Data())
        }
    }
}
