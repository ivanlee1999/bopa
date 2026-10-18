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
            liveState: live, onChanged: {}, onIdle: { box.idleDrawings.append(box.value) })
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
            liveState: live, onChanged: {}, onIdle: { box.idleDrawings.append(box.value) })
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

    func testSelectingAnEraserAfterLiftDoesNotReclassifyPendingInk() {
        let box = DrawingBox()
        let live = CanvasLiveState()
        var filedRanges: [Range<Int>] = []
        let parent = EditorCanvasView(
            pageId: "page", drawing: Binding(get: { box.value }, set: { box.value = $0 }),
            liveState: live,
            fileInkAboveTheTop: { _, range in filedRanges.append(range); return nil },
            onChanged: {})
        let coordinator = parent.makeCoordinator()
        let container = CanvasContainerView()
        container.sheetHeight = 1000
        container.hasPreviousPage = true
        coordinator.container = container
        let canvas = container.canvas
        canvas.tool = PKInkingTool(.pen, color: .black, width: 4)
        coordinator.canvasViewDidBeginUsingTool(canvas)
        coordinator.canvasViewDidEndUsingTool(canvas)
        canvas.tool = PKEraserTool(.vector)
        canvas.drawing = drawing(1).transformed(using: CGAffineTransform(translationX: 0, y: -200))
        coordinator.canvasViewDrawingDidChange(canvas)
        XCTAssertEqual(filedRanges, [0..<1])
        XCTAssertFalse(live.isDrawing)
    }

    func testSelectingAPenAfterErasingDoesNotFileEraserFragmentsAboveTheTop() {
        let box = DrawingBox()
        let live = CanvasLiveState()
        var filedRanges: [Range<Int>] = []
        let parent = EditorCanvasView(
            pageId: "page", drawing: Binding(get: { box.value }, set: { box.value = $0 }),
            liveState: live,
            fileInkAboveTheTop: { _, range in filedRanges.append(range); return nil },
            onChanged: {})
        let coordinator = parent.makeCoordinator()
        let container = CanvasContainerView()
        container.sheetHeight = 1000
        container.hasPreviousPage = true
        coordinator.container = container
        let canvas = container.canvas
        canvas.drawing = drawing(1)
        canvas.tool = PKEraserTool(.bitmap)
        coordinator.canvasViewDidBeginUsingTool(canvas)
        coordinator.canvasViewDidEndUsingTool(canvas)
        canvas.tool = PKInkingTool(.pen, color: .black, width: 4)
        canvas.drawing = drawing(2)
        coordinator.canvasViewDrawingDidChange(canvas)
        XCTAssertTrue(filedRanges.isEmpty)
        XCTAssertFalse(live.isDrawing)
    }


    func testMixedToolSequenceIsConservativeButNextInkSequenceResetsProvenance() {
        let box = DrawingBox()
        let live = CanvasLiveState()
        var filedRanges: [Range<Int>] = []
        let parent = EditorCanvasView(
            pageId: "page", drawing: Binding(get: { box.value }, set: { box.value = $0 }),
            liveState: live,
            fileInkAboveTheTop: { _, range in filedRanges.append(range); return nil },
            onChanged: {})
        let coordinator = parent.makeCoordinator()
        let container = CanvasContainerView()
        container.sheetHeight = 1000
        container.hasPreviousPage = true
        coordinator.container = container
        let canvas = container.canvas
        canvas.tool = PKInkingTool(.pen, color: .black, width: 4)
        coordinator.canvasViewDidBeginUsingTool(canvas)
        coordinator.canvasViewDidEndUsingTool(canvas)
        canvas.tool = PKEraserTool(.bitmap)
        coordinator.canvasViewDidBeginUsingTool(canvas)
        coordinator.canvasViewDidEndUsingTool(canvas)
        canvas.drawing = drawing(2)
        coordinator.canvasViewDrawingDidChange(canvas)
        XCTAssertTrue(filedRanges.isEmpty, "erasing invalidates the new-stroke suffix")
        XCTAssertFalse(live.isDrawing)

        canvas.tool = PKInkingTool(.pen, color: .black, width: 4)
        coordinator.canvasViewDidBeginUsingTool(canvas)
        coordinator.canvasViewDidEndUsingTool(canvas)
        canvas.drawing = drawing(3)
        coordinator.canvasViewDrawingDidChange(canvas)
        XCTAssertEqual(filedRanges, [2..<3], "a fresh inking sequence must reset provenance")
    }

}
