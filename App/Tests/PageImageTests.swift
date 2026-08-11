import NotableKit
import UIKit
import XCTest

@testable import Bopa

final class PageImageTests: XCTestCase {

    private let notebookDir = URL(
        fileURLWithPath: "/store/notebooks/nb-1", isDirectory: true)

    // MARK: - URI resolution

    func testRelativeURIResolvesUnderNotebookDir() {
        let url = BackgroundRenderer.imageFileURL(
            uri: "images/abc.jpg", notebookDir: notebookDir)
        XCTAssertEqual(url?.path, "/store/notebooks/nb-1/images/abc.jpg")
    }

    func testAbsoluteAndroidPathResolvesByBasenameUnderImagesDir() {
        let url = BackgroundRenderer.imageFileURL(
            uri: "/storage/emulated/0/Android/data/com.ethran.notable/files/images/xyz.png",
            notebookDir: notebookDir)
        XCTAssertEqual(url?.path, "/store/notebooks/nb-1/images/xyz.png")
    }

    func testNilAndEmptyURIsResolveToNil() {
        XCTAssertNil(BackgroundRenderer.imageFileURL(uri: nil, notebookDir: notebookDir))
        XCTAssertNil(BackgroundRenderer.imageFileURL(uri: "", notebookDir: notebookDir))
    }

    /// A uri arrives inside a document another device wrote, so it cannot be allowed to point
    /// anywhere but at an image of this notebook.
    func testAURICannotClimbOutOfTheImagesDirectory() {
        for escape in ["images/../manifest.json", "../../folders.json", "images/..", "."] {
            let url = BackgroundRenderer.imageFileURL(uri: escape, notebookDir: notebookDir)
            guard let url else { continue }
            XCTAssertEqual(
                url.deletingLastPathComponent().standardizedFileURL.path,
                "/store/notebooks/nb-1/images",
                "`\(escape)` resolved outside the notebook's images/")
        }
    }

    // MARK: - Loading

    private func makePage(images: [ImageDTO]) -> PageFile {
        let now = NotableDate.format(Date())
        return PageFile(
            id: "p1", notebookId: "nb-1", createdAt: now, updatedAt: now, images: images)
    }

    private func makeImageDTO(
        uri: String?, x: Int = 10, y: Int = 20, width: Int = 300, height: Int = 200
    ) -> ImageDTO {
        let now = NotableDate.format(Date())
        return ImageDTO(
            id: UUID().uuidString.lowercased(), x: x, y: y, width: width, height: height,
            uri: uri, createdAt: now, updatedAt: now)
    }

    func testMissingFilesAreSkippedSilently() {
        let page = makePage(images: [
            makeImageDTO(uri: "images/does-not-exist.jpg"),
            makeImageDTO(uri: nil),
        ])
        let loaded = BackgroundRenderer.pageImages(for: page, notebookDir: notebookDir)
        XCTAssertTrue(loaded.isEmpty)
    }

    func testDegenerateSizesAreSkipped() throws {
        let dir = try makeNotebookDirWithImage(named: "pix.png")
        defer { try? FileManager.default.removeItem(at: dir) }
        let page = makePage(images: [
            makeImageDTO(uri: "images/pix.png", width: 0, height: 200),
            makeImageDTO(uri: "images/pix.png", width: 300, height: -1),
        ])
        XCTAssertTrue(BackgroundRenderer.pageImages(for: page, notebookDir: dir).isEmpty)
    }

    func testLoadsExistingImageWithPageFrame() throws {
        let dir = try makeNotebookDirWithImage(named: "pix.png")
        defer { try? FileManager.default.removeItem(at: dir) }

        let page = makePage(images: [
            makeImageDTO(uri: "images/pix.png", x: 100, y: 250, width: 640, height: 480)
        ])
        let loaded = BackgroundRenderer.pageImages(for: page, notebookDir: dir)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.frame, CGRect(x: 100, y: 250, width: 640, height: 480))
    }

    /// Creates a temp notebook dir containing images/<name> (a tiny valid PNG).
    private func makeNotebookDirWithImage(named name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PageImageTests-\(UUID().uuidString)", isDirectory: true)
        let imagesDir = dir.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(
            at: imagesDir, withIntermediateDirectories: true)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let png = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4), format: format)
            .pngData { ctx in
                UIColor.systemRed.setFill()
                ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
            }
        try png.write(to: imagesDir.appendingPathComponent(name))
        return dir
    }
}
