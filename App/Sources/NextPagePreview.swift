import NotableKit
import PencilKit
import UIKit

/// What is drawn below the seam: the top of the next page, enough of it to fill a screen.
///
/// Only ever a *picture* of that page. The canvas holds one page's ink and nothing else — a
/// second live PKCanvasView below the seam would be a second undo stack, a second tool, and a
/// second place a stroke could land. The real page arrives when the scroll commits to it, and
/// this is replaced by the canvas itself; until then it exists so the reader can see what they
/// are scrolling into.
struct NextPagePreview: Equatable {
    let pageId: String
    /// The next page's own sheet — its paper is drawn at its own width, not the current page's.
    let pageSize: PageSize
    let template: NativeTemplate
    /// The top strip of the page, rendered: ink, and any images that fall in it.
    let content: UIImage?
    /// How tall that strip is, in page units. Stored rather than assumed: the view has to be
    /// sized from what was actually rendered, or the ink stops partway down a band whose paper
    /// keeps going.
    let contentHeight: CGFloat
    /// The page background (a PDF page, a photo), already fitted to the sheet width.
    let background: UIImage?

    static func == (lhs: NextPagePreview, rhs: NextPagePreview) -> Bool {
        lhs.pageId == rhs.pageId && lhs.pageSize == rhs.pageSize
            && lhs.template == rhs.template && lhs.content === rhs.content
            && lhs.contentHeight == rhs.contentHeight && lhs.background === rhs.background
    }
}

enum NextPagePreviewRenderer {
    /// How far down the next page is worth rendering, at most. A tall iPad screen is ~1400 page
    /// units at the width fit, and the preview is only ever seen until the seam scrolls off the
    /// top — but a zoomed-out view can show more, so this is a ceiling on work rather than a
    /// promise, and the strip never exceeds the page's own sheet.
    static let maximumStripHeight: CGFloat = 3000

    /// The scale the strip is rasterized at. The preview is displayed at the canvas's zoom
    /// (about 1 point per page unit at the width fit), so 2x leaves it crisp on a Retina panel
    /// without holding a sheet-sized bitmap per neighbor.
    static let renderScale: CGFloat = 2

    /// Renders the top of [page] — its ink, and the images that fall in the strip — as one
    /// image in page coordinates. Returns nil when the page has nothing to draw there, so an
    /// empty next page costs no bitmap at all (which is the common case: the page just created
    /// by scrolling off the end of the notebook).
    static func content(
        strokes: PKDrawing, images: [PageImage], pageSize: PageSize
    ) -> (image: UIImage, height: CGFloat)? {
        let pageWidth = CGFloat(pageSize.width)
        let height = min(CGFloat(pageSize.height), maximumStripHeight)
        let strip = CGRect(x: 0, y: 0, width: pageWidth, height: height)
        let visibleImages = images.filter { $0.frame.intersects(strip) }
        let hasInk = !strokes.strokes.isEmpty && strokes.bounds.intersects(strip)
        guard hasInk || !visibleImages.isEmpty else { return nil }

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = renderScale
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: strip.size, format: format).image { _ in
            for pageImage in visibleImages {
                pageImage.image.draw(in: pageImage.frame)
            }
            if hasInk {
                // `image(from:scale:)` returns just the requested rect, so it is drawn at the
                // strip's origin rather than at the stroke's own coordinates.
                strokes.image(from: strip, scale: renderScale).draw(in: strip)
            }
        }
        return (image, height)
    }
}
