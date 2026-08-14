import NotableKit
import XCTest

@testable import Bopa

/// Bookmarks and the outline, as the store exposes them to the navigator panel.
///
/// The rules worth pinning here are the ones a peer can see, because both fields travel: an
/// un-starring has to be written down rather than dropped, and a deleted page has to take its
/// outline entries with it — the merge deliberately will not do that second one, so if this layer
/// forgets, the entry comes back from the other device.
@MainActor
final class NavigatorTests: XCTestCase {
    private var rootURL: URL!
    private var store: NotebookStore!
    private var notebookId = ""

    override func setUp() async throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("bopa-navigator-test-\(UUID().uuidString)")
        store = NotebookStore(rootURL: rootURL)
        notebookId = try store.createNotebook(title: "Notes").notebookId
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: rootURL)
    }

    private var pageIds: [String] { store.manifest(id: notebookId)?.pageIds ?? [] }
    private var storedOutline: [CouchOutlineEntry] {
        store.manifest(id: notebookId)?.outline ?? []
    }

    @discardableResult
    private func addPages(_ count: Int) throws -> [String] {
        try (0..<count).map { _ in try store.insertPage(into: notebookId, at: nil).id }
    }

    // MARK: Bookmarks

    func testStarringAPageShowsItInTheBookmarkList() throws {
        try addPages(2)
        try store.setBookmark(notebookId: notebookId, pageId: pageIds[1], bookmarked: true)

        XCTAssertTrue(store.isBookmarked(notebookId: notebookId, pageId: pageIds[1]))
        XCTAssertEqual(store.bookmarkedPageIds(in: notebookId), [pageIds[1]])
    }

    /// The list reads in page order, not in the order the entries are stored — which is sorted by
    /// id, to keep the merged document byte-stable, and is therefore meaningless to a reader.
    func testBookmarksAreListedInPageOrder() throws {
        try addPages(3)
        for index in [3, 0, 2] {
            try store.setBookmark(notebookId: notebookId, pageId: pageIds[index], bookmarked: true)
        }

        XCTAssertEqual(
            store.bookmarkedPageIds(in: notebookId),
            [pageIds[0], pageIds[2], pageIds[3]])
    }

    /// Un-starring writes a `removed` entry rather than dropping the bookmark. Dropping it would
    /// leave the peer's copy as the only word on the subject, and the star would come back.
    func testUnstarringIsRecordedRatherThanDropped() throws {
        let pageId = pageIds[0]
        try store.setBookmark(notebookId: notebookId, pageId: pageId, bookmarked: true)
        try store.setBookmark(notebookId: notebookId, pageId: pageId, bookmarked: false)

        XCTAssertFalse(store.isBookmarked(notebookId: notebookId, pageId: pageId))
        XCTAssertTrue(store.bookmarkedPageIds(in: notebookId).isEmpty)
        let entry = store.manifest(id: notebookId)?.bookmarks.first { $0.pageId == pageId }
        XCTAssertEqual(entry?.removed, true, "the un-starring has to travel, so it must be stored")
    }

    func testAPageCanBeStarredAgainAfterBeingUnstarred() throws {
        let pageId = pageIds[0]
        try store.setBookmark(notebookId: notebookId, pageId: pageId, bookmarked: true)
        try store.setBookmark(notebookId: notebookId, pageId: pageId, bookmarked: false)
        try store.setBookmark(notebookId: notebookId, pageId: pageId, bookmarked: true)

        XCTAssertTrue(store.isBookmarked(notebookId: notebookId, pageId: pageId))
    }

    // MARK: Outline

    func testAddingEntriesBuildsTheOutline() throws {
        try addPages(1)
        try store.addOutlineEntry(notebookId: notebookId, pageId: pageIds[0], title: "Intro")
        try store.addOutlineEntry(notebookId: notebookId, pageId: pageIds[1], title: "Body")

        XCTAssertEqual(store.outline(in: notebookId).map(\.title), ["Intro", "Body"])
    }

    /// A page may carry more than one entry — it is how a page that closes one section and opens
    /// another gets to say so, and it is why entries are keyed by their own id.
    func testAPageMayAppearInTheOutlineTwice() throws {
        try store.addOutlineEntry(notebookId: notebookId, pageId: pageIds[0], title: "End of I")
        try store.addOutlineEntry(notebookId: notebookId, pageId: pageIds[0], title: "Start of II")

        XCTAssertEqual(store.outline(in: notebookId).count, 2)
        XCTAssertEqual(Set(store.outline(in: notebookId).map(\.id)).count, 2)
    }

    /// A new entry lands beside the pages it sits between, not at the end: an outline is read
    /// against the notebook, so an entry for page 2 added last still belongs before page 5's.
    func testANewEntryIsPlacedByItsPagePosition() throws {
        try addPages(3)
        try store.addOutlineEntry(notebookId: notebookId, pageId: pageIds[3], title: "Later")
        try store.addOutlineEntry(notebookId: notebookId, pageId: pageIds[1], title: "Earlier")

        XCTAssertEqual(store.outline(in: notebookId).map(\.title), ["Earlier", "Later"])
    }

    func testDepthIsClampedToWhatTheFormatAllows() throws {
        try store.addOutlineEntry(notebookId: notebookId, pageId: pageIds[0], title: "Deep")
        let id = try XCTUnwrap(store.outline(in: notebookId).first?.id)

        try store.updateOutlineEntry(notebookId: notebookId, entryId: id, depth: 9)
        XCTAssertEqual(store.outline(in: notebookId).first?.depth, CouchOutlineEntry.maxDepth)

        try store.updateOutlineEntry(notebookId: notebookId, entryId: id, depth: -4)
        XCTAssertEqual(store.outline(in: notebookId).first?.depth, 0)
    }

    /// Removal is a mark, not a delete, for the same reason un-starring is.
    func testRemovingAnEntryLeavesATombstone() throws {
        try store.addOutlineEntry(notebookId: notebookId, pageId: pageIds[0], title: "Intro")
        let id = try XCTUnwrap(store.outline(in: notebookId).first?.id)

        try store.removeOutlineEntry(notebookId: notebookId, entryId: id)

        XCTAssertTrue(store.outline(in: notebookId).isEmpty)
        XCTAssertEqual(storedOutline.first { $0.id == id }?.removed, true)
    }

    /// Reordering addresses the list the reader can see. The stored list also holds removed
    /// entries, so an index taken from the visible list would move the wrong row.
    func testReorderingUsesVisiblePositionsNotStoredOnes() throws {
        try addPages(2)
        for (index, title) in ["A", "B", "C"].enumerated() {
            try store.addOutlineEntry(
                notebookId: notebookId, pageId: pageIds[index], title: title)
        }
        let removedId = try XCTUnwrap(store.outline(in: notebookId).first?.id)
        try store.removeOutlineEntry(notebookId: notebookId, entryId: removedId)
        XCTAssertEqual(store.outline(in: notebookId).map(\.title), ["B", "C"])

        // Move the visible first entry ("B") to the end.
        try store.moveOutlineEntry(in: notebookId, from: 0, to: 2)

        XCTAssertEqual(store.outline(in: notebookId).map(\.title), ["C", "B"])
    }

    // MARK: Deleting a page

    /// The merge will not drop an outline entry whose page is gone — doing so is not idempotent —
    /// so deleting the page has to mark its entries here. If it does not, the peer that still
    /// holds the entry adds it straight back on the next sync.
    func testDeletingAPageMarksItsOutlineEntriesRemoved() throws {
        try addPages(1)
        let doomed = pageIds[1]
        try store.addOutlineEntry(notebookId: notebookId, pageId: doomed, title: "Gone")
        try store.addOutlineEntry(notebookId: notebookId, pageId: pageIds[0], title: "Stays")
        let doomedEntry = try XCTUnwrap(store.outline(in: notebookId).first { $0.pageId == doomed })

        try store.deletePage(from: notebookId, pageId: doomed)

        XCTAssertEqual(store.outline(in: notebookId).map(\.title), ["Stays"])
        XCTAssertEqual(
            storedOutline.first { $0.id == doomedEntry.id }?.removed, true,
            "a dropped entry would be re-added by the peer; a marked one will not be")
    }

    func testDeletingAPageTakesItsBookmarkWithIt() throws {
        try addPages(1)
        let doomed = pageIds[1]
        try store.setBookmark(notebookId: notebookId, pageId: doomed, bookmarked: true)

        try store.deletePage(from: notebookId, pageId: doomed)

        XCTAssertTrue(store.bookmarkedPageIds(in: notebookId).isEmpty)
    }

    /// An entry that outlived its page through some path nobody anticipated is invisible rather
    /// than broken: tapping it would go nowhere.
    func testAnEntryPointingAtAMissingPageIsNotShown() throws {
        try store.addOutlineEntry(notebookId: notebookId, pageId: pageIds[0], title: "Real")
        var manifest = try XCTUnwrap(store.manifest(id: notebookId))
        manifest.outline.append(CouchOutlineEntry(
            id: "orphan", pageId: "no-such-page", title: "Dangling",
            updatedAt: NotableDate.format(Date())))
        try writeManifestDirectly(manifest)
        store.refresh()

        XCTAssertEqual(store.outline(in: notebookId).map(\.title), ["Real"])
    }

    /// Writes straight to disk, bypassing the store — standing in for the sync engine.
    private func writeManifestDirectly(_ manifest: NotebookManifest) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        try encoder.encode(manifest).write(
            to: rootURL.appendingPathComponent("notebooks/\(manifest.notebookId)/manifest.json"),
            options: .atomic)
    }

    // MARK: Round trip

    /// Both fields have to survive the manifest being written and read back — it is bopa's local
    /// storage as well as its wire format, so a field that does not round-trip does not persist.
    func testBookmarksAndOutlineSurviveAReload() throws {
        try store.setBookmark(notebookId: notebookId, pageId: pageIds[0], bookmarked: true)
        try store.addOutlineEntry(
            notebookId: notebookId, pageId: pageIds[0], title: "Intro", depth: 1)

        let reopened = NotebookStore(rootURL: rootURL)

        XCTAssertEqual(reopened.bookmarkedPageIds(in: notebookId), [pageIds[0]])
        XCTAssertEqual(reopened.outline(in: notebookId).map(\.title), ["Intro"])
        XCTAssertEqual(reopened.outline(in: notebookId).first?.depth, 1)
    }
}
