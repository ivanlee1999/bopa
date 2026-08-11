import XCTest

/// The one thing unit tests cannot prove: that touch input actually produces ink on the
/// PKCanvasView. XCUITest synthesizes events through the system event path (unlike raw HID
/// injection, which PencilKit ignores), so a passing drag here verifies the live canvas.
final class DrawingUITests: XCTestCase {

    /// Creates a fresh notebook, opens it, and returns the canvas element.
    @MainActor
    private func openFreshNotebook(_ app: XCUIApplication) -> XCUIElement {
        let title = "UITest \(Int.random(in: 1000...9999))"
        app.buttons["library.add"].tap()
        let textField = app.textFields.firstMatch
        XCTAssertTrue(textField.waitForExistence(timeout: 5))
        textField.typeText(title)
        app.buttons["Create"].tap()

        // Scoped to the grid: the sidebar tree lists the same notebook, so the bare title
        // matches twice.
        let card = app.descendants(matching: .any)["library.contents"].staticTexts[title]
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        card.tap()

        let canvas = app.descendants(matching: .any)["editor.canvas"].firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 5), "canvas should appear")
        return canvas
    }

    /// Draws a short diagonal squiggle on the canvas (diagonal-down, not horizontal,
    /// to avoid any nav-gesture ambiguity).
    @MainActor
    private func drawStroke(
        on canvas: XCUIElement, from: CGVector, to: CGVector
    ) {
        let start = canvas.coordinate(withNormalizedOffset: from)
        let end = canvas.coordinate(withNormalizedOffset: to)
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    /// Waits until the canvas accessibilityValue reports the given stroke count
    /// (updated in canvasViewDrawingDidChange, i.e. at stroke end / after undo).
    @MainActor
    private func waitForStrokes(
        _ count: Int, on canvas: XCUIElement, message: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let predicate = NSPredicate(format: "value == 'strokes:\(count)'")
        let result = XCTWaiter().wait(
            for: [expectation(for: predicate, evaluatedWith: canvas)], timeout: 5)
        XCTAssertEqual(
            result, .completed,
            "\(message), canvas value = \(canvas.value ?? "nil")",
            file: file, line: line)
    }

    @MainActor
    func testFingerDragProducesStroke() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-reset-tool"]
        app.launch()

        let canvas = openFreshNotebook(app)
        XCTAssertEqual(canvas.value as? String, "strokes:0")

        drawStroke(
            on: canvas,
            from: CGVector(dx: 0.35, dy: 0.30), to: CGVector(dx: 0.45, dy: 0.55))
        waitForStrokes(1, on: canvas, message: "expected 1 stroke after drag")

        // Second stroke for good measure.
        drawStroke(
            on: canvas,
            from: CGVector(dx: 0.55, dy: 0.30), to: CGVector(dx: 0.50, dy: 0.55))
        waitForStrokes(2, on: canvas, message: "expected 2 strokes")
    }

    @MainActor
    func testUndoRemovesJustDrawnStrokeAndRedoRestoresIt() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-reset-tool"]
        app.launch()

        let canvas = openFreshNotebook(app)
        XCTAssertEqual(canvas.value as? String, "strokes:0")

        let undoButton = app.buttons["editor.undo"]
        let redoButton = app.buttons["editor.redo"]
        XCTAssertTrue(undoButton.waitForExistence(timeout: 5))
        XCTAssertFalse(undoButton.isEnabled, "undo should be disabled before any edit")
        XCTAssertFalse(redoButton.isEnabled, "redo should be disabled before any edit")

        drawStroke(
            on: canvas,
            from: CGVector(dx: 0.35, dy: 0.30), to: CGVector(dx: 0.45, dy: 0.55))
        waitForStrokes(1, on: canvas, message: "expected 1 stroke after drag")

        let undoEnabled = NSPredicate(format: "isEnabled == true")
        let enabledResult = XCTWaiter().wait(
            for: [expectation(for: undoEnabled, evaluatedWith: undoButton)], timeout: 5)
        XCTAssertEqual(enabledResult, .completed, "undo button should enable after drawing")

        undoButton.tap()
        waitForStrokes(0, on: canvas, message: "expected 0 strokes after undo")

        let redoEnabled = XCTWaiter().wait(
            for: [expectation(for: undoEnabled, evaluatedWith: redoButton)], timeout: 5)
        XCTAssertEqual(redoEnabled, .completed, "redo button should enable after undo")

        redoButton.tap()
        waitForStrokes(1, on: canvas, message: "expected stroke back after redo")
    }
}
