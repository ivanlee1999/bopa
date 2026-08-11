import XCTest

/// Proves the eraser reaches disk. The bug this covers: PencilKit does not shorten an
/// erased stroke, it keeps the whole path plus a mask — an exporter that reads only the
/// path saves the ink back exactly as it was, and the erasure vanishes on reopen.
/// Only a live canvas produces those masks, so this cannot be checked in a unit test.
final class EraserUITests: XCTestCase {

    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments
        app.launch()
        return app
    }

    @MainActor
    private func openNotebook(_ app: XCUIApplication, titled title: String) -> XCUIElement {
        // Scoped to the grid: the sidebar tree lists the same notebook, so the bare title
        // matches twice.
        let card = app.descendants(matching: .any)["library.contents"].staticTexts[title]
        XCTAssertTrue(card.waitForExistence(timeout: 10), "notebook \(title) should be listed")
        card.tap()
        let canvas = app.descendants(matching: .any)["editor.canvas"].firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 10), "canvas should appear")
        return canvas
    }

    @MainActor
    private func drag(on canvas: XCUIElement, from: CGVector, to: CGVector) {
        canvas.coordinate(withNormalizedOffset: from)
            .press(forDuration: 0.05, thenDragTo: canvas.coordinate(withNormalizedOffset: to))
    }

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

    /// Lets the editor's debounced autosave (2s) fire before the app is torn down.
    @MainActor
    private func waitForAutosave() {
        _ = XCTWaiter().wait(for: [expectation(description: "autosave")], timeout: 4)
    }

    /// Draw a long stroke, erase its middle, then erase the very same spot again after a
    /// reopen. The second pass must find an empty gap and leave the two pieces alone.
    ///
    /// Erasing the middle leaves PencilKit holding two strokes that each still carry the
    /// whole original path, so a stroke count alone cannot tell a saved erasure from a lost
    /// one. Re-erasing can: ink wrongly restored across the gap gets cut in half again, and
    /// the reopened page comes back with four strokes instead of two.
    @MainActor
    func testErasingIsStillGoneAfterAReopen() throws {
        let title = "Eraser \(Int.random(in: 1000...9999))"
        let gapTop = CGVector(dx: 0.50, dy: 0.30)
        let gapBottom = CGVector(dx: 0.50, dy: 0.50)

        let drawingApp = launch(["--uitest-reset-tool"])
        drawingApp.buttons["library.add"].tap()
        let textField = drawingApp.textFields.firstMatch
        XCTAssertTrue(textField.waitForExistence(timeout: 5))
        textField.typeText(title)
        drawingApp.buttons["Create"].tap()

        var canvas = openNotebook(drawingApp, titled: title)
        drag(on: canvas, from: CGVector(dx: 0.20, dy: 0.40), to: CGVector(dx: 0.80, dy: 0.40))
        waitForStrokes(1, on: canvas, message: "expected 1 stroke after drawing")
        waitForAutosave()
        drawingApp.terminate()

        // Relaunch with the eraser selected and rub out the middle of that stroke.
        let erasingApp = launch(["--uitest-select-eraser"])
        canvas = openNotebook(erasingApp, titled: title)
        waitForStrokes(1, on: canvas, message: "the drawn stroke should have been saved")
        drag(on: canvas, from: gapTop, to: gapBottom)
        waitForAutosave()
        erasingApp.terminate()

        // Reopen and erase the identical spot: there should be nothing left to cut.
        let secondPassApp = launch(["--uitest-select-eraser"])
        canvas = openNotebook(secondPassApp, titled: title)
        waitForStrokes(2, on: canvas, message: "the split should have been saved")
        drag(on: canvas, from: gapTop, to: gapBottom)
        waitForAutosave()
        secondPassApp.terminate()

        let reopenedApp = launch(["--uitest-reset-tool"])
        canvas = openNotebook(reopenedApp, titled: title)
        waitForStrokes(
            2, on: canvas,
            message: "the gap should still be empty — more strokes means the erased ink came back")
    }
}
