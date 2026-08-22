import XCTest

@testable import Bopa

/// The rules that make continuous scrolling continuous: how far past a page you may scroll,
/// where the next page takes over, and what it opens at.
///
/// The Android app answers the same three questions in `PageViewportBounds`; the values have to
/// agree or the same notebook reads differently on the two devices.
final class SeamGeometryTests: XCTestCase {
    private let a4Height: CGFloat = 1980
    private let viewport: CGFloat = 1400

    // MARK: Extent

    /// Without a page below, the page ends at its paper — the last page of a notebook must not
    /// offer a screenful of nothing to scroll into.
    func testAPageWithNothingBelowItEndsAtItsOwnContent() {
        XCTAssertEqual(
            SeamGeometry.scrollExtent(
                contentHeight: a4Height, sheetHeight: a4Height, viewportHeight: viewport,
                hasNextPage: false),
            a4Height)
    }

    /// With one below, a whole viewport of room — enough for the screen to fill with the next
    /// page before the switch commits.
    func testAPageWithANextPageCanBeScrolledAViewportPastItsEnd() {
        XCTAssertEqual(
            SeamGeometry.scrollExtent(
                contentHeight: a4Height, sheetHeight: a4Height, viewportHeight: viewport,
                hasNextPage: true),
            a4Height + viewport)
    }

    /// A page holding legacy ink below its sheet keeps every bit of the reach that shows it.
    func testLegacyOverflowKeepsItsReach() {
        let tall = a4Height * 3
        XCTAssertEqual(
            SeamGeometry.scrollExtent(
                contentHeight: tall, sheetHeight: a4Height, viewportHeight: viewport,
                hasNextPage: false),
            tall)
        XCTAssertEqual(
            SeamGeometry.scrollExtent(
                contentHeight: tall, sheetHeight: a4Height, viewportHeight: viewport,
                hasNextPage: true),
            tall)
    }

    /// A page with no sheet to end at has no seam either.
    func testNoSheetMeansNoSeamRoom() {
        XCTAssertEqual(
            SeamGeometry.scrollExtent(
                contentHeight: 900, sheetHeight: 0, viewportHeight: viewport, hasNextPage: true),
            900)
    }

    // MARK: The crossing

    /// The switch happens exactly where the seam reaches the top of the screen — the one
    /// position at which both pages draw the same picture, so nothing moves.
    func testTheNextPageTakesOverWhenTheSeamReachesTheTopOfTheScreen() {
        XCTAssertFalse(
            SeamGeometry.shouldEnterNextPage(offsetY: a4Height - 1, sheetHeight: a4Height))
        XCTAssertTrue(
            SeamGeometry.shouldEnterNextPage(offsetY: a4Height, sheetHeight: a4Height))
        XCTAssertTrue(
            SeamGeometry.shouldEnterNextPage(offsetY: a4Height + 200, sheetHeight: a4Height))
    }

    func testAPageWithNoSheetNeverCrosses() {
        XCTAssertFalse(SeamGeometry.shouldEnterNextPage(offsetY: 5000, sheetHeight: 0))
    }

    /// Overshoot past this page's end becomes ordinary scroll on the next one, so the picture
    /// on screen is identical either side of the swap.
    func testTheOvershootIsCarriedOntoTheEnteredPage() {
        XCTAssertEqual(
            SeamGeometry.carriedScroll(offsetY: a4Height + 320, sheetHeight: a4Height), 320)
        // Exactly at the seam: the next page opens at its very top.
        XCTAssertEqual(
            SeamGeometry.carriedScroll(offsetY: a4Height, sheetHeight: a4Height), 0)
        // Never negative, however the scroll was clamped on the way in.
        XCTAssertEqual(
            SeamGeometry.carriedScroll(offsetY: a4Height - 50, sheetHeight: a4Height), 0)
    }

    // MARK: Backwards

    /// Scrolling up past the top brings the previous page in. Measured against the inset, not
    /// zero: a page narrower than the viewport is centred and rests at a negative offset, which
    /// read against zero looks like a permanent pull backwards.
    func testScrollingAboveTheTopEntersThePreviousPage() {
        let threshold: CGFloat = 48
        func pulled(_ offsetY: CGFloat, inset: CGFloat = 0) -> Bool {
            SeamGeometry.shouldEnterPreviousPage(
                offsetY: offsetY, leadingInset: inset, threshold: threshold)
        }
        XCTAssertTrue(pulled(-60))
        XCTAssertFalse(pulled(-10), "a short pull is not a request for the previous page")
        XCTAssertFalse(pulled(1))
    }

    /// Sitting at the top is where a page rests the entire time it is not scrolled — including
    /// while the finger is dragging sideways. Without a threshold that resting position read as
    /// a backward pull, and any drag at the top walked the reader back through the notebook.
    func testRestingAtTheTopIsNotAPullBackwards() {
        func pulled(_ offsetY: CGFloat, inset: CGFloat) -> Bool {
            SeamGeometry.shouldEnterPreviousPage(
                offsetY: offsetY, leadingInset: inset, threshold: 48)
        }
        XCTAssertFalse(pulled(0, inset: 0), "the top of an uninset page is a resting position")
        // A page narrower than the viewport is centred and rests at -inset, not at 0.
        XCTAssertFalse(pulled(-40, inset: 40), "the centred resting position is not a pull")
        XCTAssertFalse(pulled(-80, inset: 40), "still inside the threshold")
        XCTAssertTrue(pulled(-100, inset: 40), "a real pull past the top, inset and all")
    }
}
