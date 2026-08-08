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
}
