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

    /// Continuous scrolling uses the sheet width first. Pulling past the physical bottom asks
    /// Bopa to create and enter the next real page.
    @MainActor
    func testContinuousScrollCreatesARealSecondPageAtTheBottom() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--uitest-reset-tool", "-handwriting.pageNavigation", "continuous",
            "-handwriting.fingerDrawing", "false",
        ]
        app.launch()

        let canvas = openFreshNotebook(app)
        let pageCounter = app.buttons["editor.pages"]
        XCTAssertTrue(pageCounter.waitForExistence(timeout: 5))
        XCTAssertEqual(pageCounter.value as? String, "Page 1 of 1")

        // Each drag travels through the width-fitted sheet and then past its bottom. The first
        // one runs off the end of the notebook, which appends page two *without leaving page
        // one* — the notebook grows under the scroll rather than jumping. Further scrolling
        // then crosses the seam onto it, which is the only thing that changes which page is
        // open. Both halves are asserted, because a version that jumped straight to page two
        // would pass an assertion about the count alone.
        func dragPastTheBottom() {
            canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: 0.85))
                .press(
                    forDuration: 0.05,
                    thenDragTo: canvas.coordinate(
                        withNormalizedOffset: CGVector(dx: 0.50, dy: 0.10)))
        }

        dragPastTheBottom()

        let notebookGrew = NSPredicate(format: "value == 'Page 1 of 2'")
        XCTAssertEqual(
            XCTWaiter().wait(
                for: [expectation(for: notebookGrew, evaluatedWith: pageCounter)], timeout: 5),
            .completed,
            "scrolling off the end should append a second page without leaving the first")

        // Now there is a page below the seam, so scrolling on crosses onto it. Asserted on the
        // page *index* rather than on "2 of 2": a drag that carries through the seam usually
        // runs off the end of page two in the same movement, which appends a third page. The
        // count growing is the feature working, not a failure — what matters is which page is
        // open.
        let onSecondPage = NSPredicate(format: "value BEGINSWITH 'Page 2 of'")
        var crossed = false
        for _ in 0..<4 where !crossed {
            dragPastTheBottom()
            crossed = XCTWaiter().wait(
                for: [expectation(for: onSecondPage, evaluatedWith: pageCounter)], timeout: 3)
                == .completed
        }
        XCTAssertTrue(crossed, "scrolling through the seam should enter the second page")
        XCTAssertEqual(
            app.descendants(matching: .any)["editor.canvas"].firstMatch.value as? String,
            "strokes:0")

        // And back: scrolling up past the top returns to the page above, so the crossing works
        // in both directions rather than being a one-way trip.
        let backOnFirstPage = NSPredicate(format: "value BEGINSWITH 'Page 1 of'")
        var returned = false
        for _ in 0..<4 where !returned {
            canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: 0.15))
                .press(
                    forDuration: 0.05,
                    thenDragTo: canvas.coordinate(
                        withNormalizedOffset: CGVector(dx: 0.50, dy: 0.90)))
            returned = XCTWaiter().wait(
                for: [expectation(for: backOnFirstPage, evaluatedWith: pageCounter)], timeout: 3)
                == .completed
        }
        XCTAssertTrue(returned, "scrolling back up through the seam should return to page one")
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
