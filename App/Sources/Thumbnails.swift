import NotableKit
import PencilKit
import SwiftUI
import UIKit

/// Renders notebook cover thumbnails (first page: paper + PDF background + ink) for the
/// library grid. Cached by notebook id + updatedAt, so covers refresh after edits.
@MainActor
enum ThumbnailRenderer {
    // NSCache is documented thread-safe; Swift can't see that through its ObjC interface.
    nonisolated(unsafe) private static let cache = NSCache<NSString, UIImage>()

    static let size = CGSize(width: 300, height: 400)

    static func thumbnail(for manifest: NotebookManifest, store: NotebookStore) -> UIImage? {
        let key = "\(manifest.notebookId)#\(manifest.updatedAt)" as NSString
        if let hit = cache.object(forKey: key) { return hit }

        guard let pageId = manifest.openPageId ?? manifest.pageIds.first,
              let page = try? store.loadPage(notebookId: manifest.notebookId, pageId: pageId)
        else { return nil }

        let pageWidth = EditorCanvasView.pageWidth
        let scale = size.width / pageWidth
        let pageRect = CGRect(x: 0, y: 0, width: pageWidth, height: size.height / scale)
        let notebookDir = store.notebookDirURL(manifest.notebookId)
        let background = BackgroundRenderer.image(
            for: page, notebookDir: notebookDir, storeRoot: store.rootURL)
        let drawing = PencilKitBridge.drawing(from: page.strokes)

        let image = UIGraphicsImageRenderer(size: size).image { context in
            // Paper is always white, matching how the ink colors were authored.
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            if let background {
                let height = size.width * background.size.height / background.size.width
                background.draw(in: CGRect(x: 0, y: 0, width: size.width, height: height))
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
