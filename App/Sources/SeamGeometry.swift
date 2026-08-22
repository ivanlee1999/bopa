import CoreGraphics

/// Where one page ends and the next begins, when the notebook scrolls as one surface.
///
/// Continuous scrolling shows the next page below the current one, under a seam line, and lets
/// the scroll run on into it — so the notebook reads as one long document even though the canvas
/// only ever holds one page's ink. The switch to that page happens when the seam has left the
/// top of the screen, at which point both pages draw the same picture and the swap costs no
/// visible movement.
///
/// Pure geometry, in unzoomed page units, so the rules can be pinned by tests rather than by
/// driving a scroll view. The Android app's `PageViewportBounds` holds the same three answers.
enum SeamGeometry {
    /// How tall the scrollable area is.
    ///
    /// Normally the page itself. With a next page below the seam it is the page *plus* a
    /// viewport, so the whole screen can fill with the next page before the switch commits —
    /// scrolling to `sheetHeight` exactly is the moment the seam reaches the top of the screen.
    /// Never shorter than the content already there: a page holding legacy ink below its sheet
    /// keeps the reach that makes it visible.
    static func scrollExtent(
        contentHeight: CGFloat, sheetHeight: CGFloat, viewportHeight: CGFloat,
        hasNextPage: Bool
    ) -> CGFloat {
        guard hasNextPage, sheetHeight > 0 else { return contentHeight }
        return max(contentHeight, sheetHeight + max(viewportHeight, 0))
    }

    /// Whether the view has scrolled far enough that the current page has left the screen
    /// entirely and the next page should take over.
    ///
    /// `>=`, and measured against the sheet rather than the content: the seam is drawn at the
    /// sheet's edge, so that is the offset at which the next page's y=0 sits at the top of the
    /// screen — the one position where the swap moves nothing.
    static func shouldEnterNextPage(offsetY: CGFloat, sheetHeight: CGFloat) -> Bool {
        sheetHeight > 0 && offsetY >= sheetHeight
    }

    /// The scroll position the next page opens at, so the pixels on screen do not move: what
    /// was overshoot past this page's end is ordinary scroll on the next one.
    static func carriedScroll(offsetY: CGFloat, sheetHeight: CGFloat) -> CGFloat {
        max(offsetY - sheetHeight, 0)
    }

    /// Whether the view has been pulled far enough above the top of the page to bring the
    /// previous page in above it, rather than rubber-banding against nothing.
    ///
    /// The previous page is entered *at its own end* — the scroll is preset past its sheet, and
    /// the ordinary clamp lands it exactly on `sheetHeight`, which is the position that draws
    /// this page under its seam. So the page the reader was on stays exactly where it was on
    /// screen, and only what is above it is new.
    ///
    /// [threshold] is what makes it a deliberate pull rather than a resting position. Merely
    /// being *at* the top satisfies `offsetY == -leadingInset` — which is where a page sits the
    /// whole time it is not scrolled — so without it a sideways pan, or any drag at all at the
    /// top of a page, walked the reader backwards through the notebook.
    static func shouldEnterPreviousPage(
        offsetY: CGFloat, leadingInset: CGFloat, threshold: CGFloat
    ) -> Bool {
        offsetY < -leadingInset - threshold
    }
}
