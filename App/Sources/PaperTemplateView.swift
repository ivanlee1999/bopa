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
    private var zoomScale: CGFloat = 1
    private var contentOffset: CGPoint = .zero

    private var isBlank: Bool { !template.isDrawable }

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
        if !isBlank { setNeedsDisplay() }
    }

    private func redrawIfChanged(_ changed: Bool) {
        guard changed else { return }
        isHidden = isBlank
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard !isBlank, pageWidth > 0, let context = UIGraphicsGetCurrentContext() else { return }
        let scale = max(zoomScale, 0.01)
        let minY = max(contentOffset.y / scale, 0)
        let maxY = (contentOffset.y + bounds.height) / scale
        guard maxY > minY else { return }

        context.saveGState()
        // Page point -> view point, so the renderer can work purely in page coordinates.
        context.translateBy(x: -contentOffset.x, y: -contentOffset.y)
        context.scaleBy(x: scale, y: scale)
        NativeTemplateRenderer.draw(
            template, in: context,
            viewport: CGRect(x: 0, y: minY, width: pageWidth, height: maxY - minY),
            pageWidth: pageWidth)
        context.restoreGState()
    }
}
