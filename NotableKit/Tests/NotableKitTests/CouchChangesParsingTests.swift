import XCTest
@testable import NotableKit

/// `_changes` parsing is strict because its result is checkpointed.
///
/// `last_seq` is persisted the moment a batch applies, and CouchDB never offers a sequence twice.
/// So a row this parser drops is a remote change lost *permanently* — the checkpoint moves past it
/// and no later pull asks about it again. The parser used to be permissive in four separate ways
/// (a missing `results` became an empty array, a malformed row was skipped, a missing revision
/// became `""`, a live row without a body was accepted), and every one of them turns a truncating
/// proxy or an unfamiliar server into silent data loss.
///
/// Refusing the whole response costs one retry. That is the trade this file pins.
final class CouchChangesParsingTests: XCTestCase {

    private let client = CouchDBClient(transport: MockCouchServer(), database: "notes")

    private func parse(_ json: String) throws -> CouchDBClient.Changes {
        try client.parseChanges(Data(json.utf8))
    }

    private func assertMalformed(
        _ json: String, _ message: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(try parse(json), message, file: file, line: line) { error in
            guard case CouchError.malformedResponse = error else {
                return XCTFail("expected malformedResponse, got \(error)", file: file, line: line)
            }
        }
    }

    // MARK: Rejected

    func testAResponseWithoutResultsIsRejected() {
        assertMalformed(
            #"{"last_seq": "5"}"#,
            "no results array is not the same fact as an empty one")
    }

    func testAResultsPropertyOfTheWrongTypeIsRejected() {
        assertMalformed(#"{"results": {}, "last_seq": "5"}"#, "results must be an array")
    }

    func testANonObjectRowIsRejected() {
        assertMalformed(#"{"results": ["nope"], "last_seq": "5"}"#, "a row must be an object")
    }

    func testARowWithoutAnIDIsRejected() {
        assertMalformed(
            #"{"results": [{"changes": [{"rev": "1-a"}], "doc": {}}], "last_seq": "5"}"#,
            "a row with no id names no document")
    }

    func testARowWithAnEmptyIDIsRejected() {
        assertMalformed(
            #"{"results": [{"id": "", "changes": [{"rev": "1-a"}], "doc": {}}], "last_seq": "5"}"#,
            "an empty id names no document either")
    }

    func testARowWithoutARevisionIsRejected() {
        assertMalformed(
            #"{"results": [{"id": "notebook:nb1", "doc": {}}], "last_seq": "5"}"#,
            "the revision is the base the next push builds on; \"\" is not a revision")
    }

    func testARowWithAnEmptyRevisionIsRejected() {
        assertMalformed(
            #"{"results": [{"id": "notebook:nb1", "changes": [{"rev": ""}], "doc": {}}], "last_seq": "5"}"#,
            "an empty revision would be recorded as if it were real")
    }

    func testALiveRowWithoutADocumentIsRejected() {
        assertMalformed(
            #"{"results": [{"id": "notebook:nb1", "changes": [{"rev": "1-a"}]}], "last_seq": "5"}"#,
            "include_docs was asked for; a live row without one is a truncated response")
    }

    func testALiveRowWithANullDocumentIsRejected() {
        assertMalformed(
            #"{"results": [{"id": "notebook:nb1", "changes": [{"rev": "1-a"}], "doc": null}], "last_seq": "5"}"#,
            "an explicit null body on a live row is no better than a missing one")
    }

    func testANonBooleanDeletedIsRejected() {
        assertMalformed(
            #"{"results": [{"id": "notebook:nb1", "changes": [{"rev": "1-a"}], "deleted": "yes", "doc": {}}], "last_seq": "5"}"#,
            "a deleted flag that is not a Boolean is a server this client does not understand")
    }

    /// `JSONSerialization` renders every JSON scalar as `NSNumber`, so a plain `as? Bool` also
    /// accepts `1` — and would then read a *count* as a deletion.
    func testANumericDeletedIsRejected() {
        assertMalformed(
            #"{"results": [{"id": "notebook:nb1", "changes": [{"rev": "1-a"}], "deleted": 1, "doc": {}}], "last_seq": "5"}"#,
            "1 is not true")
    }

    func testAResponseWithoutALastSeqIsRejected() {
        assertMalformed(#"{"results": []}"#, "there is no checkpoint to persist")
    }

    // MARK: Accepted

    func testAnEmptyResultsArrayIsAValidQuietFeed() throws {
        let changes = try parse(#"{"results": [], "last_seq": "9"}"#)
        XCTAssertEqual(changes.lastSeq, "9")
        XCTAssertTrue(changes.rows.isEmpty)
    }

    func testATombstoneMayArriveWithoutABody() throws {
        // The one body CouchDB legitimately omits: `include_docs` found the document already
        // deleted. The engine synthesizes what the merge needs from `deleted` and the revision, so
        // rejecting this would break ordinary deletions rather than catch a fault.
        let changes = try parse(
            #"{"results": [{"id": "notebook:nb1", "changes": [{"rev": "2-b"}], "deleted": true, "doc": null}], "last_seq": "9"}"#)
        let row = try XCTUnwrap(changes.rows.first)
        XCTAssertEqual(row.id, "notebook:nb1")
        XCTAssertEqual(row.rev, "2-b")
        XCTAssertTrue(row.deleted)
        XCTAssertNil(row.json)
    }

    func testATombstoneMayAlsoArriveWithItsBody() throws {
        let changes = try parse(
            #"{"results": [{"id": "notebook:nb1", "changes": [{"rev": "2-b"}], "deleted": true, "doc": {"_id": "notebook:nb1", "_deleted": true}}], "last_seq": "9"}"#)
        let row = try XCTUnwrap(changes.rows.first)
        XCTAssertTrue(row.deleted)
        XCTAssertNotNil(row.json)
    }

    func testANumericLastSeqIsKeptAsItsText() throws {
        // CouchDB 1.x reported a number. It is only ever echoed back, so the shape it arrived in is
        // the shape to keep.
        let changes = try parse(#"{"results": [], "last_seq": 42}"#)
        XCTAssertEqual(changes.lastSeq, "42")
    }

    func testAValidRowSurvivesIntact() throws {
        let changes = try parse(
            #"{"results": [{"id": "notebook:nb1", "changes": [{"rev": "1-a"}], "doc": {"type": "notebook", "schema": 1}}], "last_seq": "5"}"#)
        let row = try XCTUnwrap(changes.rows.first)
        XCTAssertEqual(row.id, "notebook:nb1")
        XCTAssertEqual(row.rev, "1-a")
        XCTAssertFalse(row.deleted)
        let body = try XCTUnwrap(row.json)
        let decoded = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(decoded["type"] as? String, "notebook")
    }

    /// The failure has to arrive as a *throw*, not as a short batch: a parser that returned the
    /// good rows and dropped the rest would still have the engine checkpoint past the bad one.
    func testAMalformedSecondRowRejectsTheWholeResponse() {
        assertMalformed(
            """
            {"results": [
              {"id": "notebook:nb1", "changes": [{"rev": "1-a"}], "doc": {"type": "notebook"}},
              {"id": "notebook:nb2", "changes": [{"rev": "1-b"}]}
            ], "last_seq": "7"}
            """,
            "one bad row poisons the batch — the good row is returned again on the retry")
    }
}
