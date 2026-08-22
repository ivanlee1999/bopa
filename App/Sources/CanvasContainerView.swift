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
    ///
    /// Not private so a test can hold the drawn paper against the space the ink is stored in:
    /// they are the same rectangle or the pen does not land where it points.
    let pageSheet = UIView()
    private let paperView = PaperTemplateView()
    private let backgroundImageView = UIImageView()
    private var imageViews: [UIImageView] = []
    private var pendingScrollY: CGFloat?
    /// The next page, drawn below the seam: its paper, its background, and a picture of its
    /// ink. See [NextPagePreview] for why it is a picture and not a second canvas.
    private let nextPageSheet = UIView()
    private let nextPagePaperView = PaperTemplateView()
    private let nextPageBackgroundView = UIImageView()
    private let nextPageContentView = UIImageView()
    /// The line the next page starts at — drawn so the boundary is legible while scrolling
    /// through it, the way a page change is a thin rule in Notability rather than a gap.
    private let seamLine = UIView()
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
        didSet {
            paperView.sheetHeight = sheetHeight
            // A declared sheet is already a page. Export-break marks belong to old continuous
            // canvases; drawing one at the bottom of a real page makes it look like that page has
            // another hidden page inside it.
            paperView.showsSheetBoundaries = false
            guard sheetHeight != oldValue, laidOutWidth > 0 else { return }
            let fit = fitWidthZoom
            allowZoom(fit)
            if keepsFitToWidth, isFitToWidth {
                canvas.zoomScale = fit
                isFitToWidth = true
            }
            updateContentGeometry()
        }
    }
    /// Slack kept to the right of ink that overflows the sheet, so the last stroke is not flush
    /// against the edge of the scrollable area. Small on purpose: unlike the downward slack,
    /// which is room to keep writing, this only has to make the overflow legible.
    private static let horizontalInkSlack: CGFloat = 100
    /// Room after content that already lies below the sheet, so old overflow stays reachable.
    /// In-bounds ink gets no slack: the sheet itself already covers it.
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

        // Below the seam, in the same order as the current page's own layers. Installed once
        // and hidden until there is a next page to show; all four are inert to touch, so a
        // stroke started over them still lands on the canvas above (and belongs to this page —
        // ink is filed against the page the canvas holds, not against what is drawn under it).
        nextPageSheet.backgroundColor = .white
        nextPageSheet.isUserInteractionEnabled = false
        addSubview(nextPageSheet)
        nextPageBackgroundView.contentMode = .scaleAspectFit
        nextPageBackgroundView.isUserInteractionEnabled = false
        addSubview(nextPageBackgroundView)
        addSubview(nextPagePaperView)
        nextPageContentView.contentMode = .scaleToFill
        nextPageContentView.isUserInteractionEnabled = false
        addSubview(nextPageContentView)
        seamLine.backgroundColor = UIColor(hex: 0x7D7979)
        seamLine.isUserInteractionEnabled = false
        addSubview(seamLine)
        setSeamHidden(true)

        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        // Both axes bounce even when there is nothing to scroll on them. A page turn is read
        // from how far a released drag pulled *past* the end, and without the bounce there is no
        // past-the-end to pull into: a sheet that fits the screen — every page under the
        // whole-page fit that "Side to side" opens with — simply refused to be pulled, so the
        // gesture that asks for the next page could not be made at all. The overshoot threshold
        // is what keeps an ordinary scroll from turning a page, not the absence of slack.
        canvas.alwaysBounceVertical = true
        canvas.alwaysBounceHorizontal = true
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
        // The seam's room is one viewport measured in page units, so it moves with both the
        // view's height and the zoom. Sizing it only when the seam's own inputs changed left it
        // frozen at whatever the viewport was when the page opened: after a rotation or a pinch
        // the scroll could no longer reach the sheet's edge, and the crossing became impossible.
        applySeamExtent()
        updateContentGeometry()
    }

    /// The zoom at which the page exactly fills the view's width. Uncapped in both
    /// directions: a landscape iPad is wider than the 1404pt page, and "fit width" there
    /// means filling the screen rather than leaving the page marooned in empty desk.
    static func fitZoom(viewWidth: CGFloat, pageWidth: CGFloat) -> CGFloat {
        guard viewWidth > 0, pageWidth > 0 else { return 1 }
        return viewWidth / pageWidth
    }

    /// Pagination shows one complete sheet; continuous scrolling uses the width fit so the sheet
    /// fills the writing surface and its lower part scrolls on into the next real page.
    var fitsWholePage = false {
        didSet {
            guard fitsWholePage != oldValue else { return }
            applySeamExtent()
        }
    }

    /// Whether a page exists below this one — known the moment the page opens, unlike the
    /// *picture* of it, which is rendered off the main actor and arrives later.
    ///
    /// The scrollable area has to be sized from this and not from the picture. Keying it on the
    /// picture meant that during every render window the canvas believed it was on the last page
    /// and shrank the extent back to one sheet — which, on the page-load that follows a backward
    /// crossing, clamped the "open at its end" scroll a whole viewport short and jumped the view
    /// by a screenful, in the one place the design promises nothing moves.
    var hasNextPage = false {
        didSet {
            guard hasNextPage != oldValue else { return }
            applySeamExtent()
            updateContentGeometry()
        }
    }

    /// The picture drawn below the seam, or nil while it is still being rendered (and for
    /// pagination, where there is no seam to look through). Controls only what is *drawn*:
    /// until it arrives the seam shows the next page's blank paper.
    var nextPage: NextPagePreview? {
        didSet {
            guard nextPage != oldValue else { return }
            nextPagePaperView.template = nextPage?.template ?? .blank
            nextPagePaperView.pageWidth = CGFloat(
                nextPage?.pageSize.width ?? PageSize.legacyUndeclared.width)
            nextPagePaperView.sheetHeight = CGFloat(nextPage?.pageSize.height ?? 0)
            nextPageContentView.image = nextPage?.content
            nextPageBackgroundView.image = nextPage?.background
            applySeamExtent()
            updateContentGeometry()
        }
    }

    /// Whether the seam is live: continuous scrolling, a declared sheet to end at, and a page
    /// below it to scroll into. Deliberately not conditioned on the picture having rendered.
    var seamActive: Bool { !fitsWholePage && sheetHeight > 0 && hasNextPage }

    private func setSeamHidden(_ hidden: Bool) {
        nextPageSheet.isHidden = hidden
        nextPageBackgroundView.isHidden = hidden || nextPage?.background == nil
        nextPagePaperView.isHidden = hidden
        nextPageContentView.isHidden = hidden || nextPage?.content == nil
        seamLine.isHidden = hidden
    }

    /// Gives the scroll a viewport of room past the sheet when there is a page below it, so the
    /// screen can fill with the next page before the switch commits — and takes it away again
    /// when there is not, so the last page of a notebook still ends at its paper.
    private func applySeamExtent() {
        guard bounds.height > 0, sheetHeight > 0 else { return }
        let current = contentExtent
        let viewportInPage = bounds.height / max(canvas.zoomScale, 0.01)
        let wanted = SeamGeometry.scrollExtent(
            contentHeight: seamActive ? sheetHeight : contentFloorHeight,
            sheetHeight: sheetHeight,
            viewportHeight: viewportInPage,
            hasNextPage: seamActive)
        guard abs(wanted - current.height) > 0.5 else { return }
        contentExtent = CGSize(width: current.width, height: wanted)
    }

    /// How tall the page is without any seam overshoot: its sheet, or as far as content that
    /// already lies past it reaches.
    private var contentFloorHeight: CGFloat {
        var height = sheetHeight
        for rect in [inkBounds, imageBounds, backgroundBounds] where Self.isReachable(rect) {
            if rect.maxY > height { height = rect.maxY + Self.verticalInkSlack }
        }
        return height
    }

    /// The ink the canvas is holding, as of the last extent computation — needed to size the
    /// page back down when the seam goes away without losing reach to legacy overflow.
    private var inkBounds: CGRect = .null

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
        applySeamExtent()
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
            // Above the page background, below the ink — and below the seam: an image dropped
            // past this page's sheet must not paint over the page drawn beneath it.
            insertSubview(view, belowSubview: nextPageSheet)
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
            // Slack starts after overflow; it is not added to ordinary ink already covered by the
            // sheet. The old unconditional vertical +1000 is what reopened a normal page as a
            // page-and-a-half whenever handwriting reached near its bottom.
            if rect.maxX > size.width {
                size.width = rect.maxX + Self.horizontalInkSlack
            }
            if rect.maxY > size.height {
                size.height = rect.maxY + Self.verticalInkSlack
            }
        }
        return size
    }

    /// Sizes the scrollable area to a page. Authoritative: pages in a notebook can declare
    /// different sheets, so opening one resets the extent rather than growing into it — which is
    /// why the images and the background have to be part of the rule and not grown in afterwards.
    func setContentExtent(pageSize: PageSize, ink: CGRect, minimumHeight: CGFloat) {
        inkBounds = ink
        contentExtent = contentSize(
            floor: CGSize(width: CGFloat(pageSize.width), height: minimumHeight),
            covering: [ink, imageBounds, backgroundBounds])
        // After the page's own extent, never instead of it: the seam's room is added on top of
        // whatever this page needs, and removed again the moment there is no page below.
        applySeamExtent()
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
        if Self.isReachable(rect), rect.maxY > inkBounds.maxY || inkBounds.isNull {
            inkBounds = inkBounds.isNull ? rect : inkBounds.union(rect)
        }
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
        let paperHeight = sheetHeight > 0
            ? sheetHeight * scale
            : max(canvas.contentSize.height, bounds.height * 2)
        pageSheet.frame = CGRect(
            x: -offset.x,
            y: -offset.y,
            width: pageWidth * scale,
            height: paperHeight)
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
        layoutSeam(scale: scale, offset: offset)
    }

    /// Places the next page directly below this one's sheet, in the same coordinate space
    /// everything else here uses: page units scaled by the zoom, translated by the scroll.
    ///
    /// Its own width, not this page's — a notebook may mix sheet sizes, and drawing an A5 page
    /// stretched to an A4's width would be a lie about what you are scrolling into.
    private func layoutSeam(scale: CGFloat, offset: CGPoint) {
        guard seamActive, let nextPage else {
            setSeamHidden(true)
            return
        }
        let seamY = sheetHeight * scale - offset.y
        // Nothing of it on screen yet: keep the views hidden rather than laying out every tick.
        guard seamY < bounds.height else {
            setSeamHidden(true)
            return
        }
        setSeamHidden(false)
        let width = CGFloat(nextPage.pageSize.width) * scale
        let height = CGFloat(nextPage.pageSize.height) * scale
        nextPageSheet.frame = CGRect(x: -offset.x, y: seamY, width: width, height: height)
        seamLine.frame = CGRect(x: -offset.x, y: seamY, width: width, height: 1)
        if let background = nextPage.background {
            let backgroundHeight = width * background.size.height / background.size.width
            nextPageBackgroundView.frame = CGRect(
                x: -offset.x, y: seamY, width: width, height: backgroundHeight)
        }
        // The paper draws in the next page's coordinates, so its viewport is this scroll
        // measured from the seam rather than from the top of the current page.
        nextPagePaperView.frame = CGRect(
            x: 0, y: seamY, width: bounds.width, height: max(bounds.height - seamY, 0))
        nextPagePaperView.setGeometry(
            zoomScale: scale, contentOffset: CGPoint(x: offset.x, y: 0))
        if nextPage.content != nil {
            nextPageContentView.frame = CGRect(
                x: -offset.x, y: seamY, width: width,
                height: nextPage.contentHeight * scale)
        }
    }
}
