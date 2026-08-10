import XCTest
@testable import NotableKit

final class CouchTombstoneTests: XCTestCase {

    private func stamp(_ second: Int) -> String {
        NotableDate.format(Date(timeIntervalSince1970: 1_770_000_000 + Double(second)))
    }

    func testDepartedStrokesBecomeTombstones() {
        let result = CouchTombstones.derive(
            previousIDs: ["s1", "s2", "s3"], currentIDs: ["s1", "s3"],
            existing: [], deletedAt: stamp(10))
        XCTAssertEqual(result.map(\.id), ["s2"])
        XCTAssertEqual(result.first?.deletedAt, stamp(10))
    }

    func testNewStrokesDoNotProduceTombstones() {
        let result = CouchTombstones.derive(
            previousIDs: ["s1"], currentIDs: ["s1", "s2"], existing: [], deletedAt: stamp(10))
        XCTAssertTrue(result.isEmpty)
    }

    /// Re-stamping an existing tombstone would let a much later time win a delete-vs-edit
    /// comparison it should lose.
    func testAnAlreadyRecordedDeletionKeepsItsOriginalTime() {
        let existing = [CouchTombstone(id: "s2", deletedAt: stamp(5))]
        let result = CouchTombstones.derive(
            previousIDs: ["s1"], currentIDs: ["s1"], existing: existing, deletedAt: stamp(99))
        XCTAssertEqual(result, existing)
    }

    func testResultIsSortedSoTheEncodedDocumentIsStable() {
        let result = CouchTombstones.derive(
            previousIDs: ["b", "a", "c"], currentIDs: [], existing: [], deletedAt: stamp(1))
        XCTAssertEqual(result.map(\.id), ["a", "b", "c"])
    }

    func testRecordErasuresUpdatesThePageInPlace() {
        var page = CouchPage(
            notebookId: "nb", strokes: [], createdAt: stamp(0), updatedAt: stamp(1),
            updatedBy: "ipad")
        CouchTombstones.recordErasures(
            in: &page, previousStrokeIDs: ["s1", "s2"], deletedAt: stamp(3))
        XCTAssertEqual(page.deletedStrokes.map(\.id), ["s1", "s2"])
    }

    func testPruningDropsOnlyOldTombstones() {
        let now = Date(timeIntervalSince1970: 1_770_000_000)
        let recent = CouchTombstone(
            id: "recent",
            deletedAt: NotableDate.format(now.addingTimeInterval(-24 * 60 * 60)))
        let ancient = CouchTombstone(
            id: "ancient",
            deletedAt: NotableDate.format(now.addingTimeInterval(-60 * 24 * 60 * 60)))

        let result = CouchTombstones.prune([recent, ancient], now: now)
        XCTAssertEqual(result.map(\.id), ["recent"])
    }

    func testPruningKeepsTombstonesItCannotDate() {
        let unparseable = CouchTombstone(id: "x", deletedAt: "whenever")
        let result = CouchTombstones.prune(
            [unparseable], now: Date(timeIntervalSince1970: 1_770_000_000))
        XCTAssertEqual(result, [unparseable], "a tombstone that cannot be dated must not be dropped")
    }

    /// The property that makes tombstones worth having: after a merge, a re-save on the device
    /// that still had the stroke must not resurrect it.
    func testDerivedTombstoneSurvivesAMergeRoundTrip() {
        var erased = CouchPage(
            notebookId: "nb", strokes: [], createdAt: stamp(0), updatedAt: stamp(10),
            updatedBy: "boox")
        CouchTombstones.recordErasures(in: &erased, previousStrokeIDs: ["s1"], deletedAt: stamp(10))

        let stillHasIt = CouchPage(
            notebookId: "nb",
            strokes: [CouchStroke(
                id: "s1", createdAt: stamp(1), updatedAt: stamp(1), deviceId: "ipad",
                pen: "BALLPEN", color: -16_777_216, size: 3,
                top: 0, bottom: 1, left: 0, right: 1, pointsData: "AAA=")],
            createdAt: stamp(0), updatedAt: stamp(5), updatedBy: "ipad")

        XCTAssertTrue(CouchMerge.merge(erased, stillHasIt).strokes.isEmpty)
        XCTAssertTrue(CouchMerge.merge(stillHasIt, erased).strokes.isEmpty)
    }
}
