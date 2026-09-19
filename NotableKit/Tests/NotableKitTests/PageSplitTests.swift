import XCTest

@testable import NotableKit

/// Cutting an endless page into one page per sheet.
///
/// The properties worth pinning are the ones that decide whether this is safe to run on every
/// page of every notebook, on two devices, for ever: it has to be idempotent, it has to agree with
/// the BOOX down to the page ids, and it must not lose or cut ink.
final class PageSplitTests: XCTestCase {

    private let sheet = PageSize(width: 1400, height: 1000)
    private let now = "2026-08-15T12:00:00.000Z"

    private func stroke(id: String, top: Float, bottom: Float) throws -> StrokeDTO {
        let points = [
            NotableStrokePoint(x: 10, y: top, pressure: 0.5),
            NotableStrokePoint(x: 20, y: bottom, pressure: 0.5),
        ]
        return StrokeDTO(
            id: id, size: 3, pen: .ballpen, color: -16_777_216, maxPressure: 1,
            top: top, bottom: bottom, left: 10, right: 20,
            pointsData: try SBStrokeCodec.encode(points).base64EncodedString(),
            createdAt: now, updatedAt: now)
    }

    private func page(_ strokes: [StrokeDTO], images: [ImageDTO] = []) -> PageFile {
        PageFile(
            id: "page-a", notebookId: "book", pageWidth: sheet.width, pageHeight: sheet.height,
            createdAt: "2026-08-01T00:00:00.000Z", updatedAt: "2026-08-01T00:00:00.000Z",
            strokes: strokes, images: images)
    }

    // MARK: Dividing

    func testAPageInsideItsSheetIsNotDivided() throws {
        let single = page([try stroke(id: "s1", top: 10, bottom: 900)])

        let result = try PageSplit.split(single, sheet: sheet, now: now, updatedBy: "ipad")

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].id, "page-a")
    }

    func testContentBelowTheSheetBecomesItsOwnPage() throws {
        let tall = page([
            try stroke(id: "s1", top: 100, bottom: 200),
            try stroke(id: "s2", top: 1100, bottom: 1200),
            try stroke(id: "s3", top: 2500, bottom: 2600),
        ])

        let result = try PageSplit.split(tall, sheet: sheet, now: now, updatedBy: "ipad")

        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result.map { $0.strokes.map(\.id) }, [["s1"], ["s2"], ["s3"]])
    }

    /// The ink is the point: a stroke moved to a new page has to arrive at the same place on it,
    /// or a page of notes comes back shifted down by however many sheets it had sunk.
    func testMovedInkLandsAtTheTopOfItsNewPage() throws {
        let tall = page([try stroke(id: "s2", top: 1100, bottom: 1200)])

        let result = try PageSplit.split(tall, sheet: sheet, now: now, updatedBy: "ipad")
        let moved = try XCTUnwrap(result.last?.strokes.first)

        XCTAssertEqual(moved.top, 100, accuracy: 0.01)
        XCTAssertEqual(moved.bottom, 200, accuracy: 0.01)
        let points = try SBStrokeCodec.decode(
            try XCTUnwrap(Data(base64Encoded: moved.pointsData)))
        XCTAssertEqual(points.map(\.y), [100, 200])
    }

    /// A descender crossing the boundary belongs to the sheet it starts on and travels whole.
    /// Cutting it would leave half a letter on each page.
    func testAStrokeCrossingTheBoundaryIsNotCut() throws {
        let tall = page([
            try stroke(id: "straddler", top: 950, bottom: 1050),
            try stroke(id: "below", top: 1500, bottom: 1600),
        ])

        let result = try PageSplit.split(tall, sheet: sheet, now: now, updatedBy: "ipad")

        XCTAssertEqual(result[0].strokes.map(\.id), ["straddler"])
        XCTAssertEqual(result[1].strokes.map(\.id), ["below"])
        XCTAssertEqual(result[0].strokes[0].bottom, 1050, accuracy: 0.01)
    }

    /// Running it a second time must be a no-op — it runs on open, so a split that kept finding
    /// work would file a fresh empty page every time a notebook was looked at.
    func testSplittingIsIdempotent() throws {
        let tall = page([
            try stroke(id: "straddler", top: 950, bottom: 1050),
            try stroke(id: "below", top: 1500, bottom: 1600),
        ])

        let once = try PageSplit.split(tall, sheet: sheet, now: now, updatedBy: "ipad")
        let twice = try once.flatMap {
            try PageSplit.split($0, sheet: sheet, now: now, updatedBy: "ipad")
        }

        XCTAssertEqual(once.map(\.id), twice.map(\.id))
        XCTAssertEqual(once.map { $0.strokes.map(\.id) }, twice.map { $0.strokes.map(\.id) })
    }

    func testNoInkIsLost() throws {
        let tall = page([
            try stroke(id: "s1", top: 0, bottom: 50),
            try stroke(id: "s2", top: 1100, bottom: 1200),
            try stroke(id: "s3", top: 2100, bottom: 2200),
            try stroke(id: "s4", top: 2900, bottom: 2950),
        ])

        let result = try PageSplit.split(tall, sheet: sheet, now: now, updatedBy: "ipad")

        XCTAssertEqual(
            Set(result.flatMap { $0.strokes.map(\.id) }), ["s1", "s2", "s3", "s4"])
        XCTAssertEqual(result.reduce(0) { $0 + $1.strokes.count }, 4)
    }

    // MARK: Identity

    /// The first sheet keeps the page's id so bookmarks and outline entries naming it survive.
    func testTheFirstSheetKeepsThePageId() throws {
        let tall = page([
            try stroke(id: "s1", top: 10, bottom: 20),
            try stroke(id: "s2", top: 1100, bottom: 1200),
        ])

        let result = try PageSplit.split(tall, sheet: sheet, now: now, updatedBy: "ipad")

        XCTAssertEqual(result[0].id, "page-a")
    }

    /// Two devices that split the same page while neither can see the other have to produce the
    /// same pages. Random ids would give the merge two rival sets and it would keep both, which is
    /// a notebook with every page in it twice.
    func testChildIdsAreDerivedFromTheParentAndNothingElse() {
        XCTAssertEqual(
            PageSplit.childId(parentId: "page-a", sheet: 1),
            PageSplit.childId(parentId: "page-a", sheet: 1))
        XCTAssertNotEqual(
            PageSplit.childId(parentId: "page-a", sheet: 1),
            PageSplit.childId(parentId: "page-a", sheet: 2))
        XCTAssertNotEqual(
            PageSplit.childId(parentId: "page-b", sheet: 1),
            PageSplit.childId(parentId: "page-a", sheet: 1))
        XCTAssertEqual(PageSplit.childId(parentId: "page-a", sheet: 0), "page-a")
    }

    /// Pinned exactly, because the BOOX computes it independently: if these two ever disagree the
    /// same split produces different pages on each device.
    ///
    /// Reproduce it without either app:
    /// `printf 'notable-page-split:page-a:1' | shasum -a 256 | cut -c1-32`
    func testTheDerivedIdIsThisExactValue() {
        XCTAssertEqual(
            PageSplit.childId(parentId: "page-a", sheet: 1),
            "82b2c548-bbc8-c002-5ea9-3e81ce812b9e")
    }

    func testDerivedIdsLookLikeEveryOtherPageId() {
        let id = PageSplit.childId(parentId: "page-a", sheet: 3)
        XCTAssertEqual(id.count, 36)
        XCTAssertEqual(id.filter { $0 == "-" }.count, 4)
        XCTAssertEqual(id, id.lowercased())
    }

    // MARK: The sheet it divides by

    /// A page that declares nothing must not be divided by "the screen" — the BOOX lays those out
    /// at its own width, and a sheet the two disagree about divides the page differently on each.
    func testAnUndeclaredPageFallsBackToTheSharedLegacySheet() {
        let undeclared = PageFile(
            id: "old", notebookId: "book", createdAt: now, updatedAt: now)

        XCTAssertEqual(
            PageSplit.sheet(for: undeclared, notebookDefault: nil), .legacyUndeclared)
    }

    func testTheNotebookDefaultIsPreferredOverTheLegacySheet() {
        let undeclared = PageFile(
            id: "old", notebookId: "book", createdAt: now, updatedAt: now)
        let a4 = PageSizePreset.a4.size

        XCTAssertEqual(PageSplit.sheet(for: undeclared, notebookDefault: a4), a4)
    }

    /// Every page the split produces says what sheet it is, so the ambiguity above is spent once
    /// rather than being re-guessed on every read for the rest of the notebook's life.
    func testEveryResultingPageDeclaresItsSheet() throws {
        let undeclared = PageFile(
            id: "old", notebookId: "book", createdAt: now, updatedAt: now,
            strokes: [
                try stroke(id: "s1", top: 10, bottom: 20),
                try stroke(id: "s2", top: 2000, bottom: 2100),
            ])

        let result = try PageSplit.split(
            undeclared, sheet: .legacyUndeclared, now: now, updatedBy: "ipad")

        XCTAssertTrue(result.count > 1)
        for produced in result {
            XCTAssertEqual(produced.pageWidth, PageSize.legacyUndeclared.width)
            XCTAssertEqual(produced.pageHeight, PageSize.legacyUndeclared.height)
        }
    }

    // MARK: Pages that declare they scroll

    /// Rule 0. Everything about this page says "divide me" — ink starting two sheets down, a
    /// declared sheet it has outgrown — and the declaration overrides all of it.
    func testAScrollPageIsNeverDivided() throws {
        var journal = page([try stroke(id: "s1", top: 2500, bottom: 2600)])
        journal.layout = PageLayout.scroll

        let result = try PageSplit.split(journal, sheet: sheet, now: now, updatedBy: "ipad")

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].id, "page-a")
        XCTAssertEqual(result[0].strokes.map(\.id), ["s1"])
        XCTAssertEqual(result[0].strokes[0].top, 2500, accuracy: 0.01)
        XCTAssertTrue(result[0].deletedStrokes.isEmpty)
    }

    /// Returned untouched, not merely undivided: `declaring` would stamp the sheet's height onto
    /// a page whose whole claim is that it has none, and the next reader would believe it.
    func testAScrollPageComesBackUnchanged() throws {
        var journal = page([try stroke(id: "s1", top: 2500, bottom: 2600)])
        journal.layout = PageLayout.scroll
        journal.pageHeight = 4000

        let result = try PageSplit.split(journal, sheet: sheet, now: now, updatedBy: "ipad")

        XCTAssertEqual(result, [journal])
    }

    func testTheSameHoldsForTheDocumentForm() throws {
        var journal = CouchPage(
            notebookId: "book", pageWidth: sheet.width, pageHeight: 4000,
            layout: PageLayout.scroll,
            strokes: [], createdAt: now, updatedAt: now, updatedBy: "ipad")
        journal.blocks = [
            CouchBlock(
                id: "b1", kind: "link", strokeIds: ["s1"], x: 10, y: 2400, width: 100, height: 40,
                targetNotebookId: "nb-other", createdAt: now, updatedAt: now)
        ]

        let result = try PageSplit.split(
            journal, id: "page-a", sheet: sheet, now: now, updatedBy: "ipad")

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].id, "page-a")
        XCTAssertEqual(result[0].page, journal)
    }

    // MARK: Journal identifiers

    /// Pinned for the same reason the split's own seed is: the BOOX computes these independently,
    /// and a disagreement would not look like a broken hash. It would look like every journal
    /// entry on one device being invisible to the other.
    ///
    /// Reproduce without either app:
    /// `printf 'notable-journal-day:2026-09-19' | shasum -a 256 | cut -c1-32`
    func testJournalIdsAreTheseExactValues() {
        XCTAssertEqual(
            DerivedID.journalNotebookId(year: 2026), "57008734-1905-d544-39b5-4e1806e663df")
        XCTAssertEqual(
            DerivedID.journalDayPageId(date: "2026-09-19"),
            "546732d7-b5b7-3e3a-36c2-5289f669308c")
        XCTAssertEqual(DerivedID.journalFolderId, "21de662f-e961-4ece-7cf5-f3c8b6f937ad")
    }

    func testTheSplitsOwnIdStillComesFromTheSharedDerivation() {
        XCTAssertEqual(
            PageSplit.childId(parentId: "page-a", sheet: 1),
            DerivedID.derive(DerivedID.pageSplitSeed(parentId: "page-a", sheet: 1)))
    }

    func testAYearIsZeroPadded() {
        XCTAssertEqual(DerivedID.journalNotebookSeed(year: 999), "notable-journal:0999")
        XCTAssertEqual(DerivedID.journalNotebookSeed(year: 2026), "notable-journal:2026")
    }

    // MARK: Images

    func testAnImageBelowTheSheetTravelsWithIt() throws {
        let tall = page(
            [try stroke(id: "s1", top: 10, bottom: 20)],
            images: [
                ImageDTO(
                    id: "img", x: 100, y: 1200, width: 300, height: 200, uri: nil,
                    createdAt: now, updatedAt: now)
            ])

        let result = try PageSplit.split(tall, sheet: sheet, now: now, updatedBy: "ipad")

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[1].images.map(\.id), ["img"])
        XCTAssertEqual(result[1].images[0].y, 200)
    }

}
