import CoreGraphics

/// Where one page ends and the next begins, when the notebook scrolls as one surface.
///
/// Continuous scrolling shows the neighbouring pages around the current one — the next page
/// below a seam at the sheet's foot, the previous page above the sheet's top — and lets the
/// scroll run on into either. The switch to a neighbour happens once the current page has left
/// the screen entirely, at which point both pages draw the same picture and the swap costs no
/// visible movement.
///
/// The two directions are the same rule mirrored. They used not to be: forward had a viewport of
/// the next page to scroll into, while backward was a rubber-band pull past the top that only
/// counted while the finger was down — so a flick upwards bounced off the top of the page every
/// time, and getting back to the page before took several deliberate drags.
///
/// Pure geometry, in unzoomed page units, so the rules can be pinned by tests rather than by
/// driving a scroll view. The Android app's `PageViewportBounds` holds the forward half.
enum SeamGeometry {
    /// How much room past a seam there is to scroll into, in viewports.
    ///
    /// More than one on purpose. The crossing commits at one viewport (the moment the current
    /// page has fully left the screen), and the page it asks for arrives a frame or so later. If
    /// the room ended exactly at the crossing, a fast scroll would hit the end of it in that
    /// window and the scroll view would start bouncing — a visible stall in the middle of a flick.
    /// The second viewport is the runway that lets momentum carry straight through.
    static let roomInViewports: CGFloat = 2

    /// How tall the scrollable area is.
    ///
    /// Normally the page itself. With a next page below the seam it is the page plus the room
    /// past it, so the whole screen can fill with the next page before the switch commits —
    /// scrolling to `sheetHeight` exactly is the moment the seam reaches the top of the screen.
    /// Never shorter than the content already there: a page holding legacy ink below its sheet
    /// keeps the reach that makes it visible.
    static func scrollExtent(
        contentHeight: CGFloat, sheetHeight: CGFloat, viewportHeight: CGFloat,
        hasNextPage: Bool
    ) -> CGFloat {
        guard hasNextPage, sheetHeight > 0 else { return contentHeight }
        return max(contentHeight, sheetHeight + roomInViewports * max(viewportHeight, 0))
    }

    /// How far above the top of the page the view may scroll, to show the page before it.
    ///
    /// The mirror of the room `scrollExtent` adds below. Nothing without a previous page: the
    /// first page of a notebook still starts at its paper.
    static func leadingRoom(viewportHeight: CGFloat, hasPreviousPage: Bool) -> CGFloat {
        hasPreviousPage ? roomInViewports * max(viewportHeight, 0) : 0
    }

    /// Whether the view has scrolled far enough that the current page has left the screen
    /// entirely and the next page should take over.
    ///
    /// `>=`, and measured against the sheet rather than the content: the seam is drawn at the
    /// sheet's edge, so that is the offset at which the next page's y=0 sits at the top of the
    /// screen — the position where the swap moves nothing.
    static func shouldEnterNextPage(offsetY: CGFloat, sheetHeight: CGFloat) -> Bool {
        sheetHeight > 0 && offsetY >= sheetHeight
    }

    /// The scroll position the next page opens at, so the pixels on screen do not move: what
    /// was scroll past this page's end is ordinary scroll on the next one.
    static func carriedScroll(offsetY: CGFloat, sheetHeight: CGFloat) -> CGFloat {
        offsetY - sheetHeight
    }

    /// Whether the view has scrolled far enough up that the current page has left the bottom of
    /// the screen and the previous page — which is all that is showing — should take over.
    ///
    /// Read the same way whether a finger is dragging or momentum is carrying the scroll: this
    /// is scrolling through one long document, not a gesture, so a flick upwards runs on into
    /// the page before exactly as a flick downwards runs on into the page after.
    ///
    /// No resting position can satisfy it — the page top has to sit a whole viewport below the
    /// top of the screen — so a sideways pan at the top of a page, or merely being there, never
    /// walks the reader backwards.
    static func shouldEnterPreviousPage(offsetY: CGFloat, viewportHeight: CGFloat) -> Bool {
        viewportHeight > 0 && offsetY <= -viewportHeight
    }

    /// The scroll position the previous page opens at: the same picture, measured from the top
    /// of that page instead of this one.
    static func scrollOnPreviousPage(offsetY: CGFloat, previousSheetHeight: CGFloat) -> CGFloat {
        offsetY + previousSheetHeight
    }
}

/// The part of a page a drawn layer keeps rendered, so scrolling moves the layer instead of
/// redrawing it.
///
/// The paper and the text boxes are drawn with Core Graphics into a bitmap the size of whatever
/// region they cover. They used to cover exactly the screen and redraw on every scroll tick — a
/// full-screen CPU redraw per layer per frame, which is most of what made scrolling stutter on
/// its own, seam or no seam. Holding a region somewhat larger than the screen, anchored to the
/// page, turns almost every tick into a change of position: the layer is redrawn only when the
/// view scrolls out of what it holds, or the zoom changes. At the width fit a whole sheet fits
/// inside the margins, so it is drawn once and never again until the zoom moves.
///
/// Rectangles are in the page's own zoomed coordinates — page units times the zoom, origin at
/// the page's top-left.
struct LayerBuffer: Equatable {
    private(set) var region: CGRect?
    private var scale: CGFloat = 0

    /// Updates the held region for the view now showing `visible`, and returns it.
    ///
    /// - Returns: the region the layer should cover — unchanged whenever it still covers what is
    ///   on screen — or nil when the page has never been on screen at this zoom.
    mutating func update(
        visible: CGRect, page: CGRect, scale: CGFloat, margin: CGSize
    ) -> CGRect? {
        let needed = visible.intersection(page)
        if scale != self.scale {
            self.scale = scale
            region = nil
        }
        // Off screen: keep what is drawn, so scrolling back costs nothing.
        guard !needed.isNull, !needed.isEmpty else { return region }
        if let region, region.contains(needed), page.contains(region) { return region }
        let grown = visible.insetBy(dx: -margin.width, dy: -margin.height).intersection(page)
        region = grown.isNull || grown.isEmpty ? nil : grown
        return region
    }

    mutating func invalidate() { region = nil }
}
