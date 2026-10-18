import PencilKit
import SwiftUI
import XCTest

@testable import Bopa

/// Drive Apple's documented callback order: pencil-up happens before the finished drawing.
@MainActor
final class CanvasDrawingLifecycleTests: XCTestCase {
    private final class DrawingBox {
        var value = PKDrawing()
        var idleDrawings: [PKDrawing] = []
    }

    private func drawing(_ count: Int) -> PKDrawing {
        PKDrawing(strokes: (0..<count).map { i in
            let points = [
                PKStrokePoint(location: CGPoint(x: 30, y: CGFloat(50 + i * 40)), timeOffset: 0,
                              size: CGSize(width: 4, height: 4), opacity: 1, force: 0.5,
                              azimuth: 0, altitude: .pi / 2),
                PKStrokePoint(location: CGPoint(x: 90, y: CGFloat(70 + i * 40)), timeOffset: 0.1,
                              size: CGSize(width: 4, height: 4), opacity: 1, force: 0.5,
                              azimuth: 0, altitude: .pi / 2),
            ]
            return PKStroke(ink: PKInk(.pen, color: .black),
                            path: PKStrokePath(controlPoints: points, creationDate: Date()))
        })
    }

    func testPencilUpDoesNotPublishIdleUntilTheFinishedDrawingArrives() {
        let box = DrawingBox()
        let live = CanvasLiveState()
        let parent = EditorCanvasView(
            pageId: "page", drawing: Binding(get: { box.value }, set: { box.value = $0 }),
            liveState: live, onIdle: { box.idleDrawings.append(box.value) })
        let coordinator = parent.makeCoordinator()
        let canvas = PKCanvasView()
        coordinator.canvasViewDidBeginUsingTool(canvas)
        coordinator.canvasViewDidEndUsingTool(canvas)
        XCTAssertTrue(live.isDrawing, "remote reloads must still be blocked at pencil-up")
        XCTAssertTrue(box.idleDrawings.isEmpty)

        canvas.drawing = drawing(1)
        coordinator.canvasViewDrawingDidChange(canvas)
        XCTAssertFalse(live.isDrawing)
        XCTAssertEqual(box.idleDrawings.map { $0.strokes.count }, [1])
        XCTAssertEqual(box.value.strokes.count, 1)
    }

    func testAnEarlierStrokesFinalCallbackCannotInterruptTheNextStroke() {
        let box = DrawingBox()
        let live = CanvasLiveState()
        let parent = EditorCanvasView(
            pageId: "page", drawing: Binding(get: { box.value }, set: { box.value = $0 }),
            liveState: live, onIdle: { box.idleDrawings.append(box.value) })
        let coordinator = parent.makeCoordinator()
        let canvas = PKCanvasView()
        coordinator.canvasViewDidBeginUsingTool(canvas)
        coordinator.canvasViewDidEndUsingTool(canvas)
        coordinator.canvasViewDidBeginUsingTool(canvas)
        canvas.drawing = drawing(1)
        coordinator.canvasViewDrawingDidChange(canvas)
        XCTAssertTrue(live.isDrawing)
        XCTAssertTrue(box.idleDrawings.isEmpty)
        coordinator.canvasViewDidEndUsingTool(canvas)
        canvas.drawing = drawing(2)
        coordinator.canvasViewDrawingDidChange(canvas)
        XCTAssertFalse(live.isDrawing)
        XCTAssertEqual(box.idleDrawings.map { $0.strokes.count }, [2])
    }
}
