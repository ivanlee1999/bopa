import NotableKit
import PencilKit
import UIKit
import XCTest

@testable import Bopa

/// Where a text box is on screen, and what a tap on it means.
///
/// The canvas keeps the page in page units and shows it through a zoom and a scroll, so every
/// one of these is really the same question: does the box the user is pointing at match the box
/// the page thinks is there.
@MainActor
final class TextBoxCanvasTests: XCTestCase {

    private func container(zoom: CGFloat = 1, offset: CGPoint = .zero) -> CanvasContainerView {
        let container = CanvasContainerView(
            frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        container.keepsFitToWidth = false
        container.pageWidth = 1400
        container.sheetHeight = 1980
        container.layoutIfNeeded()
        container.canvas.zoomScale = zoom
        container.canvas.contentOffset = offset
        return container
    }

    private func block(
        id: String, x: Int, y: Int, width: Int = 400, height: Int = 100, kind: String = "md"
    ) -> CouchBlock {
        CouchBlock(
            id: id, kind: kind, orderKey: "", text: "hello",
            x: x, y: y, width: width, height: height,
            createdAt: "2026-01-0\(id.count)T00:00:00.000Z",
            updatedAt: "2026-01-01T00:00:00.000Z", deviceId: "ipad")
    }

    func testAPointOnScreenBecomesAPointOnThePage() {
        let view = container(zoom: 0.5, offset: CGPoint(x: 100, y: 200))
        // Read back rather than assumed: the canvas clamps a zoom to its own minimum (the width
        // fit), so asking for 0.5 on an 800pt-wide view of a 1400-unit page gets 0.571.
        let zoom = view.canvas.zoomScale
        let offset = view.canvas.contentOffset
        XCTAssertEqual(
            view.pagePoint(.zero),
            CGPoint(x: offset.x / zoom, y: offset.y / zoom))
        XCTAssertEqual(
            view.pagePoint(CGPoint(x: 50, y: 50)),
            CGPoint(x: (50 + offset.x) / zoom, y: (50 + offset.y) / zoom))
    }

    func testATapFindsTheBoxUnderIt() {
        let view = container()
        view.setTextBlocks([block(id: "a", x: 100, y: 100)])
        XCTAssertEqual(view.textBlock(at: CGPoint(x: 150, y: 150))?.id, "a")
        XCTAssertNil(view.textBlock(at: CGPoint(x: 50, y: 50)))
        XCTAssertNil(view.textBlock(at: CGPoint(x: 600, y: 150)))
    }

    /// Overlapping boxes: the one drawn last is the one on top, so it is the one a tap gets.
    func testTheTopmostBoxWins() {
        let view = container()
        view.setTextBlocks([block(id: "a", x: 0, y: 0), block(id: "bb", x: 10, y: 10)])
        XCTAssertEqual(view.textBlock(at: CGPoint(x: 50, y: 50))?.id, "bb")
    }

    func testTheRightEdgeBandIsWhereAResizeStarts() {
        let view = container()
        let box = block(id: "a", x: 100, y: 100, width: 400)
        view.setTextBlocks([box])
        XCTAssertTrue(view.isOnResizeEdge(CGPoint(x: 495, y: 150), of: box))
        XCTAssertFalse(view.isOnResizeEdge(CGPoint(x: 300, y: 150), of: box))
        // Outside the box entirely is not an edge, however close to its right side.
        XCTAssertFalse(view.isOnResizeEdge(CGPoint(x: 495, y: 400), of: box))
    }

    /// A box typed at the foot of a page must stay scrollable-to. Installing it without growing
    /// the scrollable area is the bug the page images already hit: it exists, it renders, and no
    /// scroll reaches it.
    func testABoxBelowTheSheetGrowsTheScrollableArea() {
        let view = container()
        let before = view.contentExtent.height
        XCTAssertEqual(before, 1980, "a page with a sheet ends at its paper")
        view.setTextBlocks([block(id: "a", x: 100, y: 3000, height: 200)])
        XCTAssertGreaterThanOrEqual(
            view.contentExtent.height, 3200,
            "a box past the paper must still be reachable")
    }

    func testOnlyTheTextToolArmsTheTapGestures() {
        let view = container()
        XCTAssertTrue(view.canvas.drawingGestureRecognizer.isEnabled)
        view.isTextMode = true
        // The pen stops drawing and starts placing a caret; the scroll view is untouched, which
        // is what keeps two-finger scrolling and pinch-zoom working while the tool is up.
        XCTAssertFalse(view.canvas.drawingGestureRecognizer.isEnabled)
        XCTAssertTrue(view.canvas.panGestureRecognizer.isEnabled)
        view.isTextMode = false
        XCTAssertTrue(view.canvas.drawingGestureRecognizer.isEnabled)
    }

    func testTheOpenBoxIsTakenOutOfTheDrawnLayer() {
        let view = container()
        let box = block(id: "a", x: 100, y: 100)
        view.setTextBlocks([box])
        view.beginTextEditing(box, source: "hello")
        XCTAssertEqual(view.editingTextBlock?.id, "a")
        XCTAssertFalse(view.textEditor.isHidden)

        let finished = view.endTextEditing()
        XCTAssertEqual(finished?.block.id, "a")
        XCTAssertEqual(finished?.text, "hello")
        XCTAssertTrue(view.textEditor.isHidden)
        XCTAssertNil(view.editingTextBlock)
        // Nothing is open, so a second call has nothing to report.
        XCTAssertNil(view.endTextEditing())
    }

    func testTheTextViewSitsOverTheBoxAtTheCurrentZoom() {
        let view = container(zoom: 0.5, offset: CGPoint(x: 10, y: 20))
        let box = block(id: "a", x: 100, y: 200, width: 400, height: 100)
        view.setTextBlocks([box])
        view.beginTextEditing(box, source: "hello")
        view.updateContentGeometry()
        let zoom = view.canvas.zoomScale
        let offset = view.canvas.contentOffset
        XCTAssertEqual(view.textEditor.frame.origin.x, 100 * zoom - offset.x, accuracy: 0.5)
        XCTAssertEqual(view.textEditor.frame.origin.y, 200 * zoom - offset.y, accuracy: 0.5)
        XCTAssertEqual(view.textEditor.frame.width, 400 * zoom, accuracy: 0.5)
    }

    /// The text view keeps its own undo stack. Sharing the page's would put every keystroke on
    /// the stack the rail's undo button drives, between the strokes.
    func testTypingUndoIsSeparateFromThePageUndo() {
        let view = container()
        XCTAssertFalse(view.textEditor.undoManager === view.pageUndoManager)
    }
}
