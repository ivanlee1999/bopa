import PencilKit
import UIKit

/// Hosts the PKCanvasView with a page background (e.g. a rendered PDF page) BEHIND the ink.
/// The background is a sibling under the canvas, kept aligned with the canvas's scroll
/// offset and zoom (PencilKit offers no built-in background layer).
final class CanvasContainerView: UIView {
    let canvas = PKCanvasView()
    private let backgroundImageView = UIImageView()
    private var didSetInitialZoom = false

    var pageWidth: CGFloat = 1404
    private(set) var backgroundImage: UIImage?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .systemBackground
        backgroundImageView.contentMode = .scaleAspectFit
        backgroundImageView.isHidden = true
        addSubview(backgroundImageView)

        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        addSubview(canvas)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        canvas.frame = bounds
        if !didSetInitialZoom, bounds.width > 0 {
            didSetInitialZoom = true
            let fit = bounds.width / pageWidth
            if fit < 1 {
                canvas.minimumZoomScale = min(canvas.minimumZoomScale, fit)
                canvas.zoomScale = fit
            }
        }
        updateBackgroundGeometry()
    }

    func setBackground(_ image: UIImage?) {
        guard image !== backgroundImage else { return }
        backgroundImage = image
        backgroundImageView.image = image
        if let image {
            // Make sure the page is scrollable to the bottom of the background.
            let contentHeight = pageWidth * image.size.height / image.size.width
            if contentHeight > canvas.contentSize.height / max(canvas.zoomScale, 0.01) {
                canvas.contentSize.height = contentHeight * canvas.zoomScale
            }
        }
        updateBackgroundGeometry()
    }

    /// Called on init, layout, scroll, and zoom.
    func updateBackgroundGeometry() {
        guard let image = backgroundImage else {
            backgroundImageView.isHidden = true
            return
        }
        backgroundImageView.isHidden = false
        let scale = canvas.zoomScale
        let width = pageWidth * scale
        let height = width * image.size.height / image.size.width
        backgroundImageView.frame = CGRect(
            x: -canvas.contentOffset.x,
            y: -canvas.contentOffset.y,
            width: width,
            height: height)
    }
}
