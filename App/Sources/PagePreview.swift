import NotableKit
import PencilKit
import UIKit

/// What is drawn beside the live canvas under continuous scrolling: a neighbouring page, below
/// the seam for the page after this one and above the top for the page before it.
///
/// Only ever a *picture* of that page. The canvas holds one page's ink and nothing else — a
/// second live PKCanvasView beside it would be a second undo stack, a second tool, and a second
/// place a stroke could land. The real page arrives when the scroll commits to it, and this is
/// replaced by the canvas itself; until then it exists so the reader can see what they are
/// scrolling into.
struct PagePreview: Equatable {
    let pageId: String
    /// The page's own sheet — its paper is drawn at its own size, not the current page's.
    let pageSize: PageSize
    let template: NativeTemplate
    /// Everything on the page — ink, images, text boxes — rendered as one picture, or nil for a
    /// page with nothing on it.
    let content: UIImage?
    /// Where `content` sits on the page, in page units. The picture is cropped to what the page
    /// actually holds rather than covering the sheet, so a page with three lines on it costs a
    /// strip of bitmap, not a sheet of it.
    let contentFrame: CGRect
    /// The page background (a PDF page, a photo), already fitted to the sheet width.
    let background: UIImage?

    static func == (lhs: PagePreview, rhs: PagePreview) -> Bool {
        lhs.pageId == rhs.pageId && lhs.pageSize == rhs.pageSize
            && lhs.template == rhs.template && lhs.content === rhs.content
            && lhs.contentFrame == rhs.contentFrame && lhs.background === rhs.background
    }
}

enum PagePreviewRenderer {
    /// The scale the picture is rasterized at. It is displayed at the canvas's zoom — about one
    /// point per page unit at the width fit — so 2x leaves it crisp on a Retina panel, which it
    /// has to be: it is on screen right up to the moment the live canvas takes its place.
    static let renderScale: CGFloat = 2

    /// A ceiling on one picture's bitmap, in pixels. A sheet covered edge to edge at 2x is about
    /// ten million; anything bigger — a very tall legacy page — is rendered a little softer
    /// rather than holding hundreds of megabytes for a neighbour.
    static let maximumPixels: CGFloat = 12_000_000

    /// Renders everything on the page — its images, its text boxes and its ink — as one picture
    /// in page coordinates, cropped to where there is something to draw. Returns nil when the
    /// page is empty, so a blank page costs no bitmap at all (which is the common case: the page
    /// just created by scrolling off the end of the notebook).
    static func content(
        strokes: PKDrawing, images: [PageImage], blocks: [CouchBlock] = [], pageSize: PageSize
    ) -> (image: UIImage, frame: CGRect)? {
        let sheet = CGRect(
            x: 0, y: 0, width: CGFloat(pageSize.width), height: CGFloat(pageSize.height))
        let visibleImages = images.filter { $0.frame.intersects(sheet) }
        let visibleBlocks = TextBoxLayout.textBoxes(in: blocks).filter {
            TextBoxLayout.frame(of: $0)?.intersects(sheet) == true
        }
        let hasInk = !strokes.strokes.isEmpty && strokes.bounds.intersects(sheet)

        var covered = CGRect.null
        if hasInk { covered = covered.union(strokes.bounds) }
        for pageImage in visibleImages { covered = covered.union(pageImage.frame) }
        for block in visibleBlocks {
            if let frame = TextBoxLayout.frame(of: block) { covered = covered.union(frame) }
        }
        let frame = covered.intersection(sheet).integral.intersection(sheet)
        guard !frame.isNull, frame.width > 0, frame.height > 0 else { return nil }

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = min(
            renderScale, (maximumPixels / (frame.width * frame.height)).squareRoot())
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: frame.size, format: format).image { context in
            context.cgContext.translateBy(x: -frame.minX, y: -frame.minY)
            for pageImage in visibleImages {
                pageImage.image.draw(in: pageImage.frame)
            }
            // Below the ink, as everywhere else. Without this, scrolling towards a page of typed
            // notes shows blank paper beside the seam and the words appear only once the page
            // commits — which looks exactly like the text was lost.
            TextBoxLayout.draw(blocks: visibleBlocks, in: context.cgContext, scale: 1)
            if hasInk {
                // `image(from:scale:)` returns just the requested rect, so it is drawn back into
                // that rect rather than at the strokes' own coordinates.
                strokes.image(from: frame, scale: format.scale).draw(in: frame)
            }
        }
        return (image, frame)
    }
}

/// A neighbouring page read, decoded and rendered ahead of the scroll.
///
/// Entering a page used to do all of this on the main thread at the moment of the crossing — in
/// the middle of the scroll that asked for it: read megabytes of JSON, decode it, rebuild every
/// stroke for PencilKit, decode the page's images. On an inked page that is a visible stall per
/// page turned. Prepared off the main actor while the reader is still on the page before, the
/// crossing only has to hand these to the canvas.
///
/// `@unchecked` because `PKDrawing` does not declare itself `Sendable`. It is a value type and
/// nothing here is mutated after construction; the value is built on one thread and only read
/// on the main one.
struct PreparedPage: @unchecked Sendable {
    let file: PageFile
    /// The page file's revision as it was read — what decides whether this copy is still the
    /// page on disk. A copy whose revision no longer matches is never opened from; it is only
    /// kept on screen as a preview until its replacement is ready.
    let revision: String
    let drawing: PKDrawing
    let background: UIImage?
    let images: [PageImage]
    let preview: PagePreview

    /// Reads and prepares a page, off the main actor. Nil when the file cannot be read — the
    /// page itself is loaded properly (and its error reported) when the scroll commits to it.
    nonisolated static func read(
        pageId: String, notebookId: String, store: NotebookStore
    ) -> PreparedPage? {
        // The revision is taken *before* the read. A write landing between the two then leaves
        // this copy looking older than the file, which only costs a synchronous load later; the
        // other order would pass stale content off as current.
        let revision = store.pageRevision(notebookId: notebookId, pageId: pageId)
        guard let file = try? store.readPage(notebookId: notebookId, pageId: pageId) else {
            return nil
        }
        let notebookDir = store.notebookDirURL(notebookId)
        let drawing = PencilKitBridge.drawing(from: file.strokes)
        let background = BackgroundRenderer.image(
            for: file, notebookDir: notebookDir, storeRoot: store.rootURL)
        // Decoded here rather than left lazy: a UIImage read from a file decodes the first time
        // it is drawn, which would be on the main thread, on the frame the page arrives.
        let images = BackgroundRenderer.pageImages(for: file, notebookDir: notebookDir).map {
            PageImage(image: $0.image.preparingForDisplay() ?? $0.image, frame: $0.frame)
        }

        var template = NativeTemplate.blank
        if case .native(let native) = PageBackground(
            background: file.background, backgroundType: file.backgroundType),
            native.isDrawable
        {
            template = native
        }
        let content = PagePreviewRenderer.content(
            strokes: drawing, images: images, blocks: file.blocks, pageSize: file.pageSize)
        let preview = PagePreview(
            pageId: pageId,
            pageSize: file.pageSize,
            template: template,
            content: content?.image,
            contentFrame: content?.frame ?? .zero,
            background: background)
        return PreparedPage(
            file: file, revision: revision, drawing: drawing, background: background,
            images: images, preview: preview)
    }
}
