import NotableKit
import PencilKit
import XCTest

@testable import Bopa

/// Moving between pages by scrolling, as the editor model sees it: what a crossing writes, where
/// it lands, and what is read ahead so that it can land without stalling the scroll.
@MainActor
final class SeamNavigationTests: XCTestCase {
    private var rootURL: URL!
    private var store: NotebookStore!
    private var notebookId = ""

    override func setUp() async throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("bopa-seam-test-\(UUID().uuidString)")
        store = NotebookStore(rootURL: rootURL)
        notebookId = try store.createNotebook(title: "Notes").notebookId
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: rootURL)
    }

    private var pageIds: [String] { store.manifest(id: notebookId)?.pageIds ?? [] }

    private func makeModel() -> EditorPageModel {
        let model = EditorPageModel()
        model.attach(store: store, notebookId: notebookId)
        return model
    }

    private func pageData(_ pageId: String) throws -> Data {
        try Data(contentsOf: rootURL.appendingPathComponent(
            "notebooks/\(notebookId)/pages/\(pageId).json"))
    }

    /// A stroke running down from `y`, with real point data so it survives PencilKit.
    private func makeStroke(id: String, y: Float, second: Int = 0) throws -> StrokeDTO {
        let points = [
            NotableStrokePoint(x: 10, y: y, pressure: 0.5),
            NotableStrokePoint(x: 60, y: y + 30, pressure: 0.5),
        ]
        let created = String(format: "2026-08-15T00:00:%02d.000Z", second)
        return StrokeDTO(
            id: id, size: 3, pen: .ballpen, color: -16_777_216,
            top: y, bottom: y + 30, left: 10, right: 60,
            pointsData: try SBStrokeCodec.encode(points).base64EncodedString(),
            createdAt: created, updatedAt: created)
    }

    // MARK: What a crossing writes

    /// Scrolling through a page is not an edit. Writing the page for its scroll position alone
    /// put a disk write, a library rescan and a sync push into every crossing.
    func testCrossingDoesNotRewriteAPageWhoseOnlyChangeIsItsScroll() throws {
        let first = pageIds[0]
        let second = try store.addPage(to: notebookId)
        let model = makeModel()
        XCTAssertTrue(model.open(pageId: first))
        let before = try pageData(first)

        model.liveState.pageY = 900
        XCTAssertTrue(model.enterNextPageAcrossSeam(carrying: 20))

        XCTAssertEqual(model.pageId, second.id)
        XCTAssertEqual(try pageData(first), before)
    }

    /// Ink is another matter: whatever was drawn is written before the page is left.
    func testCrossingStillWritesUnsavedInk() throws {
        let first = pageIds[0]
        _ = try store.addPage(to: notebookId)
        let model = makeModel()
        XCTAssertTrue(model.open(pageId: first))
        model.drawing = PencilKitBridge.drawing(from: [try makeStroke(id: "ink", y: 100)])
        model.scheduleSave()

        XCTAssertTrue(model.enterNextPageAcrossSeam(carrying: 0))

        XCTAssertEqual(try store.loadPage(notebookId: notebookId, pageId: first).strokes.count, 1)
    }

    /// Leaving a page any other way still remembers where it was scrolled to.
    func testAnExplicitPageChangeStillRemembersTheScroll() throws {
        let first = pageIds[0]
        let second = try store.addPage(to: notebookId)
        let model = makeModel()
        XCTAssertTrue(model.open(pageId: first))

        model.liveState.pageY = 300
        XCTAssertTrue(model.open(pageId: second.id))

        XCTAssertEqual(try store.loadPage(notebookId: notebookId, pageId: first).scroll, 300)
    }

    // MARK: Where a crossing lands

    func testCrossingForwardLandsAtTheCarriedScroll() throws {
        _ = try store.addPage(to: notebookId)
        let model = makeModel()
        XCTAssertTrue(model.open(pageId: pageIds[0]))
        XCTAssertTrue(model.enterNextPageAcrossSeam(carrying: 120))
        XCTAssertEqual(model.openScroll, 120)
    }

    /// Going up, the position is known relative to the page being left — whose top is the end of
    /// the page above — so it lands measured from that page's end.
    func testCrossingBackwardLandsMeasuredFromTheEndOfThePageAbove() throws {
        let first = pageIds[0]
        let second = try store.addPage(to: notebookId)
        let model = makeModel()
        XCTAssertTrue(model.open(pageId: second.id))

        XCTAssertTrue(model.enterPreviousPageAcrossSeam(carrying: -400))

        XCTAssertEqual(model.pageId, first)
        let height = CGFloat(try store.loadPage(notebookId: notebookId, pageId: first)
            .pageSize.height)
        XCTAssertEqual(model.openScroll, height - 400)
    }

    func testThereIsNothingToCrossIntoAboveTheFirstPage() {
        let model = makeModel()
        XCTAssertTrue(model.open(pageId: pageIds[0]))
        XCTAssertFalse(model.enterPreviousPageAcrossSeam(carrying: -400))
        XCTAssertEqual(model.pageId, pageIds[0])
    }

    // MARK: Reading ahead

    /// Both neighbours are read and pictured while the reader is still on the page between
    /// them, so the seam above and the seam below both have something to show.
    func testBothNeighboursArePreparedAhead() async throws {
        let first = pageIds[0]
        let second = try store.addPage(to: notebookId)
        let third = try store.addPage(to: notebookId)
        let model = makeModel()
        XCTAssertTrue(model.open(pageId: second.id))

        await model.waitForNeighbors()

        XCTAssertEqual(model.previousPagePreview?.pageId, first)
        XCTAssertEqual(model.nextPagePreview?.pageId, third.id)
    }

    /// A page opened from what was read ahead is the page on disk, ink and all.
    func testAPageOpenedFromTheReadAheadMatchesTheFile() async throws {
        let second = try store.addPage(to: notebookId)
        var page = try store.loadPage(notebookId: notebookId, pageId: second.id)
        page.strokes = [
            try makeStroke(id: "a", y: 100, second: 0), try makeStroke(id: "b", y: 300, second: 1),
        ]
        try store.savePage(page)
        let model = makeModel()
        XCTAssertTrue(model.open(pageId: pageIds[0]))
        await model.waitForNeighbors()
        XCTAssertNotNil(model.nextPagePreview?.content, "the picture below the seam shows the ink")

        XCTAssertTrue(model.enterNextPageAcrossSeam(carrying: 0))

        XCTAssertEqual(model.drawing.strokes.count, 2)
        XCTAssertEqual(model.page, try store.loadPage(notebookId: notebookId, pageId: second.id))
    }

    /// Read-ahead is a copy, and a copy goes stale: ink that reaches the neighbour after it was
    /// read — from the BOOX, or filed there across a seam — must be on the page when it opens.
    func testAStaleReadAheadIsNotWhatOpens() async throws {
        let second = try store.addPage(to: notebookId)
        let model = makeModel()
        XCTAssertTrue(model.open(pageId: pageIds[0]))
        await model.waitForNeighbors()

        var page = try store.loadPage(notebookId: notebookId, pageId: second.id)
        page.strokes = [try makeStroke(id: "late", y: 100)]
        try store.savePage(page)
        XCTAssertTrue(model.enterNextPageAcrossSeam(carrying: 0))

        XCTAssertEqual(model.drawing.strokes.count, 1)
    }

    // MARK: Ink above the page

    /// Ink written in the room above the page, over the page above, is filed onto that page —
    /// shifted into its coordinates, where the eye put it.
    func testInkJustDrawnAboveThePageMovesToThePageAbove() throws {
        let first = pageIds[0]
        let second = try store.addPage(to: notebookId)
        let model = makeModel()
        XCTAssertTrue(model.open(pageId: second.id))
        let drawing = PencilKitBridge.drawing(from: [
            try makeStroke(id: "here", y: 100, second: 0),
            try makeStroke(id: "above", y: -100, second: 1),
        ])

        let remaining = model.fileInkAboveTheTop(from: drawing, newStrokes: 1..<2)

        XCTAssertEqual(remaining?.strokes.count, 1)
        XCTAssertGreaterThanOrEqual(remaining?.strokes.first?.renderBounds.minY ?? -1, 0)
        let above = try store.loadPage(notebookId: notebookId, pageId: first)
        XCTAssertEqual(above.strokes.count, 1)
        let height = Float(above.pageSize.height)
        XCTAssertEqual(above.strokes.first?.top ?? 0, height - 100, accuracy: 10)
    }

    /// Only what was just drawn moves. Ink already on the page that happens to start above its
    /// top is this page's, and lifting the pencil elsewhere must not carry it off.
    func testInkAlreadyAboveThePageStaysPut() throws {
        let second = try store.addPage(to: notebookId)
        let model = makeModel()
        XCTAssertTrue(model.open(pageId: second.id))
        let drawing = PencilKitBridge.drawing(from: [
            try makeStroke(id: "old", y: -100, second: 0),
            try makeStroke(id: "new", y: 100, second: 1),
        ])

        XCTAssertNil(model.fileInkAboveTheTop(from: drawing, newStrokes: 1..<2))
        XCTAssertTrue(try store.loadPage(notebookId: notebookId, pageId: pageIds[0]).strokes.isEmpty)
    }

    /// A line written along the very top of the sheet pokes above it by the width of the nib.
    /// That is still this page's ink, not the page above's.
    func testInkThatOnlyGrazesTheTopStaysOnThePage() throws {
        let second = try store.addPage(to: notebookId)
        let model = makeModel()
        XCTAssertTrue(model.open(pageId: second.id))
        let drawing = PencilKitBridge.drawing(from: [try makeStroke(id: "grazing", y: -3)])
        XCTAssertLessThan(drawing.strokes[0].renderBounds.minY, 0, "the nib reaches above")

        XCTAssertNil(model.fileInkAboveTheTop(from: drawing, newStrokes: 0..<1))
    }

    /// Sync can land a page before the image it shows. A copy read in that gap must not be what
    /// opens once the image has arrived — the file did not change to say so.
    func testAReadAheadMissingAnImageIsNotWhatOpens() async throws {
        let second = try store.addPage(to: notebookId)
        var page = try store.loadPage(notebookId: notebookId, pageId: second.id)
        page.images = [
            ImageDTO(
                id: "late-image", x: 10, y: 10, width: 100, height: 100,
                uri: "images/late.png", createdAt: "2026-08-15T00:00:00.000Z",
                updatedAt: "2026-08-15T00:00:00.000Z")
        ]
        try store.savePage(page)
        let model = makeModel()
        XCTAssertTrue(model.open(pageId: pageIds[0]))
        await model.waitForNeighbors()

        let images = store.notebookDirURL(notebookId).appendingPathComponent("images")
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        let png = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).pngData { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        try png.write(to: images.appendingPathComponent("late.png"))
        XCTAssertTrue(model.enterNextPageAcrossSeam(carrying: 0))

        XCTAssertEqual(model.pageImages.count, 1)
    }

    /// Pagination draws no neighbours, so none are pictured — but they are still read ahead.
    func testPaginationPicturesNoNeighbours() async throws {
        _ = try store.addPage(to: notebookId)
        let model = makeModel()
        model.previewsNeighbors = false
        XCTAssertTrue(model.open(pageId: pageIds[0]))
        await model.waitForNeighbors()
        XCTAssertNil(model.nextPagePreview)

        model.previewsNeighbors = true
        await model.waitForNeighbors()
        XCTAssertNotNil(model.nextPagePreview, "switching to continuous scrolling pictures them")
    }
}
