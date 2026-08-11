import UIKit
import XCTest

@testable import Bopa

/// Layout of the page canvas when the view's width changes: iPad rotation, and the Split
/// View / Stage Manager resizes that look the same to the view.
@MainActor
final class CanvasContainerViewTests: XCTestCase {

    private let portrait = CGRect(x: 0, y: 0, width: 834, height: 1210)
    private let landscape = CGRect(x: 0, y: 0, width: 1210, height: 834)
    /// Wider than the 1404pt page — an external display under Stage Manager. Every built-in
    /// iPad screen is narrower than the page, so this is the only way to reach the fit
    /// above 1:1.
    private let wide = CGRect(x: 0, y: 0, width: 1900, height: 1000)

    /// Uncapped on purpose: "fit width" fills the screen, so a landscape iPad wider than the
    /// 1404pt page scales the page UP rather than leaving it in a band of empty desk.
    private func fit(_ width: CGFloat) -> CGFloat {
        width / EditorCanvasView.pageWidth
    }

    /// A container configured the way `EditorCanvasView.makeUIView` configures it, laid out
    /// once at `frame`.
    private func makeContainer(_ frame: CGRect = .zero) -> CanvasContainerView {
        let container = CanvasContainerView()
        container.canvas.contentSize = CGSize(
            width: EditorCanvasView.pageWidth, height: EditorCanvasView.minimumHeight)
        container.canvas.minimumZoomScale = 0.25
        container.canvas.maximumZoomScale = 3
        if frame != .zero { rotate(container, to: frame) }
        return container
    }

    /// Resizes the container and lets it lay out, as the window does on a rotation.
    private func rotate(_ container: CanvasContainerView, to frame: CGRect) {
        container.frame = frame
        container.setNeedsLayout()
        container.layoutIfNeeded()
    }

    // MARK: - Fitting the width

    func testOpensFittedToTheWidth() {
        let container = makeContainer(portrait)
        XCTAssertEqual(container.canvas.zoomScale, fit(portrait.width), accuracy: 0.001)
    }

    func testOpensAtOneToOneWhenFitWidthIsOff() {
        let container = makeContainer()
        container.keepsFitToWidth = false
        rotate(container, to: portrait)
        XCTAssertEqual(container.canvas.zoomScale, 1, accuracy: 0.001)
    }

    /// "Actual size" means the zoom is the user's business: a rotation must not quietly
    /// re-fit the page even when the old zoom happened to be the old width's fit.
    func testActualSizeKeepsItsZoomAcrossRotation() {
        let container = makeContainer(portrait)
        container.keepsFitToWidth = false
        rotate(container, to: landscape)
        XCTAssertEqual(container.canvas.zoomScale, fit(portrait.width), accuracy: 0.001)
    }

    /// The page fills a window wider than itself instead of stopping at 1:1 with desk on
    /// either side — what "fit width" means everywhere else it appears.
    func testAWindowWiderThanThePageScalesThePageUp() {
        let container = makeContainer(wide)
        XCTAssertEqual(container.canvas.zoomScale, fit(wide.width), accuracy: 0.001)
        XCTAssertGreaterThan(container.canvas.zoomScale, 1)
    }

    /// The fit is only a fit if the scroll view will actually hold it: the configured
    /// maximum (3) is below the fit for a wide enough window, and a clamped fit is not one.
    func testMaximumZoomAlwaysAllowsFittingTheCurrentWidth() {
        let container = makeContainer(CGRect(x: 0, y: 0, width: 5000, height: 1000))
        XCTAssertGreaterThanOrEqual(container.canvas.maximumZoomScale, fit(5000))
        XCTAssertEqual(container.canvas.zoomScale, fit(5000), accuracy: 0.001)
    }

    func testRotatingToLandscapeRefitsThePageToTheWiderScreen() {
        let container = makeContainer(portrait)
        rotate(container, to: landscape)
        XCTAssertEqual(container.canvas.zoomScale, fit(landscape.width), accuracy: 0.001)
    }

    func testRotatingBackToPortraitRefitsThePageToTheNarrowerScreen() {
        let container = makeContainer(landscape)
        rotate(container, to: portrait)
        XCTAssertEqual(container.canvas.zoomScale, fit(portrait.width), accuracy: 0.001)
    }

    /// The regression that made portrait unusable after a rotation: the minimum zoom was
    /// computed once, from the landscape width, so the page could not be pinched back down
    /// far enough to fit the narrower screen.
    func testMinimumZoomAlwaysAllowsFittingTheCurrentWidth() {
        let container = makeContainer(landscape)
        rotate(container, to: portrait)
        XCTAssertLessThanOrEqual(container.canvas.minimumZoomScale, fit(portrait.width))
    }

    func testZoomedInPageKeepsItsZoomAcrossRotation() {
        let container = makeContainer(portrait)
        container.canvas.zoomScale = 1.5
        container.canvasZoomDidChange()

        rotate(container, to: landscape)
        XCTAssertEqual(container.canvas.zoomScale, 1.5, accuracy: 0.001)
    }

    // MARK: - Re-fitting on demand

    /// The ••• menu's "Fit page width" after a pinch: back on the fit, and armed again, so
    /// the next rotation keeps it there rather than preserving the pinched-in zoom.
    func testFitToWidthReEngagesAfterAPinch() {
        let container = makeContainer(portrait)
        container.canvas.zoomScale = 2
        container.canvasZoomDidChange()

        container.fitToWidth()
        XCTAssertEqual(container.canvas.zoomScale, fit(portrait.width), accuracy: 0.001)

        rotate(container, to: landscape)
        XCTAssertEqual(container.canvas.zoomScale, fit(landscape.width), accuracy: 0.001)
    }

    /// The ••• menu both sets the preference and fits, and the preference reaching the canvas
    /// fits again — so being asked twice has to land in exactly the same place as being asked
    /// once, not re-anchor off the position the first fit just produced.
    func testFittingTwiceIsTheSameAsFittingOnce() {
        let container = makeContainer(portrait)
        container.canvas.zoomScale = 2
        container.canvasZoomDidChange()
        container.canvas.contentOffset.y = 1200 * 2

        container.fitToWidth()
        let zoom = container.canvas.zoomScale
        let offset = container.canvas.contentOffset.y

        container.fitToWidth()
        XCTAssertEqual(container.canvas.zoomScale, zoom, accuracy: 0.0001)
        XCTAssertEqual(container.canvas.contentOffset.y, offset, accuracy: 0.0001)
    }

    /// Fitting says where the page sits, not what mode it is in: "actual size" must not start
    /// re-fitting rotations behind the back of the setting.
    func testFitToWidthDoesNotTurnTheStickyModeOn() {
        let container = makeContainer(portrait)
        container.keepsFitToWidth = false
        container.fitToWidth()
        XCTAssertEqual(container.canvas.zoomScale, fit(portrait.width), accuracy: 0.001)

        rotate(container, to: landscape)
        XCTAssertEqual(container.canvas.zoomScale, fit(portrait.width), accuracy: 0.001)
    }

    /// Re-fitting changes the scale, not the place: you stay on the line you were writing.
    func testFitToWidthKeepsThePagePosition() {
        let container = makeContainer(portrait)
        container.canvas.zoomScale = 2
        container.canvasZoomDidChange()
        container.canvas.contentOffset.y = 1200 * 2

        container.fitToWidth()

        let pageY = container.canvas.contentOffset.y / container.canvas.zoomScale
        XCTAssertEqual(pageY, 1200, accuracy: 1)
    }

    // MARK: - Scroll position

    func testRotationKeepsThePagePosition() {
        let container = makeContainer(portrait)
        let portraitZoom = container.canvas.zoomScale
        // Halfway down a page-space offset of 1200pt.
        container.canvas.contentOffset.y = 1200 * portraitZoom
        container.layoutIfNeeded()

        rotate(container, to: landscape)

        let pageY = container.canvas.contentOffset.y / container.canvas.zoomScale
        XCTAssertEqual(pageY, 1200, accuracy: 1)
    }

    func testPersistedScrollIsAppliedOnceLaidOut() {
        let container = makeContainer()
        container.setInitialScroll(pageY: 900)
        rotate(container, to: portrait)

        let pageY = container.canvas.contentOffset.y / container.canvas.zoomScale
        XCTAssertEqual(pageY, 900, accuracy: 1)
    }

    // MARK: - Centring

    func testPageFillingTheWidthIsNotInset() {
        let container = makeContainer(portrait)
        XCTAssertEqual(container.canvas.contentInset.left, 0, accuracy: 0.5)
    }

    func testPageNarrowerThanTheViewIsCentred() {
        let container = makeContainer(portrait)
        container.canvas.zoomScale = 0.3
        container.canvasZoomDidChange()
        container.updateContentGeometry()

        let expected = (portrait.width - EditorCanvasView.pageWidth * 0.3) / 2
        XCTAssertEqual(container.canvas.contentInset.left, expected, accuracy: 1)
        XCTAssertEqual(container.canvas.contentInset.right, expected, accuracy: 1)
        XCTAssertEqual(container.canvas.contentOffset.x, -expected, accuracy: 1)
    }
}
