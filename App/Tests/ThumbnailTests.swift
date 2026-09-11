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

    // MARK: What the card shows

    /// Puts a tiny red PNG at `images/<name>` in the notebook dir, the way the sync engine's
    /// asset download does.
    private func installImageFile(named name: String) throws {
        let imagesDir = rootURL.appendingPathComponent(
            "notebooks/\(notebookId)/images", isDirectory: true)
        try FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let png = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4), format: format)
            .pngData { ctx in
                UIColor.systemRed.setFill()
                ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
            }
        try png.write(to: imagesDir.appendingPathComponent(name))
    }

    private func makeImageDTO(uri: String, x: Int, y: Int, width: Int, height: Int) -> ImageDTO {
        let now = NotableDate.format(Date())
        return ImageDTO(
            id: UUID().uuidString.lowercased(), x: x, y: y, width: width, height: height,
            uri: uri, createdAt: now, updatedAt: now)
    }

    /// Reads one pixel, in point coordinates measured from the top-left, the way the frames are.
    private func pixel(of image: UIImage, x: Int, y: Int) throws -> (r: UInt8, g: UInt8, b: UInt8) {
        let width = Int(image.size.width)
        let height = Int(image.size.height)
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &data, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(
            try XCTUnwrap(image.cgImage),
            in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        let offset = (y * width + x) * 4
        return (data[offset], data[offset + 1], data[offset + 2])
    }

    private func isWhite(_ p: (r: UInt8, g: UInt8, b: UInt8)) -> Bool {
        p.r > 240 && p.g > 240 && p.b > 240
    }

    /// An image-heavy page used to render as a blank card: the composite was paper + PDF
    /// background + strokes, and the images the editor draws never appeared in it.
    func testAPageImageAppearsInTheThumbnail() throws {
        try installImageFile(named: "pix.png")
        var page = try store.loadPage(notebookId: notebookId, pageId: pageIds[0])
        page.images = [makeImageDTO(uri: "images/pix.png", x: 100, y: 200, width: 800, height: 800)]
        page.strokes = [try makeStroke(id: "s1")]
        try store.savePage(page)

        let thumb = try XCTUnwrap(
            ThumbnailRenderer.thumbnail(notebookId: notebookId, pageId: pageIds[0], store: store))

        let fitted = ThumbnailRenderer.fittedPageRect(pageSize: page.pageSize)
        let scale = fitted.width / CGFloat(page.pageSize.width)
        let center = try pixel(
            of: thumb, x: Int(fitted.minX + (100 + 400) * scale), y: Int(fitted.minY + (200 + 400) * scale))
        XCTAssertFalse(isWhite(center), "the image region rendered as blank paper")
        XCTAssertGreaterThan(center.r, center.g, "the red picture should render red")

        let paper = try pixel(of: thumb, x: Int(ThumbnailRenderer.size.width) - 20, y: 20)
        XCTAssertTrue(isWhite(paper), "paper beside the image must stay white")
    }

    /// An image whose file has not arrived yet (or is gone) is skipped, the way the editor
    /// skips it — never a crash, never a hole drawn over the page.
    func testAMissingImageFileLeavesTheThumbnailRenderable() throws {
        var page = try store.loadPage(notebookId: notebookId, pageId: pageIds[0])
        page.images = [makeImageDTO(uri: "images/gone.png", x: 100, y: 200, width: 800, height: 800)]
        try store.savePage(page)

        let thumb = try XCTUnwrap(
            ThumbnailRenderer.thumbnail(notebookId: notebookId, pageId: pageIds[0], store: store))
        let fitted = ThumbnailRenderer.fittedPageRect(pageSize: page.pageSize)
        let scale = fitted.width / CGFloat(page.pageSize.width)
        let center = try pixel(
            of: thumb, x: Int(fitted.minX + (100 + 400) * scale), y: Int(fitted.minY + (200 + 400) * scale))
        XCTAssertTrue(isWhite(center), "a missing file must render as paper, not as a hole")
    }
    func testThumbnailsFitTheWholeSheetAtEveryPresetSize() {
        for preset in PageSizePreset.all {
            let fitted = ThumbnailRenderer.fittedPageRect(pageSize: preset.size)
            XCTAssertGreaterThan(fitted.width, 0)
            XCTAssertGreaterThan(fitted.height, 0)
            XCTAssertGreaterThanOrEqual(fitted.minX, -0.001)
            XCTAssertGreaterThanOrEqual(fitted.minY, -0.001)
            XCTAssertLessThanOrEqual(fitted.maxX, ThumbnailRenderer.size.width + 0.001)
            XCTAssertLessThanOrEqual(fitted.maxY, ThumbnailRenderer.size.height + 0.001)
            XCTAssertEqual(fitted.width / fitted.height,
                           CGFloat(preset.size.width) / CGFloat(preset.size.height), accuracy: 0.001)
        }
    }

    func testNativePaperIsRenderedAndCoverStaysOnTheFirstPage() throws {
        let notebook = try store.createNotebook(title: "Ruled", template: .lined)
        let first = try XCTUnwrap(notebook.pageIds.first)
        let ruled = try XCTUnwrap(ThumbnailRenderer.thumbnail(for: notebook, store: store))
        let second = try store.addPage(to: notebook.notebookId)
        store.rememberOpenedPage(second.id, in: notebook.notebookId)
        let freshManifest = try XCTUnwrap(store.manifest(id: notebook.notebookId))
        XCTAssertTrue(ruled === ThumbnailRenderer.thumbnail(for: freshManifest, store: store),
                      "The library cover must stay the first page when the editor resumes elsewhere")
        var page = try store.loadPage(notebookId: notebook.notebookId, pageId: first)
        let blank = TemplateApplication.pageFields(for: .native(.blank))
        page.background = blank.background
        page.backgroundType = blank.backgroundType
        try store.savePage(page)
        let plain = try XCTUnwrap(ThumbnailRenderer.thumbnail(for: freshManifest, store: store))
        XCTAssertNotEqual(ruled.pngData(), plain.pngData(), "Ruled paper must not appear as a blank cover")
    }

    func testBottomOfTallPaperRemainsVisible() throws {
        try installImageFile(named: "bottom.png")
        var page = try store.loadPage(notebookId: notebookId, pageId: pageIds[0])
        let bottom = page.pageSize.height - 100
        page.images = [makeImageDTO(uri: "images/bottom.png", x: 100, y: bottom, width: 200, height: 80)]
        try store.savePage(page)
        let thumb = try XCTUnwrap(ThumbnailRenderer.thumbnail(
            notebookId: notebookId, pageId: pageIds[0], store: store))
        let fitted = ThumbnailRenderer.fittedPageRect(pageSize: page.pageSize)
        let scale = fitted.width / CGFloat(page.pageSize.width)
        let sample = try pixel(of: thumb, x: Int(fitted.minX + 200 * scale),
                               y: Int(fitted.minY + CGFloat(bottom + 40) * scale))
        XCTAssertGreaterThan(sample.r, sample.g, "Content near the bottom of A4 was cropped from the cover")
    }

}
