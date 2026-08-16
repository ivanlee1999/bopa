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

    /// Whether the page is kept fitted to the view's width: fitted on open, re-fitted on
    /// every width change, until a pinch takes it off the fit. Off means "actual size":
    /// open at 1:1 and leave the zoom alone.
    var keepsFitToWidth = true
    /// The width of the sheet, in page units — the page's declared page size, or the legacy
    /// fallback. What "fit to width" fits, and how wide the paper is drawn.
    var pageWidth: CGFloat = CGFloat(PageSize.legacyUndeclared.width) {
        didSet { paperView.pageWidth = pageWidth }
    }
    /// The declared sheet height, or 0 for a page that declares none — what an export splits on,
    /// and so what the page-break hairlines are drawn at. Zero draws none: a page with no agreed
    /// sheet has no break to promise.
    var sheetHeight: CGFloat = 0 {
        didSet { paperView.sheetHeight = sheetHeight }
    }
    /// Slack kept to the right of ink that overflows the sheet, so the last stroke is not flush
    /// against the edge of the scrollable area. Small on purpose: unlike the downward slack,
    /// which is room to keep writing, this only has to make the overflow legible.
    private static let horizontalInkSlack: CGFloat = 100
    /// Room below the lowest thing on the page — space to keep writing, not just to see the edge.
    private static let verticalInkSlack: CGFloat = 1000
    private(set) var backgroundImage: UIImage?
    private(set) var pageImages: [PageImage] = []
    /// The union of the page image frames, in page units, and of the background's. Kept because
    /// the extent has to cover them and they can be installed on either side of it being set.
    private var imageBounds: CGRect = .null
    private var backgroundBounds: CGRect = .null

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
        // The container is the viewport, and everything below is positioned by scroll offset:
        // the sheet starts at `-contentOffset.y` and is at least two screens tall, so any scroll
        // or zoom puts part of it outside these bounds. The canvas clips itself (it is a scroll
        // view), but the sheet, the background and the page images are plain sibling views, and
        // unclipped they painted white over the chrome around the canvas — scroll down far enough
        // and the page covered the top bar and the tool rail entirely.
        clipsToBounds = true
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

    /// The zoom at which the page exactly fills the view's width. Uncapped in both
    /// directions: a landscape iPad is wider than the 1404pt page, and "fit width" there
    /// means filling the screen rather than leaving the page marooned in empty desk.
    static func fitZoom(viewWidth: CGFloat, pageWidth: CGFloat) -> CGFloat {
        guard viewWidth > 0, pageWidth > 0 else { return 1 }
        return viewWidth / pageWidth
    }

    /// Fit the whole sheet on screen rather than just its width.
    ///
    /// What "the page fits" means depends on which way you turn it, and the two established
    /// answers are the ones reMarkable, the Kindle Scribe and GoodNotes all land on: turning
    /// sideways shows one whole page at a time, because a page you cannot see all of is not a page
    /// you can turn past; scrolling down fits the width and lets the page run off the bottom,
    /// because that is the direction you are about to travel in.
    var fitsWholePage = false

    private var fitWidthZoom: CGFloat {
        let widthFit = Self.fitZoom(viewWidth: bounds.width, pageWidth: pageWidth)
        guard fitsWholePage, sheetHeight > 0, bounds.height > 0 else { return widthFit }
        // The smaller of the two, so neither edge is cut off.
        return min(widthFit, bounds.height / sheetHeight)
    }

    /// Widens the scroll view's zoom range so the fit is actually reachable — the fit can
    /// fall outside the configured range at either end (a narrow window needs less than the
    /// minimum, a landscape iPad more than the maximum), and a clamped fit is not a fit.
    private func allowZoom(_ fit: CGFloat) {
        canvas.minimumZoomScale = min(canvas.minimumZoomScale, fit)
        canvas.maximumZoomScale = max(canvas.maximumZoomScale, fit)
    }

    private func applyInitialZoom() {
        let fit = fitWidthZoom
        allowZoom(fit)
        if keepsFitToWidth {
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
        // Never leave the user unable to reach the zoom that fits the new width.
        allowZoom(fit)
        // The offset is in (zoomed) view points, so re-derive it from the page-space
        // position: rotating should keep you where you were writing, not jump the page.
        let anchorY = canvas.contentOffset.y / max(canvas.zoomScale, 0.01)
        // A zoomed-in page keeps its zoom (you were writing at that size); only the
        // range above changes, so the narrower screen can still be pinched back to fit.
        if keepsFitToWidth, isFitToWidth {
            canvas.zoomScale = fit
        }
        applyScroll(pageY: anchorY)
    }

    /// Fits the page to the view's width now and marks it as sitting on the fit — the way
    /// back after a pinch has taken it off. Whether later width changes *keep* it fitted is
    /// `keepsFitToWidth`'s business, which mirrors the user's preference: this deliberately
    /// does not switch that on, or the canvas would start re-fitting rotations behind the
    /// back of a setting that says "actual size". Callers that mean to change the mode set
    /// the preference, and the config is pushed down from there.
    func fitToWidth() {
        guard bounds.width > 0 else { return }
        let fit = fitWidthZoom
        allowZoom(fit)
        // Re-arming is the cheap half and happens either way; moving the page is only work
        // when it is actually somewhere else. Being asked twice — the ••• menu both sets the
        // preference and fits, and the config change fits again — must not fit twice.
        let alreadyFitted = isFitToWidth && canvas.zoomScale == fit
        isFitToWidth = true
        guard !alreadyFitted else { return }
        // Same page-space anchor as a rotation: re-fitting changes the scale, not the place.
        let anchorY = canvas.contentOffset.y / max(canvas.zoomScale, 0.01)
        canvas.zoomScale = fit
        applyScroll(pageY: anchorY)
        updateContentGeometry()
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
        // Through the same rule as ink and images, so the page is scrollable to the bottom of the
        // background however the extent is next recomputed — a page switch used to reset the
        // extent from the sheet and the ink alone, with nothing left saying how tall the
        // background was.
        backgroundBounds =
            image.map {
                CGRect(
                    x: 0, y: 0, width: pageWidth,
                    height: pageWidth * $0.size.height / $0.size.width)
            } ?? .null
        growContent(toCover: backgroundBounds)
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
        // An image can sit anywhere on the page, including well below the sheet or past its right
        // edge — dropped there by the user, or arriving there from the BOOX. Installing the view
        // without growing the scrollable area did not merely park it off-page: there was nothing
        // to scroll to and no zoom that brought it back, so the image existed, rendered, and could
        // not be reached.
        imageBounds = images.reduce(CGRect.null) { $0.union($1.frame) }
        growContent(toCover: imageBounds)
        updateContentGeometry()
    }

    /// Applies the sheet width of the page being shown, re-fitting when it actually changes.
    ///
    /// Needed as its own step because the editor loads a page *after* the canvas exists: the first
    /// layout fits whatever width was known then (the fallback), and the page's real sheet arrives
    /// a moment later. Without re-fitting, the page would sit at the previous sheet's zoom — very
    /// slightly wrong for an A4 page opened at the 1404 fallback, and obviously wrong for A3.
    ///
    /// "Actual size" is left alone, and so is a page the user has pinched off the fit: the zoom is
    /// theirs, and only the range is widened so the new fit stays reachable.
    func setPageWidth(_ width: CGFloat) {
        guard width > 0, width != pageWidth else { return }
        let wasFitted = isFitToWidth
        pageWidth = width
        guard laidOutWidth > 0 else { return }
        allowZoom(fitWidthZoom)
        if keepsFitToWidth, wasFitted {
            canvas.zoomScale = fitWidthZoom
            isFitToWidth = true
        }
        updateContentGeometry()
    }

    /// The scrollable area in page units. `contentSize` is in zoomed points — the same reading
    /// `setBackground` and `applyScroll` work from — so both directions go through the zoom.
    var contentExtent: CGSize {
        get {
            let scale = max(canvas.zoomScale, 0.01)
            return CGSize(
                width: canvas.contentSize.width / scale,
                height: canvas.contentSize.height / scale)
        }
        set {
            let scale = max(canvas.zoomScale, 0.01)
            canvas.contentSize = CGSize(
                width: newValue.width * scale, height: newValue.height * scale)
        }
    }

    /// Whether a rect can be scrolled to at all.
    ///
    /// An EMPTY drawing has a null bounds whose maxX/maxY are CGFLOAT_MAX; letting that through
    /// breaks the scroll view's gesture system and permanently disables inking (found by UI-test
    /// bisect). Page images and backgrounds go through the same gate — an unreadable image and a
    /// half-decoded frame can produce the same nonsense.
    private static func isReachable(_ rect: CGRect) -> Bool {
        !rect.isNull && rect.maxX.isFinite && rect.maxY.isFinite
    }

    /// The one rule for how big the scrollable area is: the sheet, and everything the page holds
    /// beyond it.
    ///
    /// The width matters as much as the height. Content can sit to the *right* of the sheet — a
    /// page written on a BOOX whose screen is wider than this page's sheet puts it there, a page
    /// from before page sizes existed has no agreed sheet at all, and an image can simply be
    /// dropped past the edge — and an area that stops at the sheet's edge does not merely park
    /// that content off-page, it makes it unreachable: there is nothing to scroll to and no zoom
    /// that brings it back. So the area covers everything the page holds, and the paper stays
    /// sheet-sized underneath it.
    ///
    /// One function because the answer has to be the same however it is reached — opening a page,
    /// drawing a stroke, installing an image, setting a background. Sizing the extent from the
    /// ink alone is what left images unreachable.
    private func contentSize(
        floor: CGSize, covering rects: [CGRect]
    ) -> CGSize {
        var size = floor
        for rect in rects where Self.isReachable(rect) {
            size.width = max(size.width, rect.maxX + Self.horizontalInkSlack)
            size.height = max(size.height, rect.maxY + Self.verticalInkSlack)
        }
        return size
    }

    /// Sizes the scrollable area to a page. Authoritative: pages in a notebook can declare
    /// different sheets, so opening one resets the extent rather than growing into it — which is
    /// why the images and the background have to be part of the rule and not grown in afterwards.
    func setContentExtent(pageSize: PageSize, ink: CGRect, minimumHeight: CGFloat) {
        contentExtent = contentSize(
            floor: CGSize(width: CGFloat(pageSize.width), height: minimumHeight),
            covering: [ink, imageBounds, backgroundBounds])
        updateContentGeometry()
    }

    /// Grows the scrollable area to keep covering content that is being added to. Grow-only: the
    /// extent a page opened with is a floor, so writing near an edge never yanks the scroll
    /// position around.
    ///
    /// **It no longer grows downward past the sheet.** Writing to the bottom and carrying on used
    /// to make the page taller, which is how a notebook ended up with hours of work below the first
    /// sheet where nothing that thinks in pages could reach it — the overview drew one thumbnail
    /// for all of it. The page ends where the sheet ends; the way to keep writing is the next page.
    ///
    /// Sideways growth is untouched, and so is whatever height the page opened at. Content can
    /// legitimately sit outside the sheet — written on a wider BOOX screen, or on a page from
    /// before sheets were agreed — and an area that refused to cover it would not merely park it
    /// off-page, it would make it unreachable. This stops the page *growing*; it never shrinks one.
    func growContent(toCover rect: CGRect) {
        guard Self.isReachable(rect) else { return }
        let current = contentExtent
        var needed = contentSize(floor: current, covering: [rect])
        if sheetHeight > 0 {
            needed.height = min(needed.height, max(current.height, sheetHeight))
        }
        guard needed != current else { return }
        contentExtent = needed
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
