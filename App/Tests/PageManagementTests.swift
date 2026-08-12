import NotableKit
import XCTest

@testable import Bopa

/// Managing the pages of a notebook: insert, duplicate, reorder, rename, delete.
///
/// bopa had append and nothing else, so a notebook could be grown but never arranged. The rules
/// worth pinning are the ones a peer can see: a deleted page needs a tombstone or the other device
/// adds it straight back, and a duplicate needs fresh ids or the merge treats the copy and the
/// original as the same page.
@MainActor
final class PageManagementTests: XCTestCase {
    private var rootURL: URL!
    private var store: NotebookStore!
    private var notebookId = ""

    override func setUp() async throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("bopa-pages-test-\(UUID().uuidString)")
        store = NotebookStore(rootURL: rootURL)
        notebookId = try store.createNotebook(title: "Notes").notebookId
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: rootURL)
    }

    private var pageIds: [String] { store.manifest(id: notebookId)?.pageIds ?? [] }

    private func stroke(_ id: String) -> StrokeDTO {
        let now = NotableDate.format(Date())
        return StrokeDTO(
            id: id, size: 3, pen: .ballpen, color: -16_777_216, maxPressure: 1,
            top: 0, bottom: 1, left: 0, right: 1, pointsData: "AAA=",
            createdAt: now, updatedAt: now)
    }

    // MARK: Inserting

    func testInsertingPutsThePageWhereItWasAsked() throws {
        let second = try store.insertPage(into: notebookId, at: nil)
        let middle = try store.insertPage(into: notebookId, at: 1)

        XCTAssertEqual(pageIds.count, 3)
        XCTAssertEqual(pageIds[1], middle.id)
        XCTAssertEqual(pageIds[2], second.id)
    }

    /// An index arrives from a drag gesture or from a peer's page list, neither of which is
    /// obliged to be in range — and an out-of-range insert traps rather than misbehaving.
    func testAnOutOfRangeIndexIsClampedRatherThanTrapping() throws {
        let page = try store.insertPage(into: notebookId, at: 99)
        XCTAssertEqual(pageIds.last, page.id)
    }

    // MARK: Duplicating

    func testDuplicatingCopiesTheContentUnderFreshIDs() throws {
        let original = pageIds[0]
        var page = try store.loadPage(notebookId: notebookId, pageId: original)
        page.strokes = [stroke("s1")]
        try store.savePage(page)

        let copy = try store.duplicatePage(in: notebookId, pageId: original)

        XCTAssertEqual(pageIds, [original, copy.id], "the copy is filed right after the original")
        XCTAssertNotEqual(copy.id, original)
        let loaded = try store.loadPage(notebookId: notebookId, pageId: copy.id)
        XCTAssertEqual(loaded.strokes.count, 1)
        XCTAssertNotEqual(
            loaded.strokes[0].id, "s1",
            "a shared stroke id would have the merge treat the two pages as one")
    }

    /// Nothing was erased from a page that did not exist a moment ago. Carrying the original's
    /// tombstones over would tell peers to delete strokes from the copy by id.
    func testADuplicateCarriesNoTombstones() throws {
        let original = pageIds[0]
        var page = try store.loadPage(notebookId: notebookId, pageId: original)
        page.deletedStrokes = [CouchTombstone(id: "gone", deletedAt: page.updatedAt)]
        try store.savePage(page)

        let copy = try store.duplicatePage(in: notebookId, pageId: original)

        XCTAssertTrue(
            try store.loadPage(notebookId: notebookId, pageId: copy.id).deletedStrokes.isEmpty)
    }

    // MARK: Reordering

    func testMovingAPageReordersTheNotebook() throws {
        let first = pageIds[0]
        let second = try store.insertPage(into: notebookId, at: nil).id
        let third = try store.insertPage(into: notebookId, at: nil).id

        try store.movePage(in: notebookId, from: 2, to: 0)

        XCTAssertEqual(pageIds, [third, first, second])
    }

    func testMovingBumpsTheNotebookSoTheChangeSyncs() throws {
        _ = try store.insertPage(into: notebookId, at: nil)
        let before = store.manifest(id: notebookId)?.updatedAt

        try store.movePage(in: notebookId, from: 1, to: 0)

        XCTAssertNotNil(store.manifest(id: notebookId)?.updatedAt)
        XCTAssertGreaterThanOrEqual(store.manifest(id: notebookId)!.updatedAt, before!)
    }

    // MARK: Renaming

    func testRenamingAPageSticks() throws {
        try store.renamePage(in: notebookId, pageId: pageIds[0], title: "Intro")

        XCTAssertEqual(
            try store.loadPage(notebookId: notebookId, pageId: pageIds[0]).title, "Intro")
    }

    func testClearingANameStoresNilRatherThanAnEmptyString() throws {
        try store.renamePage(in: notebookId, pageId: pageIds[0], title: "Intro")
        try store.renamePage(in: notebookId, pageId: pageIds[0], title: nil)

        XCTAssertNil(try store.loadPage(notebookId: notebookId, pageId: pageIds[0]).title)
    }

    // MARK: Deleting

    /// The tombstone is the point: a page has no lifecycle of its own, so a peer that still lists
    /// it would add it straight back on the next merge.
    func testDeletingRecordsATombstoneAndRemovesTheFile() throws {
        let doomed = try store.insertPage(into: notebookId, at: nil).id

        try store.deletePage(from: notebookId, pageId: doomed)

        XCTAssertFalse(pageIds.contains(doomed))
        XCTAssertEqual(store.manifest(id: notebookId)?.deletedPageIds.map(\.id), [doomed])
        XCTAssertThrowsError(try store.loadPage(notebookId: notebookId, pageId: doomed))
    }

    func testDeletingTheOpenPageMovesTheNotebookOnToAnother() throws {
        let first = pageIds[0]
        let second = try store.insertPage(into: notebookId, at: nil).id
        XCTAssertEqual(store.manifest(id: notebookId)?.openPageId, first)

        try store.deletePage(from: notebookId, pageId: first)

        XCTAssertEqual(store.manifest(id: notebookId)?.openPageId, second)
    }

    /// A notebook with no pages is the empty leftover the library already has to warn about;
    /// arriving there deliberately would be a worse way to get one.
    func testTheLastPageCannotBeDeleted() throws {
        XCTAssertThrowsError(try store.deletePage(from: notebookId, pageId: pageIds[0])) { error in
            XCTAssertTrue(error is NotebookStore.LastPageError)
        }
        XCTAssertEqual(pageIds.count, 1)
    }
}
