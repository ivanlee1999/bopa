import XCTest

/// The iPad is used both ways round — flat on a desk in landscape, held like a pad in
/// portrait — and pages are often turned mid-note. These cover what unit tests cannot: that
/// the live canvas still takes ink, and keeps the ink it has, across a real rotation.
final class RotationUITests: XCTestCase {

    @MainActor
    override func tearDown() async throws {
        XCUIDevice.shared.orientation = .portrait
    }

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

    @MainActor
    private func drawStroke(on canvas: XCUIElement, from: CGVector, to: CGVector) {
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
            for: [expectation(for: predicate, evaluatedWith: canvas)], timeout: 10)
        XCTAssertEqual(
            result, .completed,
            "\(message), canvas value = \(canvas.value ?? "nil")",
            file: file, line: line)
    }

    @MainActor
    private func rotate(to orientation: UIDeviceOrientation, _ app: XCUIApplication) {
        XCUIDevice.shared.orientation = orientation
        // The rotation animation and the relayout it triggers are not synchronous with the
        // orientation setter.
        _ = app.descendants(matching: .any)["editor.canvas"].firstMatch
            .waitForExistence(timeout: 5)
    }

    @MainActor
    func testCanvasKeepsInkingThroughRotationInBothDirections() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-reset-tool"]
        app.launch()

        let canvas = openFreshNotebook(app)
        XCTAssertEqual(canvas.value as? String, "strokes:0")

        drawStroke(on: canvas, from: CGVector(dx: 0.35, dy: 0.30), to: CGVector(dx: 0.45, dy: 0.55))
        waitForStrokes(1, on: canvas, message: "expected 1 stroke in portrait")

        rotate(to: .landscapeLeft, app)
        waitForStrokes(1, on: canvas, message: "rotating must not lose the drawing")
        drawStroke(on: canvas, from: CGVector(dx: 0.30, dy: 0.30), to: CGVector(dx: 0.40, dy: 0.55))
        waitForStrokes(2, on: canvas, message: "expected the canvas to still ink in landscape")

        rotate(to: .portrait, app)
        waitForStrokes(2, on: canvas, message: "rotating back must not lose the drawing")
        drawStroke(on: canvas, from: CGVector(dx: 0.55, dy: 0.30), to: CGVector(dx: 0.50, dy: 0.55))
        waitForStrokes(3, on: canvas, message: "expected the canvas to still ink back in portrait")
    }
}
