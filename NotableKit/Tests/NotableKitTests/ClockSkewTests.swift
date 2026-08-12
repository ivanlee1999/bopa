import Foundation
import XCTest
@testable import NotableKit

/// Protocol §7, "Clock skew": every response carries the server's `Date`, and a device whose own
/// clock disagrees with it by two minutes or more is told so. The merge is wall-clock ordered, so
/// a wrong clock does not fail — it silently changes which version of a page wins.
final class ClockSkewTests: XCTestCase {

    /// Answers every request with one canned response. Nothing here is about CouchDB's semantics:
    /// the observation happens on the way back from the transport, whatever was asked for.
    private struct StubTransport: HTTPTransport {
        var headers: [String: String]

        func send(_ request: HTTPRequest) async throws -> HTTPResponse {
            HTTPResponse(
                status: 200, headers: headers,
                body: Data(#"{"_id":"notebook:n1","_rev":"1-a"}"#.utf8))
        }
    }

    /// `serverTime` as an origin server would stamp it, offset from the local clock by `skew`
    /// seconds — positive meaning this device runs ahead.
    private func observe(
        skewSeconds: Double?, header: String? = nil, now: Date = Date()
    ) async -> ClockSkew? {
        var headers: [String: String] = [:]
        if let header {
            headers["Date"] = header
        } else if let skewSeconds {
            headers["Date"] = imfFixdate(now.addingTimeInterval(-skewSeconds))
        }
        let monitor = ClockSkewMonitor()
        let client = CouchDBClient(
            transport: StubTransport(headers: headers), database: "notes", clockSkew: monitor)
        _ = try? await client.getRaw("notebook:n1")
        return await monitor.significantSkew
    }

    private func imfFixdate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.string(from: date)
    }

    /// A clock-ahead device wins comparisons it should lose — and a clock-ahead *deletion*
    /// destroys work made after it. That is the direction worth naming out loud.
    func testAClockRunningAheadOfTheServerIsReported() async {
        let skew = await observe(skewSeconds: 3_600)
        guard let skew else { return XCTFail("an hour of skew should have been reported") }
        XCTAssertTrue(skew.isAhead)
        XCTAssertEqual(skew.seconds, 3_600, accuracy: 2)
        XCTAssertTrue(skew.summary.contains("ahead of"), skew.summary)
        XCTAssertTrue(skew.summary.contains("1 hours") || skew.summary.contains("60 minutes"),
                      "the magnitude has to be in there to be actionable: \(skew.summary)")
    }

    func testAClockRunningBehindTheServerIsReported() async {
        let skew = await observe(skewSeconds: -600)
        guard let skew else { return XCTFail("ten minutes of skew should have been reported") }
        XCTAssertFalse(skew.isAhead)
        XCTAssertEqual(skew.seconds, -600, accuracy: 2)
        XCTAssertTrue(skew.summary.contains("behind"), skew.summary)
        XCTAssertTrue(skew.summary.contains("10 minutes"), skew.summary)
    }

    /// The threshold is deliberately loose. The header has one-second granularity and is stamped
    /// before the response travels, so a strict comparison would warn about healthy setups — and a
    /// warning that fires when nothing is wrong is one nobody reads when something is.
    func testSkewBelowTheThresholdIsNotReported() async {
        let justUnder = await observe(skewSeconds: ClockSkewMonitor.significantSeconds - 5)
        XCTAssertNil(justUnder)
        let none = await observe(skewSeconds: 0)
        XCTAssertNil(none)
        let halfAMinuteBehind = await observe(skewSeconds: -30)
        XCTAssertNil(halfAMinuteBehind)
    }

    func testTheThresholdItselfCounts() async {
        let atThreshold = await observe(skewSeconds: ClockSkewMonitor.significantSeconds)
        XCTAssertNotNil(atThreshold, "120s is 'at or above', not 'above'")
    }

    /// No header, or one that will not parse, is *no information* — not a warning and not an
    /// error. Guessing a skew from a header this cannot read would invent the very problem the
    /// check exists to detect.
    func testAMissingOrUnreadableDateHeaderSaysNothing() async {
        let absent = await observe(skewSeconds: nil)
        XCTAssertNil(absent, "no Date header at all")
        let garbage = await observe(skewSeconds: nil, header: "not a date")
        XCTAssertNil(garbage)
        let empty = await observe(skewSeconds: nil, header: "")
        XCTAssertNil(empty)
        // ISO-8601 rather than IMF-fixdate: readable to a human, not to this parser, and treated
        // the same as silence rather than being half-guessed.
        let wrongFormat = await observe(skewSeconds: nil, header: "2026-08-12T11:00:00Z")
        XCTAssertNil(wrongFormat)
    }

    /// Advisory means advisory: the request whose response carried the skew still succeeded, and
    /// the engine went on syncing.
    func testASkewedClockDoesNotFailTheRequest() async throws {
        let monitor = ClockSkewMonitor()
        let transport = StubTransport(headers: [
            "Date": imfFixdate(Date().addingTimeInterval(-7_200))
        ])
        let client = CouchDBClient(transport: transport, database: "notes", clockSkew: monitor)

        let document = try await client.getRaw("notebook:n1")

        XCTAssertEqual(document?.rev, "1-a", "the read should have succeeded regardless")
        let skew = await monitor.significantSkew
        XCTAssertNotNil(skew)
    }

    /// The question is whether the clocks disagree *now*, so a later response that looks fine
    /// clears the warning — otherwise fixing the clock would leave the message on screen until
    /// the app was restarted.
    func testAResponseWithinToleranceClearsAnEarlierWarning() async {
        let monitor = ClockSkewMonitor()
        let now = Date()
        await monitor.observe(
            HTTPResponse(status: 200, headers: ["Date": imfFixdate(now.addingTimeInterval(-900))]),
            receivedAt: now)
        var skew = await monitor.significantSkew
        XCTAssertNotNil(skew)

        await monitor.observe(
            HTTPResponse(status: 200, headers: ["Date": imfFixdate(now)]), receivedAt: now)
        skew = await monitor.significantSkew
        XCTAssertNil(skew)

        // Silence, on the other hand, is not evidence of anything: the last real answer stands.
        await monitor.observe(
            HTTPResponse(status: 200, headers: ["Date": imfFixdate(now.addingTimeInterval(-900))]),
            receivedAt: now)
        await monitor.observe(HTTPResponse(status: 200), receivedAt: now)
        skew = await monitor.significantSkew
        XCTAssertEqual(skew?.seconds ?? 0, 900, accuracy: 2)
    }

    /// The engine hands the observation on, because the controller only ever sees reports.
    func testTheFlushAndPullReportsCarryTheSkew() async throws {
        let server = MockCouchServer()
        server.dateHeader = imfFixdate(Date().addingTimeInterval(-7_200))
        let store = FakeLocalStore()
        let engine = CouchSyncEngine(
            client: CouchDBClient(
                transport: server, database: "notes", clockSkew: ClockSkewMonitor()),
            store: store, deviceID: "ipad")

        let pull = try await engine.pull()
        XCTAssertEqual(pull.clockSkew?.seconds ?? 0, 7_200, accuracy: 5)

        store.set(CouchDocID.notebook("n1"), .notebook(CouchNotebook(
            title: "Ideas", pageIds: [], createdAt: "", updatedAt: "", updatedBy: "ipad")))
        await engine.markDirty([CouchDocID.notebook("n1")])
        let flush = await engine.flush()
        XCTAssertEqual(flush.pushed, [CouchDocID.notebook("n1")], "sync carries on regardless")
        XCTAssertEqual(flush.clockSkew?.seconds ?? 0, 7_200, accuracy: 5)
    }
}
