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
        let textField = app.textFields["newNotebook.title"]
        XCTAssertTrue(textField.waitForExistence(timeout: 5))
        // The New-notebook form is a sheet, not an alert: nothing takes focus on its own, so the
        // field has to be tapped before it will accept typing.
        textField.tap()
        textField.typeText(title)
        app.buttons["newNotebook.create"].tap()

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

    /// The reported Bopa dead end: with sideways turning stored, the first page used to disable
    /// vertical bounce, so an upward pull could neither reach nor create page two. The app now
    /// treats that pull as "more paper" independently of the preferred sideways turn gesture.
    @MainActor
    func testVerticalPullCreatesARealSecondPageWhenSidewaysTurningIsPreferred() throws {
        let app = XCUIApplication()
        // UserDefaults' argument domain lets the UI test exercise the persisted horizontal mode
        // without adding a production-only settings hook.
        app.launchArguments = [
            "--uitest-reset-tool", "-handwriting.pageTurn", "horizontal",
            "-handwriting.fingerDrawing", "false",
        ]
        app.launch()

        let canvas = openFreshNotebook(app)
        let pageCounter = app.buttons["editor.pages"]
        XCTAssertTrue(pageCounter.waitForExistence(timeout: 5))
        XCTAssertEqual(pageCounter.value as? String, "Page 1 of 1")

        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: 0.85))
            .press(
                forDuration: 0.05,
                thenDragTo: canvas.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.50, dy: 0.10)))

        let onSecondPage = NSPredicate(format: "value == 'Page 2 of 2'")
        XCTAssertEqual(
            XCTWaiter().wait(
                for: [expectation(for: onSecondPage, evaluatedWith: pageCounter)], timeout: 5),
            .completed,
            "pulling past the bottom should create and enter the second real page")
        XCTAssertEqual(
            app.descendants(matching: .any)["editor.canvas"].firstMatch.value as? String,
            "strokes:0")
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
