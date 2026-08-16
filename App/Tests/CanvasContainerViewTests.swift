import NotableKit
import UIKit
import XCTest

@testable import Bopa

/// Layout of the page canvas when the view's width changes: iPad rotation, and the Split
/// View / Stage Manager resizes that look the same to the view.
@MainActor
final class CanvasContainerViewTests: XCTestCase {

    private let portrait = CGRect(x: 0, y: 0, width: 834, height: 1210)
    /// Ink reaching well past the sheet — the shape of a page written when writing made the page
    /// taller, and the only shape that still scrolls once a page is one sheet.
    private let deepInk = CGRect(x: 0, y: 0, width: 1000, height: 3000)
    private let landscape = CGRect(x: 0, y: 0, width: 1210, height: 834)
    /// Wider than the 1404pt page — an external display under Stage Manager. Every built-in
    /// iPad screen is narrower than the page, so this is the only way to reach the fit
    /// above 1:1.
    private let wide = CGRect(x: 0, y: 0, width: 1900, height: 1000)

    /// Uncapped on purpose: "fit width" fills the screen, so a landscape iPad wider than the
    /// 1404pt page scales the page UP rather than leaving it in a band of empty desk.
    private func fit(_ width: CGFloat, pageSize: PageSize = .legacyUndeclared) -> CGFloat {
        width / CGFloat(pageSize.width)
    }

    /// A container configured the way `EditorCanvasView.makeUIView` configures it, laid out
    /// once at `frame`.
    private func makeContainer(
        _ frame: CGRect = .zero,
        pageSize: PageSize = .legacyUndeclared,
        ink: CGRect = .null
    ) -> CanvasContainerView {
        let container = CanvasContainerView()
        container.pageWidth = CGFloat(pageSize.width)
        container.setContentExtent(
            pageSize: pageSize, ink: ink,
            minimumHeight: EditorCanvasView.minimumHeight(for: pageSize))
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
        // Ink below the sheet, so there is something to scroll: fitted to width, a bare sheet is
        // shorter than the screen and the only position it has is the top.
        let container = makeContainer(portrait, ink: deepInk)
        container.canvas.zoomScale = 2
        container.canvasZoomDidChange()
        container.canvas.contentOffset.y = 1200 * 2

        container.fitToWidth()

        let pageY = container.canvas.contentOffset.y / container.canvas.zoomScale
        XCTAssertEqual(pageY, 1200, accuracy: 1)
    }

    // MARK: - Scroll position

    func testRotationKeepsThePagePosition() {
        let container = makeContainer(portrait, ink: deepInk)
        let portraitZoom = container.canvas.zoomScale
        // Halfway down a page-space offset of 1200pt.
        container.canvas.contentOffset.y = 1200 * portraitZoom
        container.layoutIfNeeded()

        rotate(container, to: landscape)

        let pageY = container.canvas.contentOffset.y / container.canvas.zoomScale
        XCTAssertEqual(pageY, 1200, accuracy: 1)
    }

    func testPersistedScrollIsAppliedOnceLaidOut() {
        let container = makeContainer(ink: deepInk)
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

        let expected =
            (portrait.width - CGFloat(PageSize.legacyUndeclared.width) * 0.3) / 2
        XCTAssertEqual(container.canvas.contentInset.left, expected, accuracy: 1)
        XCTAssertEqual(container.canvas.contentInset.right, expected, accuracy: 1)
        XCTAssertEqual(container.canvas.contentOffset.x, -expected, accuracy: 1)
    }

    /// The page layer is positioned from the scroll offset, so scrolling down lifts the sheet
    /// above the top of the viewport and zooming in pushes it past every edge. Those views are
    /// plain siblings of the canvas (which clips itself), so unclipped they painted white over
    /// the chrome around the canvas: scroll a page or pinch it and the top bar and the tool rail
    /// disappeared behind the paper.
    func testScrolledPageDoesNotPaintOverTheChrome() {
        let container = makeContainer(portrait)
        container.canvas.contentOffset.y = 600
        container.updateContentGeometry()

        XCTAssertTrue(
            container.subviews.contains { !container.bounds.contains($0.frame) },
            "the page layer should extend past the viewport here, or this pins nothing")
        XCTAssertTrue(container.clipsToBounds)
    }

    // MARK: - Reaching the ink

    /// The bug this was written for: ink written near the right edge of a BOOX whose screen is
    /// wider than the page's sheet had nothing to scroll to on the iPad, so it was invisible —
    /// not merely off-page. The scrollable area has to cover the ink wherever it landed.
    func testInkPastTheSheetIsReachable() {
        let sheet = PageSizePreset.a4.size
        let ink = CGRect(x: 1700, y: 100, width: 150, height: 40)
        let container = makeContainer(portrait, pageSize: sheet, ink: ink)

        XCTAssertGreaterThanOrEqual(container.contentExtent.width, ink.maxX)
    }

    /// …and the paper does not stretch to meet it: the sheet stays the sheet, so overflowing
    /// ink reads as overflowing rather than silently redefining the page.
    func testInkPastTheSheetDoesNotWidenThePaper() {
        let sheet = PageSizePreset.a4.size
        let container = makeContainer(
            portrait, pageSize: sheet, ink: CGRect(x: 1700, y: 100, width: 150, height: 40))

        XCTAssertEqual(container.pageWidth, CGFloat(sheet.width))
        XCTAssertEqual(
            container.canvas.zoomScale, fit(portrait.width, pageSize: sheet), accuracy: 0.001)
    }

    /// A page whose ink stays on the sheet is not made horizontally scrollable for nothing.
    func testInkInsideTheSheetLeavesNoHorizontalSlack() {
        let sheet = PageSizePreset.a4.size
        let container = makeContainer(
            portrait, pageSize: sheet, ink: CGRect(x: 10, y: 10, width: 100, height: 100))

        XCTAssertEqual(container.contentExtent.width, CGFloat(sheet.width), accuracy: 1)
    }

    /// Writing off the right edge grows the area under the pen, not only on load.
    func testGrowingCoversInkAddedBeyondTheSheet() {
        let sheet = PageSizePreset.a4.size
        let container = makeContainer(portrait, pageSize: sheet)
        XCTAssertEqual(container.contentExtent.width, CGFloat(sheet.width), accuracy: 1)

        container.growContent(toCover: CGRect(x: 1500, y: 0, width: 400, height: 50))
        XCTAssertGreaterThanOrEqual(container.contentExtent.width, 1900)
    }

    /// An empty drawing's bounds are null, with infinite maxX/maxY. Letting those through breaks
    /// the scroll view's gesture system and permanently disables inking.
    func testNullInkBoundsDoNotCorruptTheExtent() {
        let sheet = PageSizePreset.a4.size
        let container = makeContainer(portrait, pageSize: sheet, ink: .null)

        XCTAssertEqual(container.contentExtent.width, CGFloat(sheet.width), accuracy: 1)
        XCTAssertEqual(
            container.contentExtent.height,
            EditorCanvasView.minimumHeight(for: sheet), accuracy: 1)

        container.growContent(toCover: .null)
        XCTAssertEqual(container.contentExtent.width, CGFloat(sheet.width), accuracy: 1)
    }

    // MARK: - Images inside the scrollable area

    private func swatch() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
    }

    /// An image dropped well below the sheet has to be scrollable to. Installing the view without
    /// growing the extent did not park it off-page — it made it unreachable, since there was
    /// nothing to scroll to and no zoom that brought it back.
    func testImageBelowTheSheetIsReachable() {
        let sheet = PageSizePreset.a4.size
        let container = makeContainer(portrait, pageSize: sheet)
        let farDown = CGFloat(sheet.height) * 3

        container.setImages([
            PageImage(
                image: swatch(),
                frame: CGRect(x: 40, y: farDown, width: 300, height: 200))
        ])

        XCTAssertGreaterThanOrEqual(container.contentExtent.height, farDown + 200)
    }

    /// The same in the other direction: an image past the right edge of the sheet.
    func testImageBeyondTheRightEdgeIsReachable() {
        let sheet = PageSizePreset.a4.size
        let container = makeContainer(portrait, pageSize: sheet)
        let farRight = CGFloat(sheet.width) + 800

        container.setImages([
            PageImage(
                image: swatch(),
                frame: CGRect(x: farRight, y: 20, width: 300, height: 200))
        ])

        XCTAssertGreaterThanOrEqual(container.contentExtent.width, farRight + 300)
    }

    /// Opening a page resets the extent from that page's sheet, so the images have to be part of
    /// the rule rather than grown in beforehand — otherwise a page switch would drop them back out
    /// of reach. `updateUIView` installs images before it sets the extent, which is this order.
    func testSettingTheExtentAfterImagesStillCoversThem() {
        let sheet = PageSizePreset.a4.size
        let container = makeContainer(portrait, pageSize: sheet)
        let farDown = CGFloat(sheet.height) * 3
        container.setImages([
            PageImage(
                image: swatch(),
                frame: CGRect(x: 0, y: farDown, width: 300, height: 200))
        ])

        container.setContentExtent(
            pageSize: sheet, ink: .null,
            minimumHeight: EditorCanvasView.minimumHeight(for: sheet))

        XCTAssertGreaterThanOrEqual(container.contentExtent.height, farDown + 200)
    }

    /// Removing the images lets the area come back down on the next page load; it must not stay
    /// stretched to whatever the last page happened to hold.
    func testExtentDropsBackWhenTheImagesGo() {
        let sheet = PageSizePreset.a4.size
        let container = makeContainer(portrait, pageSize: sheet)
        container.setImages([
            PageImage(
                image: swatch(),
                frame: CGRect(x: 0, y: CGFloat(sheet.height) * 3, width: 300, height: 200))
        ])

        container.setImages([])
        container.setContentExtent(
            pageSize: sheet, ink: .null,
            minimumHeight: EditorCanvasView.minimumHeight(for: sheet))

        XCTAssertEqual(
            container.contentExtent.height,
            EditorCanvasView.minimumHeight(for: sheet), accuracy: 1)
    }

    // MARK: - Declared page sizes

    /// Fit-to-width fits whatever sheet the page declares, so the same page fills the screen
    /// on both devices instead of each app deciding for itself how wide a page is.
    func testFitUsesTheDeclaredSheetWidth() {
        for preset in PageSizePreset.all {
            let container = makeContainer(portrait, pageSize: preset.size)
            XCTAssertEqual(
                container.canvas.zoomScale, portrait.width / CGFloat(preset.size.width),
                accuracy: 0.001, "\(preset.name)")
        }
    }

    /// Opening a page gives it exactly its sheet — measured in the sheet the page declares, not a
    /// constant left over from another page size.
    ///
    /// It used to open at two sheets, which is why there was always a second screenful of blank
    /// paper below the one being written on. It read as another page and was not one: the overview
    /// drew a single thumbnail for the pair, because it was all one page.
    func testAPageOpensExactlyOneSheetTall() {
        let container = makeContainer(portrait, pageSize: PageSizePreset.a3.size)
        XCTAssertEqual(
            container.contentExtent.height, CGFloat(PageSizePreset.a3.size.height),
            accuracy: 1)
    }

    /// Writing near the bottom must not push the bottom further away. This is what stops a page
    /// growing into the endless scroll the split then has to undo.
    func testWritingAtTheBottomDoesNotMakeThePageTaller() {
        let container = makeContainer(portrait, pageSize: PageSizePreset.a4.size)
        container.sheetHeight = CGFloat(PageSizePreset.a4.size.height)
        let before = container.contentExtent.height

        container.growContent(
            toCover: CGRect(x: 100, y: CGFloat(PageSizePreset.a4.size.height) - 20,
                            width: 50, height: 40))

        XCTAssertEqual(container.contentExtent.height, before, accuracy: 1)
    }

    /// But a page that already reaches past its sheet keeps every bit of it reachable. Ink written
    /// below the sheet before pages were sheets is still there until the split moves it, and an
    /// area that refused to cover it would not park it off-page — it would strand it, with no
    /// scroll or zoom that brings it back.
    func testAPageThatAlreadyOverflowsItsSheetStaysReachable() {
        let tall = CGRect(x: 0, y: 0, width: 1000, height: 4000)
        let container = makeContainer(portrait, ink: tall)
        container.sheetHeight = CGFloat(PageSize.legacyUndeclared.height)

        XCTAssertGreaterThan(container.contentExtent.height, 4000)
    }

    // MARK: - The sheet arriving after the canvas

    /// The editor loads its page asynchronously, so the canvas is laid out and fitted before the
    /// page's declared sheet is known. The sheet has to re-fit when it lands, or an A4 page would
    /// keep the fallback's zoom — barely visible at 1404 vs 1400, and plainly wrong for A3.
    func testASheetArrivingAfterLayoutRefitsThePage() {
        let container = makeContainer(portrait)
        XCTAssertEqual(container.canvas.zoomScale, fit(portrait.width), accuracy: 0.001)

        let a3 = PageSizePreset.a3.size
        container.setPageWidth(CGFloat(a3.width))

        XCTAssertEqual(container.pageWidth, CGFloat(a3.width))
        XCTAssertEqual(
            container.canvas.zoomScale, portrait.width / CGFloat(a3.width), accuracy: 0.001)
    }

    /// …but not over the user's own zoom: a page pinched off the fit keeps the zoom it was pinched
    /// to, and only the reachable range grows.
    func testASheetArrivingDoesNotOverrideAPinchedZoom() {
        let container = makeContainer(portrait)
        container.canvas.zoomScale = 2
        container.canvasZoomDidChange()

        container.setPageWidth(CGFloat(PageSizePreset.a3.size.width))

        XCTAssertEqual(container.canvas.zoomScale, 2, accuracy: 0.001)
        XCTAssertLessThanOrEqual(
            container.canvas.minimumZoomScale,
            portrait.width / CGFloat(PageSizePreset.a3.size.width))
    }

    /// "Actual size" means the zoom is the user's business, sheet changes included.
    func testASheetArrivingLeavesActualSizeAlone() {
        let container = makeContainer()
        container.keepsFitToWidth = false
        rotate(container, to: portrait)
        XCTAssertEqual(container.canvas.zoomScale, 1, accuracy: 0.001)

        container.setPageWidth(CGFloat(PageSizePreset.a3.size.width))
        XCTAssertEqual(container.canvas.zoomScale, 1, accuracy: 0.001)
    }
}
