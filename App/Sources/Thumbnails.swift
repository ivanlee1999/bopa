import NotableKit
import PencilKit
import SwiftUI
import UIKit

/// Renders notebook cover thumbnails (first page: paper + PDF background + page images + ink)
/// for the library grid. Cached by notebook id + page id + the page file's own revision, so a card
/// refreshes when its page changes and only then.
@MainActor
enum ThumbnailRenderer {
    // NSCache is documented thread-safe; Swift can't see that through its ObjC interface.
    nonisolated(unsafe) private static let cache = NSCache<NSString, UIImage>()

    static let size = CGSize(width: 300, height: 400)

    static func thumbnail(for manifest: NotebookManifest, store: NotebookStore) -> UIImage? {
        guard let pageId = manifest.openPageId ?? manifest.pageIds.first else { return nil }
        return thumbnail(notebookId: manifest.notebookId, pageId: pageId, store: store)
    }

    /// One page's thumbnail — what the page overview draws, one per page.
    ///
    /// The revision in the key is what makes the cache correct rather than merely fast, and it is
    /// the *page's* (see `NotebookStore.pageRevision`): an edited page gets a fresh entry, an
    /// untouched one is not re-rendered while the overview scrolls. It used to be the notebook's
    /// `updatedAt`, which failed in both directions — a remote apply rewrites only the page file,
    /// so ink drawn on the BOOX never refreshed its thumbnail, while a rename bumped the manifest
    /// and re-rendered every page of the notebook for a title no thumbnail draws.
    static func thumbnail(notebookId: String, pageId: String, store: NotebookStore) -> UIImage? {
        let revision = store.pageRevision(notebookId: notebookId, pageId: pageId)
        let key = "\(notebookId)#\(pageId)#\(revision)" as NSString
        if let hit = cache.object(forKey: key) { return hit }

        guard let page = try? store.loadPage(notebookId: notebookId, pageId: pageId)
        else { return nil }

        let pageWidth = CGFloat(page.pageSize.width)
        let scale = size.width / pageWidth
        let pageRect = CGRect(x: 0, y: 0, width: pageWidth, height: size.height / scale)
        let notebookDir = store.notebookDirURL(notebookId)
        let background = BackgroundRenderer.image(
            for: page, notebookDir: notebookDir, storeRoot: store.rootURL)
        // The same loading the editor uses (uri resolution included), so a picture that shows on
        // the canvas shows on the card; one whose file is missing is skipped there, not drawn as
        // a hole here.
        let pageImages = BackgroundRenderer.pageImages(for: page, notebookDir: notebookDir)
        let drawing = PencilKitBridge.drawing(from: page.strokes)

        let image = UIGraphicsImageRenderer(size: size).image { context in
            // Paper is always white, matching how the ink colors were authored.
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            if let background {
                let height = size.width * background.size.height / background.size.width
                background.draw(in: CGRect(x: 0, y: 0, width: size.width, height: height))
            }
            // Above the background, below the ink — the z-order CanvasContainerView installs
            // them in. An image-heavy page used to render as a blank card: the composite was
            // paper + background + strokes, and the images the editor draws never appeared.
            for pageImage in pageImages {
                let frame = pageImage.frame
                pageImage.image.draw(in: CGRect(
                    x: frame.origin.x * scale,
                    y: frame.origin.y * scale,
                    width: frame.width * scale,
                    height: frame.height * scale))
            }
            if !drawing.strokes.isEmpty {
                drawing.image(from: pageRect, scale: scale)
                    .draw(in: CGRect(origin: .zero, size: size))
            }
        }
        cache.setObject(image, forKey: key)
        return image
    }
}
