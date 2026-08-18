import NotableKit
import UIKit
import XCTest

@testable import Bopa

/// The thumbnail cache's revision, and what the rendered card actually shows.
///
/// The cache used to key every page's thumbnail on the *notebook's* `updatedAt`, which failed in
/// both directions: a remote apply rewrites only the page file, so ink drawn on the BOOX never
/// refreshed its thumbnail, while a rename bumped the manifest and invalidated every page of the
/// notebook for a title no thumbnail draws. The revision is the page file's own now.
@MainActor
final class ThumbnailTests: XCTestCase {
    private var rootURL: URL!
    private var store: NotebookStore!
    private var notebookId = ""

    override func setUp() async throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("bopa-thumbnail-test-\(UUID().uuidString)")
        store = NotebookStore(rootURL: rootURL)
        notebookId = try store.createNotebook(title: "Notes").notebookId
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: rootURL)
    }

    private var pageIds: [String] { store.manifest(id: notebookId)?.pageIds ?? [] }

    private func revision(_ pageId: String) -> String {
        store.pageRevision(notebookId: notebookId, pageId: pageId)
    }

    private func makeStroke(id: String) throws -> StrokeDTO {
        let points = [
            NotableStrokePoint(x: 10, y: 10, pressure: 0.5),
            NotableStrokePoint(x: 60, y: 40, pressure: 0.5),
        ]
        return StrokeDTO(
            id: id, size: 3, pen: .ballpen, color: -16_777_216,
            top: 10, bottom: 40, left: 10, right: 60,
            pointsData: try SBStrokeCodec.encode(points).base64EncodedString(),
            createdAt: "2026-08-15T00:00:00.000Z", updatedAt: "2026-08-15T00:00:00.000Z")
    }

    // MARK: The revision

    func testDrawingOnAPageMovesItsRevisionAndOnlyIts() throws {
        let second = try store.addPage(to: notebookId)
        let drawn = pageIds[0]
        let drawnBefore = revision(drawn)
        let siblingBefore = revision(second.id)

        var page = try store.loadPage(notebookId: notebookId, pageId: drawn)
        page.strokes = [try makeStroke(id: "s1")]
        try store.savePage(page)

        XCTAssertNotEqual(
            revision(drawn), drawnBefore,
            "ink drawn on a page must invalidate its thumbnail")
        XCTAssertEqual(
            revision(second.id), siblingBefore,
            "an untouched sibling was invalidated along with it")
    }

    /// A rename edits the manifest and nothing else; no thumbnail draws the title, so no
    /// thumbnail may pay for it.
    func testANotebookRenameLeavesEveryRevisionAlone() throws {
        let second = try store.addPage(to: notebookId)
        let before = [revision(pageIds[0]), revision(second.id)]

        try store.renameNotebook(id: notebookId, title: "Renamed")

        XCTAssertEqual([revision(pageIds[0]), revision(second.id)], before)
    }

    // MARK: The cache follows the revision

    /// The BOOX's path: sync rewrites the page file and never touches the manifest. Keyed on the
    /// notebook's `updatedAt` this was a permanent cache hit — the stale card outlived the ink.
    func testASyncRewriteAloneReRendersTheThumbnail() throws {
        let stale = ThumbnailRenderer.thumbnail(
            notebookId: notebookId, pageId: pageIds[0], store: store)

        var onDisk = try store.loadPage(notebookId: notebookId, pageId: pageIds[0])
        onDisk.strokes = [try makeStroke(id: "from-boox")]
        let encoder = JSONEncoder()
        try encoder.encode(onDisk).write(
            to: rootURL.appendingPathComponent(
                "notebooks/\(notebookId)/pages/\(pageIds[0]).json"),
            options: .atomic)

        let fresh = ThumbnailRenderer.thumbnail(
            notebookId: notebookId, pageId: pageIds[0], store: store)
        XCTAssertNotNil(fresh)
        XCTAssertFalse(stale === fresh, "the rewritten page came back out of the cache")
    }

    func testAnUntouchedPageIsServedFromTheCache() throws {
        let first = ThumbnailRenderer.thumbnail(
            notebookId: notebookId, pageId: pageIds[0], store: store)
        let second = ThumbnailRenderer.thumbnail(
            notebookId: notebookId, pageId: pageIds[0], store: store)
        XCTAssertNotNil(first)
        XCTAssertTrue(first === second, "an untouched page was re-rendered")
    }
}
