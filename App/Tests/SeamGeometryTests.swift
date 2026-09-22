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

    /// With one below, room for the screen to fill with the next page before the switch
    /// commits — and a second viewport past that, so a fast scroll still in motion when the
    /// switch is asked for does not reach the end of the room and bounce before the page lands.
    func testAPageWithANextPageCanBeScrolledTwoViewportsPastItsEnd() {
        XCTAssertEqual(
            SeamGeometry.scrollExtent(
                contentHeight: a4Height, sheetHeight: a4Height, viewportHeight: viewport,
                hasNextPage: true),
            a4Height + 2 * viewport)
    }

    /// The room above the page mirrors the room below it, and exists only when there is a page
    /// above to show — the first page of a notebook starts at its paper.
    func testTheRoomAboveMirrorsTheRoomBelow() {
        XCTAssertEqual(
            SeamGeometry.leadingRoom(viewportHeight: viewport, hasPreviousPage: true),
            2 * viewport)
        XCTAssertEqual(
            SeamGeometry.leadingRoom(viewportHeight: viewport, hasPreviousPage: false), 0)
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
        // A scroll that turned back while the page was on its way lands in the room above the
        // entered page — the page just left is drawn there, so that is still the same picture.
        XCTAssertEqual(
            SeamGeometry.carriedScroll(offsetY: a4Height - 50, sheetHeight: a4Height), -50)
    }

    // MARK: Backwards

    /// Scrolling up brings the page above in, and the switch to it commits once this page has
    /// left the bottom of the screen — the mirror of the forward rule, and just as independent of
    /// whether a finger is down, so a flick upwards carries on into the page above.
    func testThePreviousPageTakesOverWhenThisPageLeavesTheBottomOfTheScreen() {
        XCTAssertFalse(
            SeamGeometry.shouldEnterPreviousPage(offsetY: -viewport + 1, viewportHeight: viewport))
        XCTAssertTrue(
            SeamGeometry.shouldEnterPreviousPage(offsetY: -viewport, viewportHeight: viewport))
        XCTAssertTrue(
            SeamGeometry.shouldEnterPreviousPage(
                offsetY: -viewport - 200, viewportHeight: viewport))
    }

    /// Resting at the top of a page — where it sits the whole time it is not scrolled, including
    /// while a finger drags sideways — and an ordinary pull past it are nowhere near the rule, so
    /// nothing walks the reader backwards through the notebook on its own.
    func testRestingOrPeekingAboveTheTopIsNotACrossing() {
        XCTAssertFalse(SeamGeometry.shouldEnterPreviousPage(offsetY: 0, viewportHeight: viewport))
        XCTAssertFalse(
            SeamGeometry.shouldEnterPreviousPage(offsetY: -300, viewportHeight: viewport))
        XCTAssertFalse(SeamGeometry.shouldEnterPreviousPage(offsetY: -300, viewportHeight: 0))
    }

    /// The page above opens showing exactly what is on screen: the position measured from the
    /// top of the page being left is the same position measured from the end of the page above.
    func testTheScrollIsCarriedOntoThePageAbove() {
        XCTAssertEqual(
            SeamGeometry.scrollOnPreviousPage(
                offsetY: -viewport, previousSheetHeight: a4Height),
            a4Height - viewport)
    }

    /// The two crossings cannot fire back to back: landing on either side of a seam puts the view
    /// a whole viewport away from the crossing that would undo it.
    func testCrossingOneWayDoesNotImmediatelyCrossBack() {
        // Forward: lands at the top of the next page.
        let forward = SeamGeometry.carriedScroll(offsetY: a4Height, sheetHeight: a4Height)
        XCTAssertFalse(
            SeamGeometry.shouldEnterPreviousPage(offsetY: forward, viewportHeight: viewport))
        // Backward: lands with the page left just below the screen.
        let backward = SeamGeometry.scrollOnPreviousPage(
            offsetY: -viewport, previousSheetHeight: a4Height)
        XCTAssertFalse(SeamGeometry.shouldEnterNextPage(offsetY: backward, sheetHeight: a4Height))
    }
}

/// What a drawn layer keeps rendered while the page scrolls under it.
final class LayerBufferTests: XCTestCase {
    private let page = CGRect(x: 0, y: 0, width: 1000, height: 1400)
    private let margin = CGSize(width: 100, height: 500)

    private func screen(atY y: CGFloat) -> CGRect {
        CGRect(x: 0, y: y, width: 1000, height: 1000)
    }

    /// Scrolling within what is held changes nothing, which is the whole point: no redraw.
    func testScrollingInsideTheHeldRegionKeepsIt() {
        var buffer = LayerBuffer()
        let first = buffer.update(visible: screen(atY: 0), page: page, scale: 1, margin: margin)
        XCTAssertEqual(first, page, "a sheet that fits inside the margins is held whole")
        for y in stride(from: 0, through: 400, by: 50) {
            XCTAssertEqual(
                buffer.update(visible: screen(atY: CGFloat(y)), page: page, scale: 1, margin: margin),
                first)
        }
    }

    /// Scrolled out of what is held, the region moves to follow — never past the page.
    func testScrollingOutOfTheHeldRegionMovesIt() {
        var buffer = LayerBuffer()
        let tall = CGRect(x: 0, y: 0, width: 1000, height: 6000)
        let first = buffer.update(visible: screen(atY: 0), page: tall, scale: 1, margin: margin)
        XCTAssertEqual(first, CGRect(x: 0, y: 0, width: 1000, height: 1500))
        let moved = buffer.update(visible: screen(atY: 2000), page: tall, scale: 1, margin: margin)
        XCTAssertEqual(moved, CGRect(x: 0, y: 1500, width: 1000, height: 2000))
    }

    /// A zoom change redraws at the new scale, whatever was held.
    func testAZoomChangeRedraws() {
        var buffer = LayerBuffer()
        _ = buffer.update(visible: screen(atY: 0), page: page, scale: 1, margin: margin)
        let zoomed = CGRect(x: 0, y: 0, width: 2000, height: 2800)
        XCTAssertEqual(
            buffer.update(visible: screen(atY: 0), page: zoomed, scale: 2, margin: margin),
            CGRect(x: 0, y: 0, width: 1100, height: 1500))
    }

    /// Off screen, what is held is kept, so scrolling back costs nothing.
    func testOffScreenKeepsWhatIsHeld() {
        var buffer = LayerBuffer()
        let held = buffer.update(visible: screen(atY: 0), page: page, scale: 1, margin: margin)
        XCTAssertEqual(
            buffer.update(visible: screen(atY: 5000), page: page, scale: 1, margin: margin), held)
        var fresh = LayerBuffer()
        XCTAssertNil(
            fresh.update(visible: screen(atY: 5000), page: page, scale: 1, margin: margin),
            "a page never on screen holds nothing")
    }
}
