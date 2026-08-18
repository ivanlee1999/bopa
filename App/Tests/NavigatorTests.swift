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

    // MARK: Repairing the page list

    /// A repeated id is what makes a four-page notebook draw one thumbnail: the editor's counter is
    /// `pageIds.count` while the overview is a `ForEach` keyed by page id, and SwiftUI renders one
    /// row for ids that collide. The two have to be able to disagree for the bug to exist, so the
    /// repair is the thing that keeps them honest.
    func testARepeatedPageIdIsCollapsedToOne() throws {
        try addPages(3)
        var manifest = try XCTUnwrap(store.manifest(id: notebookId))
        let first = manifest.pageIds[0]
        manifest.pageIds = [first, first, first, first]
        try writeManifestDirectly(manifest)
        store.refresh()

        XCTAssertTrue(store.repairPageList(in: notebookId))

        // The three real pages are still on disk, so they come back rather than being dropped with
        // the duplicates — repairing must not cost the reader three pages.
        let repaired = try XCTUnwrap(store.manifest(id: notebookId)).pageIds
        XCTAssertEqual(repaired.count, 4)
        XCTAssertEqual(Set(repaired).count, 4)
        XCTAssertEqual(repaired.first, first)
    }

    /// A page file with no entry in `pageIds` is invisible in the app and, worse, the next upload's
    /// orphan cleanup deletes it. Re-attaching it is the difference between a page being lost and
    /// being out of order.
    func testAnOrphanPageFileIsReattached() throws {
        let pages = try addPages(2)
        var manifest = try XCTUnwrap(store.manifest(id: notebookId))
        manifest.pageIds = manifest.pageIds.filter { $0 != pages[1] }
        try writeManifestDirectly(manifest)
        store.refresh()

        XCTAssertTrue(store.repairPageList(in: notebookId))

        XCTAssertTrue(
            try XCTUnwrap(store.manifest(id: notebookId)).pageIds.contains(pages[1]))
    }

    /// The counterpart, and the one that matters more: a page deleted here or on the BOOX leaves a
    /// tombstone and its file may linger. Re-attaching it would walk a deleted page back in on the
    /// next open, which is exactly the loop the merge's erasure-beats-drawing rule exists to stop.
    func testATombstonedPageIsNotReattached() throws {
        let pages = try addPages(2)
        try store.deletePage(from: notebookId, pageId: pages[1])
        store.refresh()

        XCTAssertFalse(store.repairPageList(in: notebookId))
        XCTAssertFalse(
            try XCTUnwrap(store.manifest(id: notebookId)).pageIds.contains(pages[1]))
    }

    /// A healthy notebook must not be rewritten: the repair bumps `updatedAt`, which is the clock
    /// the merge reads, so a no-op that still wrote would make every open look like an edit and
    /// give the notebook a spurious win over the other device.
    func testAHealthyNotebookIsLeftAlone() throws {
        try addPages(3)
        let before = try XCTUnwrap(store.manifest(id: notebookId))

        XCTAssertFalse(store.repairPageList(in: notebookId))

        XCTAssertEqual(try XCTUnwrap(store.manifest(id: notebookId)), before)
    }

    // MARK: Dividing pages that outgrew their sheet

    /// The migration a notebook written before pages were sheets needs: work that lived below the
    /// first sheet becomes pages of its own, in order, and the notebook's page list says so.
    func testANotebookOfEndlessPagesBecomesANotebookOfPages() throws {
        let pageId = pageIds[0]
        var page = try store.loadPage(notebookId: notebookId, pageId: pageId)
        let sheet = try XCTUnwrap(page.pageHeight)
        page.strokes = [
            try makeStroke(id: "top", top: 10),
            try makeStroke(id: "second-sheet", top: Float(sheet) + 100),
            try makeStroke(id: "third-sheet", top: Float(sheet) * 2 + 100),
        ]
        try store.savePage(page)

        let added = store.splitOversizedPages(in: notebookId)

        XCTAssertEqual(added, 2)
        let after = try XCTUnwrap(store.manifest(id: notebookId)).pageIds
        XCTAssertEqual(after.count, 3)
        XCTAssertEqual(after[0], pageId, "the first sheet keeps the page's id")
        XCTAssertEqual(
            try store.loadPage(notebookId: notebookId, pageId: after[1]).strokes.map(\.id),
            ["second-sheet"])
        XCTAssertEqual(
            try store.loadPage(notebookId: notebookId, pageId: after[2]).strokes.map(\.id),
            ["third-sheet"])
    }

    /// It runs on open, so a notebook that is already in sheets must be left completely alone —
    /// not merely produce the same pages, but not be written at all. Writing would bump the clock
    /// the merge reads and hand this device a spurious win over the BOOX on every open.
    func testANotebookAlreadyInSheetsIsNotTouched() throws {
        try addPages(2)
        let before = try XCTUnwrap(store.manifest(id: notebookId))

        XCTAssertEqual(store.splitOversizedPages(in: notebookId), 0)

        XCTAssertEqual(try XCTUnwrap(store.manifest(id: notebookId)), before)
    }

    /// A bookmark names a page id. The first sheet keeps the page's, so a starred page is still
    /// starred after the notebook is divided — anything else would quietly drop the reader's marks.
    func testBookmarksSurviveTheDivision() throws {
        let pageId = pageIds[0]
        try store.setBookmark(notebookId: notebookId, pageId: pageId, bookmarked: true)
        var page = try store.loadPage(notebookId: notebookId, pageId: pageId)
        let sheet = try XCTUnwrap(page.pageHeight)
        page.strokes = [
            try makeStroke(id: "top", top: 10),
            try makeStroke(id: "below", top: Float(sheet) + 100),
        ]
        try store.savePage(page)

        store.splitOversizedPages(in: notebookId)

        XCTAssertEqual(store.bookmarkedPageIds(in: notebookId), [pageId])
    }

    /// The division must leave the parent a record of the ink it moved — §6.6 rule 7. Without it
    /// a peer still holding the tall copy unions the moved strokes back into the parent on every
    /// merge, and the notebook never converges.
    func testTheParentRemembersTheInkThatLeftIt() throws {
        let pageId = pageIds[0]
        var page = try store.loadPage(notebookId: notebookId, pageId: pageId)
        let sheet = try XCTUnwrap(page.pageHeight)
        page.strokes = [
            try makeStroke(id: "top", top: 10),
            try makeStroke(id: "below", top: Float(sheet) + 100),
        ]
        try store.savePage(page)

        store.splitOversizedPages(in: notebookId)

        let parent = try store.loadPage(notebookId: notebookId, pageId: pageId)
        XCTAssertEqual(parent.deletedStrokes.map(\.id), ["below"])
        let childId = try XCTUnwrap(pageIds.last)
        let child = try store.loadPage(notebookId: notebookId, pageId: childId)
        XCTAssertEqual(child.strokes.map(\.id), ["below"])
        XCTAssertTrue(
            child.deletedStrokes.isEmpty,
            "the child must carry no tombstone for the ink now alive on it")
    }

    /// A page can re-grow after its division — a peer that has not learned the split pushes new
    /// below-sheet ink, most plausibly — and the re-division used to rebuild every child from the
    /// parent alone, over whatever had been drawn on the child since. The produced child is folded
    /// into the existing one through the ordinary page merge instead, and the page list gains no
    /// duplicate entries on the way.
    func testARegrownParentDoesNotRebuildItsChildren() throws {
        let pageId = pageIds[0]
        var page = try store.loadPage(notebookId: notebookId, pageId: pageId)
        let sheet = try XCTUnwrap(page.pageHeight)
        page.strokes = [
            try makeStroke(id: "top", top: 10),
            try makeStroke(id: "below", top: Float(sheet) + 100),
        ]
        try store.savePage(page)
        store.splitOversizedPages(in: notebookId)
        let childId = try XCTUnwrap(pageIds.last)

        // Ink drawn on the child after the division…
        var child = try store.loadPage(notebookId: notebookId, pageId: childId)
        child.strokes.append(try makeStroke(id: "child-ink", top: 50))
        try store.savePage(child)
        // …and the parent re-grown underneath it, the way an old peer's push arrives.
        var regrown = try store.loadPage(notebookId: notebookId, pageId: pageId)
        regrown.strokes.append(try makeStroke(id: "regrown", top: Float(sheet) + 300))
        try store.savePage(regrown)

        store.splitOversizedPages(in: notebookId)

        let after = try store.loadPage(notebookId: notebookId, pageId: childId)
        XCTAssertEqual(
            Set(after.strokes.map(\.id)), ["below", "child-ink", "regrown"],
            "the child keeps its own ink and gains the moved ink — nothing is rebuilt away")
        let ids = pageIds
        XCTAssertEqual(ids.count, Set(ids).count, "no page is listed twice")
        XCTAssertEqual(ids, [pageId, childId])
    }

    private func makeStroke(id: String, top: Float) throws -> StrokeDTO {
        let points = [
            NotableStrokePoint(x: 10, y: top, pressure: 0.5),
            NotableStrokePoint(x: 20, y: top + 40, pressure: 0.5),
        ]
        return StrokeDTO(
            id: id, size: 3, pen: .ballpen, color: -16_777_216,
            top: top, bottom: top + 40, left: 10, right: 20,
            pointsData: try SBStrokeCodec.encode(points).base64EncodedString(),
            createdAt: "2026-08-15T00:00:00.000Z", updatedAt: "2026-08-15T00:00:00.000Z")
    }
}
