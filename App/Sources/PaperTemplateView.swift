import NotableKit
import UIKit

/// Draws Notable's native paper templates (lines/dots/grid/hexes) behind the ink, using
/// NotableKit's `NativeTemplateRenderer` so the geometry stays identical to
/// `TemplateRenderer`'s rasterized backdrops (and to the BOOX).
///
/// Unlike `TemplateRenderer.image(for:)`, this draws straight into the live view context on
/// every scroll/zoom tick instead of rasterizing a bitmap per frame — cheap for these simple
/// vector patterns, and it keeps the view's backing store to the size of the visible canvas
/// rather than a content-sized one, which an infinite page cannot afford.
final class PaperTemplateView: UIView {
    var template: NativeTemplate = .blank {
        didSet { redrawIfChanged(oldValue != template) }
    }
    var pageWidth: CGFloat = 1404 {
        didSet { redrawIfChanged(oldValue != pageWidth) }
    }

    /// The declared sheet height, or 0 for a page that declares none. What the export splits on.
    var sheetHeight: CGFloat = 0 {
        didSet { redrawIfChanged(oldValue != sheetHeight) }
    }

    /// Whether to mark where an export would break the page.
    var showsSheetBoundaries = false {
        didSet { redrawIfChanged(oldValue != showsSheetBoundaries) }
    }

    private var zoomScale: CGFloat = 1
    private var contentOffset: CGPoint = .zero

    private var isBlank: Bool { !template.isDrawable }

    /// Whether there are breaks to draw: a page that declares a sheet, on a canvas that runs past
    /// the bottom of it.
    private var drawsBoundaries: Bool { showsSheetBoundaries && sheetHeight > 0 }

    /// Nothing to paint at all — the one case where the view can sit out the redraw entirely.
    private var drawsNothing: Bool { isBlank && !drawsBoundaries }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
        contentMode = .redraw
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Called on every scroll/zoom tick; redraws only when the geometry actually moved.
    func setGeometry(zoomScale: CGFloat, contentOffset: CGPoint) {
        guard zoomScale != self.zoomScale || contentOffset != self.contentOffset else { return }
        self.zoomScale = zoomScale
        self.contentOffset = contentOffset
        if !drawsNothing { setNeedsDisplay() }
    }

    private func redrawIfChanged(_ changed: Bool) {
        guard changed else { return }
        isHidden = drawsNothing
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard !drawsNothing, pageWidth > 0, let context = UIGraphicsGetCurrentContext()
        else { return }
        let scale = max(zoomScale, 0.01)
        let minY = max(contentOffset.y / scale, 0)
        let viewportMaxY = (contentOffset.y + bounds.height) / scale
        // A declared page's paper and template stop at its physical edge. Letting the white
        // template continue into the scroll view's overshoot made that rubber-band area look like
        // another page even when the canvas extent itself was correct.
        let maxY = sheetHeight > 0 ? min(viewportMaxY, sheetHeight) : viewportMaxY
        guard maxY > minY else { return }

        context.saveGState()
        // Page point -> view point, so the renderer can work purely in page coordinates.
        context.translateBy(x: -contentOffset.x, y: -contentOffset.y)
        context.scaleBy(x: scale, y: scale)
        if !isBlank {
            NativeTemplateRenderer.draw(
                template, in: context,
                viewport: CGRect(x: 0, y: minY, width: pageWidth, height: maxY - minY),
                pageWidth: pageWidth)
        }
        if drawsBoundaries {
            drawSheetBoundaries(in: context, from: minY, to: maxY, scale: scale)
        }
        context.restoreGState()
    }

    /// Marks where an export would cut the page.
    ///
    /// The canvas is continuous and the export is not: it splits at fixed sheet-height intervals.
    /// With nothing drawn there, the user writes straight across a break without knowing one
    /// exists — the export stays technically complete, and a diagram or a line of handwriting
    /// comes out cut in half.
    ///
    /// Drawn as a hairline that stays a hairline at any zoom, and in a grey light enough to read
    /// as paper furniture rather than as ink. It has to be quieter than anything the user could
    /// have written, or it becomes a mark on their page instead of a fact about the paper.
    private func drawSheetBoundaries(
        in context: CGContext, from minY: CGFloat, to maxY: CGFloat, scale: CGFloat
    ) {
        let first = max(1, Int((minY / sheetHeight).rounded(.down)))
        let last = Int((maxY / sheetHeight).rounded(.up))
        guard last >= first else { return }

        context.setStrokeColor(UIColor(white: 0.72, alpha: 1).cgColor)
        context.setLineWidth(1 / scale)
        context.setLineDash(phase: 0, lengths: [12 / scale, 10 / scale])
        for index in first...last {
            let y = CGFloat(index) * sheetHeight
            guard y >= minY, y <= maxY else { continue }
            context.move(to: CGPoint(x: 0, y: y))
            context.addLine(to: CGPoint(x: pageWidth, y: y))
        }
        context.strokePath()
        context.setLineDash(phase: 0, lengths: [])
    }
}
