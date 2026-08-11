import NotableKit
import XCTest

@testable import Bopa

/// What the store has to do for CouchDB sync: record erasures, stamp the writing device, and
/// name the documents each mutation touched so sync queues exactly those.
@MainActor
final class NotebookStoreCouchTests: XCTestCase {
    private var rootURL: URL!
    private var store: NotebookStore!
    private var changed: [[String]] = []

    override func setUp() async throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("bopa-couch-store-\(UUID().uuidString)")
        store = NotebookStore(rootURL: rootURL)
        store.deviceID = "ipad"
        changed = []
        store.didChangeDocuments = { [weak self] ids in self?.changed.append(ids) }
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: rootURL)
    }

    private func stroke(_ id: String) -> StrokeDTO {
        StrokeDTO(
            id: id, size: 3, pen: .ballpen, color: -16_777_216, maxPressure: 1,
            top: 0, bottom: 1, left: 0, right: 1, pointsData: "AAA=",
            createdAt: NotableDate.format(Date()), updatedAt: NotableDate.format(Date()))
    }

    // MARK: Erasure

    /// The whole reason tombstones exist: without this, the BOOX's copy of an erased stroke comes
    /// back on the next merge, because absence cannot be told from "not synced yet".
    func testErasingAStrokeRecordsATombstone() throws {
        let manifest = try store.createNotebook(title: "notes")
        let pageId = manifest.pageIds[0]
        var page = try store.loadPage(notebookId: manifest.notebookId, pageId: pageId)

        page.strokes = [stroke("s1"), stroke("s2")]
        try store.savePage(page)

        var afterWriting = try store.loadPage(notebookId: manifest.notebookId, pageId: pageId)
        XCTAssertTrue(afterWriting.deletedStrokes.isEmpty, "drawing should not tombstone anything")

        afterWriting.strokes.removeAll { $0.id == "s2" }
        try store.savePage(afterWriting)

        let afterErasing = try store.loadPage(notebookId: manifest.notebookId, pageId: pageId)
        XCTAssertEqual(afterErasing.strokes.map(\.id), ["s1"])
        XCTAssertEqual(afterErasing.deletedStrokes.map(\.id), ["s2"])
    }

    /// Re-stamping an existing tombstone on every save would let an arbitrarily later time win a
    /// delete-vs-edit comparison it should lose.
    func testATombstoneKeepsItsOriginalTimeAcrossLaterSaves() throws {
        let manifest = try store.createNotebook(title: "notes")
        let pageId = manifest.pageIds[0]
        var page = try store.loadPage(notebookId: manifest.notebookId, pageId: pageId)
        page.strokes = [stroke("s1")]
        try store.savePage(page)

        page.strokes = []
        try store.savePage(page)
        let firstTime = try store.loadPage(notebookId: manifest.notebookId, pageId: pageId)
            .deletedStrokes.first?.deletedAt
        XCTAssertNotNil(firstTime)

        // Draw something else later; the old tombstone must not move.
        var later = try store.loadPage(notebookId: manifest.notebookId, pageId: pageId)
        later.strokes = [stroke("s9")]
        try store.savePage(later)

        let reread = try store.loadPage(notebookId: manifest.notebookId, pageId: pageId)
        XCTAssertEqual(reread.deletedStrokes.first?.deletedAt, firstTime)
    }

    func testSavingStampsTheWritingDevice() throws {
        let manifest = try store.createNotebook(title: "notes")
        let page = try store.loadPage(
            notebookId: manifest.notebookId, pageId: manifest.pageIds[0])
        try store.savePage(page)

        let saved = try store.loadPage(
            notebookId: manifest.notebookId, pageId: manifest.pageIds[0])
        XCTAssertEqual(saved.updatedBy, "ipad")
        XCTAssertEqual(store.manifest(id: manifest.notebookId)?.updatedBy, "ipad")
    }

    // MARK: Sync writing underneath an open page

    /// Applies a document the way the CouchDB pull loop does — straight to disk, with no regard
    /// for what the editor currently has open. That is the whole difference from the WebDAV
    /// engine, which is handed `uploadOnly: [openNotebookId]` and never writes there.
    private func applyFromTheBoox(_ page: PageFile) throws {
        var incoming = page
        incoming.updatedAt = NotableDate.format(Date())
        try FileCouchStore(rootURL: rootURL, deviceID: "boox")
            .apply(CouchDocID.page(page.id), .page(
                CouchMapping.couchPage(from: incoming, deviceID: "boox")))
    }

    /// The bug: the editor loads a page, the BOOX's ink lands in the file while it is open, and
    /// the next autosave writes back the stroke set the editor still remembers. Without a baseline
    /// that says what the editor actually saw, the arriving stroke is both overwritten here *and*
    /// tombstoned — so the merge then deletes it on every device, permanently.
    func testInkThatArrivedWhileThePageWasOpenSurvivesTheNextSave() throws {
        let manifest = try store.createNotebook(title: "notes")
        let pageId = manifest.pageIds[0]

        // The editor opens the page and draws.
        var opened = try store.loadPage(notebookId: manifest.notebookId, pageId: pageId)
        opened.strokes = [stroke("mine")]
        let onCanvas = try store.savePage(opened, baselineStrokeIDs: [])

        // The BOOX's stroke arrives while that page is still open.
        var fromBoox = onCanvas
        fromBoox.strokes.append(stroke("from-boox"))
        try applyFromTheBoox(fromBoox)

        // The editor autosaves what it has, which is still only its own stroke.
        var stale = onCanvas
        stale.scroll = 40
        let written = try store.savePage(stale, baselineStrokeIDs: ["mine"])

        XCTAssertEqual(
            Set(written.strokes.map(\.id)), ["mine", "from-boox"],
            "a stale save overwrote ink that arrived from the other device")
        XCTAssertTrue(
            written.deletedStrokes.isEmpty,
            "the editor never saw that stroke, so it cannot have erased it: "
                + "\(written.deletedStrokes.map(\.id))")

        let reread = try store.loadPage(notebookId: manifest.notebookId, pageId: pageId)
        XCTAssertEqual(Set(reread.strokes.map(\.id)), ["mine", "from-boox"])
        XCTAssertEqual(reread.scroll, 40, "the caller's own fields still win")
    }

    /// The same race one step on: a page that was reconciled once must stay reconciled. Passing
    /// the file's own ids back as the baseline would tombstone the arrival on the *second* save.
    func testARepeatedStaleSaveStillDoesNotTombstoneTheArrival() throws {
        let manifest = try store.createNotebook(title: "notes")
        let pageId = manifest.pageIds[0]
        var opened = try store.loadPage(notebookId: manifest.notebookId, pageId: pageId)
        opened.strokes = [stroke("mine")]
        let onCanvas = try store.savePage(opened, baselineStrokeIDs: [])

        var fromBoox = onCanvas
        fromBoox.strokes.append(stroke("from-boox"))
        try applyFromTheBoox(fromBoox)

        // Two more autosaves from an editor that still only knows about its own stroke.
        var stale = onCanvas
        stale.scroll = 10
        _ = try store.savePage(stale, baselineStrokeIDs: ["mine"])
        stale.scroll = 20
        let written = try store.savePage(stale, baselineStrokeIDs: ["mine"])

        XCTAssertEqual(Set(written.strokes.map(\.id)), ["mine", "from-boox"])
        XCTAssertTrue(written.deletedStrokes.isEmpty, "the arrival was erased on a later save")
    }

    /// The other direction: a stroke the BOOX erased must not be resurrected by an editor that
    /// still has it on screen. Erasure beats drawing, the same rule the merge uses.
    func testAStrokeErasedOnTheOtherDeviceIsNotWrittenBackByAStaleSave() throws {
        let manifest = try store.createNotebook(title: "notes")
        let pageId = manifest.pageIds[0]
        var opened = try store.loadPage(notebookId: manifest.notebookId, pageId: pageId)
        opened.strokes = [stroke("keep"), stroke("gone")]
        let onCanvas = try store.savePage(opened, baselineStrokeIDs: [])

        var fromBoox = onCanvas
        fromBoox.strokes.removeAll { $0.id == "gone" }
        fromBoox.deletedStrokes = [
            CouchTombstone(id: "gone", deletedAt: NotableDate.format(Date()))
        ]
        try applyFromTheBoox(fromBoox)

        let written = try store.savePage(onCanvas, baselineStrokeIDs: ["keep", "gone"])

        XCTAssertEqual(written.strokes.map(\.id), ["keep"], "the erased stroke came back")
        XCTAssertEqual(written.deletedStrokes.map(\.id), ["gone"], "the tombstone was dropped")
    }

    /// Erasing still has to work — the baseline is what the caller had, so what left it is gone.
    func testErasingAgainstAnExplicitBaselineStillTombstones() throws {
        let manifest = try store.createNotebook(title: "notes")
        let pageId = manifest.pageIds[0]
        var opened = try store.loadPage(notebookId: manifest.notebookId, pageId: pageId)
        opened.strokes = [stroke("s1"), stroke("s2")]
        var onCanvas = try store.savePage(opened, baselineStrokeIDs: [])

        onCanvas.strokes.removeAll { $0.id == "s2" }
        let written = try store.savePage(onCanvas, baselineStrokeIDs: ["s1", "s2"])

        XCTAssertEqual(written.strokes.map(\.id), ["s1"])
        XCTAssertEqual(written.deletedStrokes.map(\.id), ["s2"])
    }

    /// Images ride along the same path and the editor never removes them, so an add-wins union
    /// is the whole rule — an image from the BOOX must not vanish on the next autosave either.
    func testAnImageThatArrivedWhileThePageWasOpenSurvivesTheNextSave() throws {
        let manifest = try store.createNotebook(title: "notes")
        let pageId = manifest.pageIds[0]
        let onCanvas = try store.savePage(
            try store.loadPage(notebookId: manifest.notebookId, pageId: pageId),
            baselineStrokeIDs: [])

        var fromBoox = onCanvas
        fromBoox.images = [
            ImageDTO(
                id: "img", x: 0, y: 0, width: 10, height: 10, uri: "images/a.png",
                createdAt: NotableDate.format(Date()), updatedAt: NotableDate.format(Date()))
        ]
        try applyFromTheBoox(fromBoox)

        let written = try store.savePage(onCanvas, baselineStrokeIDs: [])
        XCTAssertEqual(written.images.map(\.id), ["img"])
    }

    // MARK: Change reporting

    func testCreatingANotebookNamesBothItAndItsPage() throws {
        let manifest = try store.createNotebook(title: "notes")
        XCTAssertEqual(changed.last, [
            CouchDocID.notebook(manifest.notebookId), CouchDocID.page(manifest.pageIds[0]),
        ])
    }

    func testSavingAPageNamesThePageAndItsNotebook() throws {
        let manifest = try store.createNotebook(title: "notes")
        let page = try store.loadPage(
            notebookId: manifest.notebookId, pageId: manifest.pageIds[0])
        changed = []
        try store.savePage(page)

        XCTAssertEqual(changed.last, [
            CouchDocID.page(page.id), CouchDocID.notebook(manifest.notebookId),
        ])
    }

    func testRenamingNamesOnlyTheNotebook() throws {
        let manifest = try store.createNotebook(title: "notes")
        changed = []
        try store.renameNotebook(id: manifest.notebookId, title: "renamed")
        XCTAssertEqual(changed.last, [CouchDocID.notebook(manifest.notebookId)])
    }

    /// The pages go with the notebook, so sync has to hear about them: one left queued would be
    /// pushed back under a notebook that no longer exists.
    func testDeletingANotebookNamesItsPagesToo() throws {
        let manifest = try store.createNotebook(title: "notes")
        let extraPage = try store.addPage(to: manifest.notebookId)
        changed = []

        try store.deleteNotebook(id: manifest.notebookId)

        let reported = Set(changed.last ?? [])
        XCTAssertTrue(reported.contains(CouchDocID.notebook(manifest.notebookId)))
        XCTAssertTrue(reported.contains(CouchDocID.page(manifest.pageIds[0])))
        XCTAssertTrue(reported.contains(CouchDocID.page(extraPage.id)))
    }

    func testFolderChangesAreReported() throws {
        let folder = try store.createFolder(title: "school")
        XCTAssertEqual(changed.last, [CouchDocID.folder(folder.id)])
    }

    /// `refresh()` is what sync itself calls after applying a change; reporting from there would
    /// be a feedback loop that re-queues everything sync just downloaded.
    func testRefreshReportsNothing() throws {
        _ = try store.createNotebook(title: "notes")
        changed = []
        store.refresh()
        XCTAssertTrue(changed.isEmpty)
    }
}
