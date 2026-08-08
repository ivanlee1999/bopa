import XCTest

/// Regression tests for PencilKit inking, kept from the bisect that found two canvas
/// invariants (see EditorCanvasView.updateUIView). The bare canvas is the control; the
/// editor-canvas cases guard the real editor wrapper, with and without NavigationStack.
final class BareCanvasUITests: XCTestCase {

    @MainActor
    func testDragOnBareCanvas() throws {
        try drag(args: ["--bare-canvas"])
    }

    @MainActor
    func testEditorCanvasNoNav() throws {
        try drag(args: ["--bare-canvas", "--bare-editorcanvas"], identifier: "editor.canvas")
    }


    @MainActor
    func testEditorCanvasWithNav() throws {
        try drag(args: ["--bare-canvas", "--bare-editorcanvas", "--bare-nav"], identifier: "editor.canvas")
    }

    @MainActor
    private func drag(args: [String], identifier: String = "bare.canvas") throws {
        let app = XCUIApplication()
        app.launchArguments = args + ["--uitest-reset-tool"]
        app.launch()

        let canvas = app.descendants(matching: .any)[identifier].firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))

        let start = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.3))
        let end = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
        start.press(forDuration: 0.05, thenDragTo: end)

        let drew = NSPredicate(format: "value == 'strokes:1'")
        let result = XCTWaiter().wait(
            for: [expectation(for: drew, evaluatedWith: canvas)], timeout: 5)
        XCTAssertEqual(result, .completed,
                       "canvas after drag: \(canvas.value ?? "nil")")
    }
}
