import NotableKit
import PDFKit
import UIKit

/// Resolves and renders Notable page backgrounds.
///
/// Notable encodes PDF backgrounds as `backgroundType: "pdf<N>"` (N = 0-based page index;
/// `"autoPdf"` at notebook level materializes per-page) with `background` holding the
/// device-absolute path of the PDF. Only the basename is portable, so resolution looks for
/// the file in the notebook's `backgrounds/` dir, then the store-level `backgrounds/pdfs/`.
enum BackgroundRenderer {
    // NSCache is documented thread-safe; Swift can't see that through its ObjC interface.
    nonisolated(unsafe) private static let cache = NSCache<NSString, UIImage>()

    static func pdfPageIndex(backgroundType: String) -> Int? {
        if backgroundType == "autoPdf" { return 0 }
        guard backgroundType.hasPrefix("pdf"),
              let index = Int(backgroundType.dropFirst(3))
        else { return nil }
        return index
    }

    static func image(
        for page: PageFile,
        notebookDir: URL,
        storeRoot: URL,
        targetWidth: CGFloat = 1404
    ) -> UIImage? {
        guard let pageIndex = pdfPageIndex(backgroundType: page.backgroundType) else {
            return nil // native templates render as plain background
        }
        let basename = (page.background as NSString).lastPathComponent
        guard !basename.isEmpty else { return nil }

        let candidates = [
            notebookDir.appendingPathComponent("backgrounds/\(basename)"),
            storeRoot.appendingPathComponent("backgrounds/pdfs/\(basename)"),
        ]
        guard let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) })
        else { return nil }

        let key = "\(url.path)#\(pageIndex)" as NSString
        if let cached = cache.object(forKey: key) { return cached }

        guard let document = PDFDocument(url: url),
              document.pageCount > 0,
              let pdfPage = document.page(at: min(pageIndex, document.pageCount - 1))
        else { return nil }

        let box = pdfPage.bounds(for: .cropBox)
        guard box.width > 0 else { return nil }
        // Render at 2x the logical page width for crisp zooming.
        let size = CGSize(
            width: targetWidth * 2,
            height: targetWidth * 2 * box.height / box.width)
        let image = pdfPage.thumbnail(of: size, for: .cropBox)
        cache.setObject(image, forKey: key)
        return image
    }

    // MARK: - Page images

    /// Resolves an ImageDTO uri to a file URL. The rule lives in NotableKit because sync needs the
    /// same one: it turns these files into the content-addressed assets that carry an image to the
    /// other device, and a second copy of the rule would show up as an image that syncs but never
    /// appears.
    static func imageFileURL(uri: String?, notebookDir: URL) -> URL? {
        NotableImageFiles.url(uri: uri, notebookDir: notebookDir)
    }

    /// Decodes a page's images from disk, keyed to their page-space frames.
    /// Missing, unreadable, or degenerate (non-positive size) entries are skipped silently.
    static func pageImages(for page: PageFile, notebookDir: URL) -> [PageImage] {
        page.images.compactMap { dto in
            guard dto.width > 0, dto.height > 0,
                  let url = imageFileURL(uri: dto.uri, notebookDir: notebookDir),
                  FileManager.default.fileExists(atPath: url.path),
                  let image = UIImage(contentsOfFile: url.path)
            else { return nil }
            return PageImage(
                image: image,
                frame: CGRect(
                    x: CGFloat(dto.x), y: CGFloat(dto.y),
                    width: CGFloat(dto.width), height: CGFloat(dto.height)))
        }
    }
}
