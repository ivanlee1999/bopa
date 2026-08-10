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
