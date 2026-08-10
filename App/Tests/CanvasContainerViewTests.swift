import UIKit
import XCTest

@testable import Bopa

/// Layout of the page canvas when the view's width changes: iPad rotation, and the Split
/// View / Stage Manager resizes that look the same to the view.
@MainActor
final class CanvasContainerViewTests: XCTestCase {

    private let portrait = CGRect(x: 0, y: 0, width: 834, height: 1210)
    private let landscape = CGRect(x: 0, y: 0, width: 1210, height: 834)

    private func fit(_ width: CGFloat) -> CGFloat {
        min(width / EditorCanvasView.pageWidth, 1)
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
        container.fitWidthOnOpen = false
        rotate(container, to: portrait)
        XCTAssertEqual(container.canvas.zoomScale, 1, accuracy: 0.001)
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
