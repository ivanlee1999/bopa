import Combine
import PencilKit
import SwiftUI
import XCTest

@testable import Bopa

/// Protect the established tool-gesture boundary, without treating anonymous drawing
/// callbacks as a final-pressure completion signal. Physical Pencil timing needs device coverage.
@MainActor
final class CanvasDrawingLifecycleTests: XCTestCase {
    private final class DrawingBox {
        var value = PKDrawing()
        var idleDrawings: [PKDrawing] = []
    }

    func testUnchangedUndoCheckpointsDoNotRepublishToolbarState() {
        let manager = UndoManager()
        let controller = CanvasUndoController()
        controller.attach(manager)
        var publications = 0
        let subscription = controller.objectWillChange.sink { publications += 1 }
        defer { subscription.cancel() }
        for _ in 0..<20 {
            NotificationCenter.default.post(name: .NSUndoManagerCheckpoint, object: manager)
            controller.refresh()
        }
        XCTAssertEqual(publications, 0, "menu validation must not invalidate the same menu again")
        XCTAssertFalse(controller.canUndo)
        XCTAssertFalse(controller.canRedo)
    }

    func testUndoStateChangesPublishAndSubsequentRefreshIsQuiet() {
        let manager = UndoManager()
        manager.groupsByEvent = false
        let controller = CanvasUndoController()
        controller.attach(manager)
        let target = NSObject()
        manager.beginUndoGrouping()
        manager.registerUndo(withTarget: target) { _ in }
        manager.endUndoGrouping()
        controller.refresh()
        XCTAssertTrue(controller.canUndo)

        var publications = 0
        let subscription = controller.objectWillChange.sink { publications += 1 }
        defer { subscription.cancel() }
        controller.refresh()
        XCTAssertEqual(publications, 0)
        manager.removeAllActions()
        controller.refresh()
        XCTAssertFalse(controller.canUndo)
        XCTAssertFalse(controller.canRedo)
        XCTAssertEqual(publications, 1, "the real availability change must reach the toolbar")
        controller.refresh()
        XCTAssertEqual(publications, 1)
    }

    func testReentrantUndoRefreshPublishesEachChangeOnlyOnce() {
        let manager = UndoManager()
        manager.groupsByEvent = false
        let target = NSObject()
        manager.beginUndoGrouping()
        manager.registerUndo(withTarget: target) { _ in }
        manager.endUndoGrouping()
        let controller = CanvasUndoController()
        controller.attach(manager)
        XCTAssertTrue(controller.canUndo)

        var publications = 0
        let subscription = controller.objectWillChange.sink {
            publications += 1
            // Bound the reentry so a missing guard produces a failed assertion, not a hang.
            // Published sends before assignment, so the nested read still sees the old flag.
            if publications == 1 { controller.refresh() }
        }
        defer { subscription.cancel() }
        manager.removeAllActions()
        controller.refresh()
        XCTAssertEqual(publications, 1)
        XCTAssertFalse(controller.canUndo)
        XCTAssertFalse(controller.canRedo)
        controller.refresh()
        XCTAssertEqual(publications, 1)
    }

    private final class UndoValue {
        var value = 0

        func set(_ newValue: Int, using manager: UndoManager) {
            let previous = value
            manager.registerUndo(withTarget: self) { target in
                target.set(previous, using: manager)
            }
            value = newValue
        }
    }

    func testUndoAndRedoUpdateAvailabilityAndPerformTheRegisteredEdit() {
        let manager = UndoManager()
        manager.groupsByEvent = false
        let controller = CanvasUndoController()
        controller.attach(manager)
        let target = UndoValue()
        manager.beginUndoGrouping()
        target.set(1, using: manager)
        manager.endUndoGrouping()
        controller.refresh()
        XCTAssertEqual(target.value, 1)
        XCTAssertTrue(controller.canUndo)
        XCTAssertFalse(controller.canRedo)

        // Do not manually refresh here: the manager's actual undo/redo notifications must
        // update availability, and each inverse must register the next real operation.
        controller.undo()
        XCTAssertEqual(target.value, 0)
        XCTAssertFalse(controller.canUndo)
        XCTAssertTrue(controller.canRedo)
        controller.redo()
        XCTAssertEqual(target.value, 1)
        XCTAssertTrue(controller.canUndo)
        XCTAssertFalse(controller.canRedo)
        controller.undo()
        XCTAssertEqual(target.value, 0)
        XCTAssertFalse(controller.canUndo)
        XCTAssertTrue(controller.canRedo)
        manager.removeAllActions()
        controller.refresh()
        XCTAssertFalse(controller.canUndo)
        XCTAssertFalse(controller.canRedo)
    }

    func testSwitchingUndoManagersStopsObservingThePreviousManager() {
        let oldManager = UndoManager()
        let newManager = UndoManager()
        newManager.groupsByEvent = false
        let controller = CanvasUndoController()
        controller.attach(oldManager)
        let target = NSObject()
        newManager.beginUndoGrouping()
        newManager.registerUndo(withTarget: target) { _ in }
        newManager.endUndoGrouping()
        controller.attach(newManager)
        XCTAssertTrue(controller.canUndo, "attachment must read the newly selected manager")
        XCTAssertFalse(controller.canRedo)

        var publications = 0
        let subscription = controller.objectWillChange.sink { publications += 1 }
        defer { subscription.cancel() }
        // removeAllActions requires an explicit refresh. Leave the exposed flag stale so an
        // incorrectly retained old-manager observer would reveal itself by refreshing it.
        newManager.removeAllActions()
        NotificationCenter.default.post(name: .NSUndoManagerCheckpoint, object: oldManager)
        XCTAssertTrue(controller.canUndo, "an old-manager notification must not cause a refresh")
        XCTAssertEqual(publications, 0)
        NotificationCenter.default.post(name: .NSUndoManagerCheckpoint, object: newManager)
        XCTAssertFalse(controller.canUndo)
        XCTAssertFalse(controller.canRedo)
        XCTAssertEqual(publications, 1)
        controller.attach(newManager)
        controller.refresh()
        XCTAssertEqual(publications, 1, "reattachment and unchanged refresh must remain quiet")
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

    func testUnchangedToolSessionsAlwaysReleaseNavigation() {
        let tools: [PKTool] = [PKInkingTool(.pen, color: .black, width: 4),
                               PKEraserTool(.vector), PKLassoTool()]
        for tool in tools {
            let box = DrawingBox()
            let live = CanvasLiveState()
            let parent = EditorCanvasView(
                pageId: "page", drawing: Binding(get: { box.value }, set: { box.value = $0 }),
                liveState: live, onChanged: {}, onIdle: { box.idleDrawings.append(box.value) })
            let coordinator = parent.makeCoordinator()
            let canvas = PKCanvasView()
            canvas.tool = tool
            coordinator.canvasViewDidBeginUsingTool(canvas)
            XCTAssertTrue(live.isDrawing)
            coordinator.canvasViewDidEndUsingTool(canvas)
            XCTAssertFalse(live.isDrawing, "an unchanged gesture must not wait for a mutation")
            XCTAssertEqual(box.idleDrawings.count, 1)
        }
    }

    func testLateDrawingUpdatesDoNotEndAnotherActiveToolSession() {
        let box = DrawingBox()
        let live = CanvasLiveState()
        let parent = EditorCanvasView(
            pageId: "page", drawing: Binding(get: { box.value }, set: { box.value = $0 }),
            liveState: live, onChanged: {}, onIdle: { box.idleDrawings.append(box.value) })
        let coordinator = parent.makeCoordinator()
        let canvas = PKCanvasView()
        coordinator.canvasViewDidBeginUsingTool(canvas)
        coordinator.canvasViewDidEndUsingTool(canvas)
        XCTAssertEqual(box.idleDrawings.count, 1)
        coordinator.canvasViewDidBeginUsingTool(canvas)
        canvas.drawing = drawing(1)
        coordinator.canvasViewDrawingDidChange(canvas)
        XCTAssertTrue(live.isDrawing)
        XCTAssertEqual(box.idleDrawings.count, 1)
        coordinator.canvasViewDidEndUsingTool(canvas)
        XCTAssertFalse(live.isDrawing)
        XCTAssertEqual(box.idleDrawings.count, 2)
        canvas.drawing = drawing(2)
        coordinator.canvasViewDrawingDidChange(canvas)
        XCTAssertFalse(live.isDrawing)
        XCTAssertEqual(box.value.strokes.count, 2)
        XCTAssertEqual(box.idleDrawings.count, 2, "late changes must not invent another tool end")
    }

    func testSelectingAnEraserDuringInkDoesNotReclassifyTheGesture() {
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
        canvas.tool = PKEraserTool(.vector)
        canvas.drawing = drawing(1).transformed(using: CGAffineTransform(translationX: 0, y: -200))
        coordinator.canvasViewDrawingDidChange(canvas)
        coordinator.canvasViewDidEndUsingTool(canvas)
        XCTAssertEqual(filedRanges, [0..<1])
        XCTAssertFalse(live.isDrawing)
    }

    func testSelectingAPenDuringErasingDoesNotFileEraserFragmentsAboveTheTop() {
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
        canvas.tool = PKInkingTool(.pen, color: .black, width: 4)
        canvas.drawing = drawing(2)
        coordinator.canvasViewDrawingDidChange(canvas)
        coordinator.canvasViewDidEndUsingTool(canvas)
        XCTAssertTrue(filedRanges.isEmpty)
        XCTAssertFalse(live.isDrawing)
    }

    func testEachToolGestureResetsInkProvenance() {
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
        canvas.tool = PKEraserTool(.bitmap)
        coordinator.canvasViewDidBeginUsingTool(canvas)
        canvas.drawing = drawing(2)
        coordinator.canvasViewDrawingDidChange(canvas)
        coordinator.canvasViewDidEndUsingTool(canvas)
        XCTAssertTrue(filedRanges.isEmpty, "erasing invalidates the new-stroke suffix")
        XCTAssertFalse(live.isDrawing)

        canvas.tool = PKInkingTool(.pen, color: .black, width: 4)
        coordinator.canvasViewDidBeginUsingTool(canvas)
        canvas.drawing = drawing(3)
        coordinator.canvasViewDrawingDidChange(canvas)
        coordinator.canvasViewDidEndUsingTool(canvas)
        XCTAssertEqual(filedRanges, [2..<3], "a fresh inking sequence must reset provenance")
    }

}
