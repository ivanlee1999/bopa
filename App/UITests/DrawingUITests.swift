import XCTest

/// The one thing unit tests cannot prove: that touch input actually produces ink on the
/// PKCanvasView. XCUITest synthesizes events through the system event path (unlike raw HID
/// injection, which PencilKit ignores), so a passing drag here verifies the live canvas.
final class DrawingUITests: XCTestCase {

    @MainActor
    func testFingerDragProducesStroke() throws {
        let app = XCUIApplication()
        app.launch()

        // Create a notebook (or reuse the existing test one).
        let title = "UITest \(Int.random(in: 1000...9999))"
        app.buttons["library.add"].tap()
        let textField = app.textFields.firstMatch
        XCTAssertTrue(textField.waitForExistence(timeout: 5))
        textField.typeText(title)
        app.buttons["Create"].tap()

        // Open it.
        let row = app.staticTexts[title]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()

        let canvas = app.descendants(matching: .any)["editor.canvas"].firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 5), "canvas should appear")
        XCTAssertEqual(canvas.value as? String, "strokes:0")

        // Draw a diagonal-down squiggle (not horizontal, to avoid any nav-gesture ambiguity).
        let start = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.30))
        let end = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.55))
        start.press(forDuration: 0.05, thenDragTo: end)

        // The accessibilityValue updates in canvasViewDrawingDidChange (stroke end).
        let drew = NSPredicate(format: "value == 'strokes:1'")
        let result = XCTWaiter().wait(
            for: [expectation(for: drew, evaluatedWith: canvas)], timeout: 5)
        XCTAssertEqual(result, .completed,
                       "expected 1 stroke after drag, canvas value = \(canvas.value ?? "nil")")

        // Second stroke for good measure.
        let start2 = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.30))
        let end2 = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: 0.55))
        start2.press(forDuration: 0.05, thenDragTo: end2)

        let drewTwo = NSPredicate(format: "value == 'strokes:2'")
        let result2 = XCTWaiter().wait(
            for: [expectation(for: drewTwo, evaluatedWith: canvas)], timeout: 5)
        XCTAssertEqual(result2, .completed,
                       "expected 2 strokes, canvas value = \(canvas.value ?? "nil")")
    }
}
