import NotableKit
import PencilKit
import UIKit

/// A decoded page image with its frame in page coordinates (unzoomed).
struct PageImage {
    let image: UIImage
    let frame: CGRect
}

/// Hosts the PKCanvasView over the page content layer BEHIND the ink: the page background
/// (e.g. a rendered PDF page) plus any positioned page images. The content views are
/// siblings under the canvas, kept aligned with the canvas's scroll offset and zoom
/// (PencilKit offers no built-in background layer).
final class CanvasContainerView: UIView {
    let canvas = PKCanvasView()
    /// The "paper": a white sheet behind everything, so the page reads as a page on a desk.
    /// Deliberately white in both appearances — ink colors are authored against white.
    private let pageSheet = UIView()
    private let paperView = PaperTemplateView()
    private let backgroundImageView = UIImageView()
    private var imageViews: [UIImageView] = []
    private var didSetInitialZoom = false
    private var pendingScrollY: CGFloat?

    /// Whether the first layout zooms the page to fit the view's width (otherwise 1:1).
    var fitWidthOnOpen = true
    var pageWidth: CGFloat = 1404 {
        didSet { paperView.pageWidth = pageWidth }
    }
    private(set) var backgroundImage: UIImage?
    private(set) var pageImages: [PageImage] = []

    /// PKCanvasView looks up its UndoManager through the responder chain, and SwiftUI's
    /// hosting controller does not supply one — which leaves the tool picker's undo/redo
    /// buttons inert. Owning a manager here puts it on the chain right above the canvas,
    /// so PencilKit registers drawing edits with it and EditorView can drive/observe it.
    let pageUndoManager = UndoManager()
    override var undoManager: UndoManager? { pageUndoManager }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .secondarySystemBackground
        pageSheet.backgroundColor = .white
        pageSheet.layer.shadowColor = UIColor.black.cgColor
        pageSheet.layer.shadowOpacity = 0.12
        pageSheet.layer.shadowRadius = 8
        pageSheet.layer.shadowOffset = CGSize(width: 0, height: 2)
        addSubview(pageSheet)
        paperView.pageWidth = pageWidth
        addSubview(paperView)
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
        paperView.frame = bounds
        if !didSetInitialZoom, bounds.width > 0 {
            didSetInitialZoom = true
            let fit = bounds.width / pageWidth
            if fit < 1 {
                canvas.minimumZoomScale = min(canvas.minimumZoomScale, fit)
                if fitWidthOnOpen { canvas.zoomScale = fit }
            }
        }
        if didSetInitialZoom, let pendingScrollY {
            self.pendingScrollY = nil
            applyScroll(pageY: pendingScrollY)
        }
        updateContentGeometry()
    }

    /// Sets the ruled/dotted/grid paper drawn on the sheet. A PDF-backed page passes
    /// `.blank`: its background image already carries the paper.
    func setTemplate(_ template: NativeTemplate) {
        paperView.template = template
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
        updateContentGeometry()
    }

    /// Replaces the page image layer. Idempotent: no-op when the same images (by object
    /// identity) at the same page frames are already installed.
    func setImages(_ images: [PageImage]) {
        let unchanged = images.count == pageImages.count
            && zip(images, pageImages).allSatisfy { $0.image === $1.image && $0.frame == $1.frame }
        guard !unchanged else { return }
        pageImages = images
        for view in imageViews { view.removeFromSuperview() }
        imageViews = images.map { pageImage in
            let view = UIImageView(image: pageImage.image)
            view.contentMode = .scaleToFill
            view.clipsToBounds = true
            // Above the page background, below the ink.
            insertSubview(view, belowSubview: canvas)
            return view
        }
        updateContentGeometry()
    }

    /// Scrolls to a persisted unzoomed page-space y offset. Applied immediately once the
    /// initial layout/zoom has happened; before that it is deferred to the first layout
    /// pass (zoomScale is not final until then).
    func setInitialScroll(pageY: CGFloat) {
        let y = max(0, pageY)
        if didSetInitialZoom {
            applyScroll(pageY: y)
        } else {
            pendingScrollY = y
        }
    }

    private func applyScroll(pageY: CGFloat) {
        let target = pageY * canvas.zoomScale
        let maxOffset = max(canvas.contentSize.height - canvas.bounds.height, 0)
        canvas.contentOffset.y = min(max(target, 0), maxOffset)
    }

    /// Called on init, layout, scroll, and zoom. Keeps the content layer (background +
    /// page images) aligned with the canvas content: page coordinates scaled by zoom,
    /// translated by the scroll offset.
    func updateContentGeometry() {
        let scale = canvas.zoomScale
        let offset = canvas.contentOffset
        pageSheet.frame = CGRect(
            x: -offset.x,
            y: -offset.y,
            width: pageWidth * scale,
            height: max(canvas.contentSize.height, bounds.height * 2))
        paperView.setGeometry(zoomScale: scale, contentOffset: offset)
        if let image = backgroundImage {
            backgroundImageView.isHidden = false
            let width = pageWidth * scale
            let height = width * image.size.height / image.size.width
            backgroundImageView.frame = CGRect(
                x: -offset.x,
                y: -offset.y,
                width: width,
                height: height)
        } else {
            backgroundImageView.isHidden = true
        }
        for (view, pageImage) in zip(imageViews, pageImages) {
            let f = pageImage.frame
            view.frame = CGRect(
                x: f.origin.x * scale - offset.x,
                y: f.origin.y * scale - offset.y,
                width: f.width * scale,
                height: f.height * scale)
        }
    }
}
