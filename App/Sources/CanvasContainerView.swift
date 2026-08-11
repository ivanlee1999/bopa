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
    private var pendingScrollY: CGFloat?
    /// The view's width at the last layout pass, so a rotation (or a Split View resize) can
    /// be told apart from the ordinary layout passes that happen at the same width. Zero
    /// until the first real layout, i.e. before the zoom is known.
    private var laidOutWidth: CGFloat = 0
    /// Whether the page is currently zoomed to exactly fill the view's width. Only in that
    /// state does a width change re-fit the page — someone who zoomed in to write keeps
    /// their zoom across a rotation.
    private var isFitToWidth = true

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
        // Desk and page: a flat ground with the sheet edged rather than floated, so the
        // page reads as drawn on the surface instead of hovering over it.
        backgroundColor = UIColor(hex: 0xEEECE9)
        pageSheet.backgroundColor = .white
        pageSheet.layer.borderColor = UIColor(hex: 0x7D7979).cgColor
        pageSheet.layer.borderWidth = 1
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
        if bounds.width > 0, bounds.width != laidOutWidth {
            let isFirstLayout = laidOutWidth == 0
            laidOutWidth = bounds.width
            if isFirstLayout {
                applyInitialZoom()
            } else {
                adjustZoomForNewWidth()
            }
        }
        if laidOutWidth > 0, let pendingScrollY {
            self.pendingScrollY = nil
            applyScroll(pageY: pendingScrollY)
        }
        updateContentGeometry()
    }

    /// The zoom at which the page exactly fills the view's width, capped at 1:1 — a page is
    /// never blown up just because the window is wide.
    private var fitWidthZoom: CGFloat {
        guard bounds.width > 0, pageWidth > 0 else { return 1 }
        return min(bounds.width / pageWidth, 1)
    }

    private func applyInitialZoom() {
        let fit = fitWidthZoom
        canvas.minimumZoomScale = min(canvas.minimumZoomScale, fit)
        if fitWidthOnOpen {
            canvas.zoomScale = fit
            isFitToWidth = true
        } else {
            isFitToWidth = canvas.zoomScale == fit
        }
    }

    /// Re-fits the page after the view's width changes — a rotation, or a Split View /
    /// Stage Manager resize. Without this the zoom stays at the old width's fit: turning
    /// the iPad to landscape leaves the page marooned in a band of empty space, and turning
    /// it back to portrait overflows the page off-screen with the minimum zoom still set
    /// from the wider layout, so it cannot be pinched back into view.
    private func adjustZoomForNewWidth() {
        let fit = fitWidthZoom
        // Never leave the user unable to zoom out far enough to see the whole page width.
        canvas.minimumZoomScale = min(canvas.minimumZoomScale, fit)
        // The offset is in (zoomed) view points, so re-derive it from the page-space
        // position: rotating should keep you where you were writing, not jump the page.
        let anchorY = canvas.contentOffset.y / max(canvas.zoomScale, 0.01)
        // A zoomed-in page keeps its zoom (you were writing at that size); only the
        // minimum above changes, so the narrower screen can still be pinched back to fit.
        if isFitToWidth {
            canvas.zoomScale = fit
        }
        applyScroll(pageY: anchorY)
    }

    /// Called by the canvas delegate whenever the zoom changes. Remembers whether the page
    /// is still fitted to the width, which is what the next width change preserves.
    func canvasZoomDidChange() {
        isFitToWidth = abs(canvas.zoomScale - fitWidthZoom) < 0.005
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
        if laidOutWidth > 0 {
            applyScroll(pageY: y)
        } else {
            pendingScrollY = y
        }
    }

    /// Centres the page when the view is wider than the zoomed page — a zoomed-out page, or
    /// a landscape window wider than the 1:1 page. Done with contentInset rather than by
    /// moving views, so the ink (which lives in the canvas's own coordinate space) travels
    /// with the paper: every content view below is positioned from `contentOffset` too.
    private func centerPageHorizontally() {
        let slack = max((bounds.width - pageWidth * canvas.zoomScale) / 2, 0).rounded()
        guard canvas.contentInset.left != slack else { return }
        canvas.contentInset.left = slack
        canvas.contentInset.right = slack
        // With the page narrower than the view there is nothing to scroll to sideways, so
        // pin it to the centred position rather than leaving it wherever it was.
        if slack > 0 { canvas.contentOffset.x = -slack }
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
        centerPageHorizontally()
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
