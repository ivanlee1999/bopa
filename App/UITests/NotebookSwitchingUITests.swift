import XCTest

/// Exercise the presentation boundary as well as the store: a new notebook must not inherit
/// the previous editor's StateObject, drawing, page selection or undo manager.
final class NotebookSwitchingUITests: XCTestCase {
    @MainActor
    private func create(_ title: String, in app: XCUIApplication) {
        app.buttons["library.add"].tap()
        let field = app.textFields["newNotebook.title"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(title)
        app.buttons["newNotebook.create"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["library.contents"].staticTexts[title]
            .waitForExistence(timeout: 5))
    }

    @MainActor
    private func canvas(_ app: XCUIApplication) -> XCUIElement {
        let element = app.descendants(matching: .any)["editor.canvas"].firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        return element
    }

    @MainActor
    private func waitForValue(_ value: String, on element: XCUIElement) {
        XCTAssertEqual(XCTWaiter().wait(for: [expectation(
            for: NSPredicate(format: "value == %@", value), evaluatedWith: element)], timeout: 8), .completed)
    }

    @MainActor
    private func draw(in app: XCUIApplication) {
        let element = canvas(app)
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.3))
            .press(forDuration: 0.05, thenDragTo: element.coordinate(
                withNormalizedOffset: CGVector(dx: 0.4, dy: 0.5)))
    }

    @MainActor
    private func switchTo(_ title: String, in app: XCUIApplication) {
        app.buttons["editor.notebooks"].tap()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'switcher.notebook.'"))
            .containing(.staticText, identifier: title).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        waitForValue(title, on: app.buttons["editor.notebooks"])
    }

    @MainActor
    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testRepeatedNotebookSwitchesKeepInkPagePositionAndUndoSeparate() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-reset-tool", "-handwriting.pageNavigation", "paged",
                               "-handwriting.fingerDrawing", "true"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        let suffix = UUID().uuidString.prefix(6)
        let a = "Switch A \(suffix)"
        let b = "Switch B \(suffix)"
        create(a, in: app)
        create(b, in: app)
        app.descendants(matching: .any)["library.contents"].staticTexts[a].tap()
        draw(in: app)
        waitForValue("strokes:1", on: canvas(app))
        app.buttons["Add page"].tap()
        waitForValue("Page 2 of 2", on: app.buttons["editor.pages"])
        draw(in: app)
        waitForValue("strokes:1", on: canvas(app))
        switchTo(b, in: app)
        waitForValue("strokes:0", on: canvas(app))
        XCTAssertFalse(app.buttons["editor.undo"].isEnabled)
        draw(in: app)
        waitForValue("strokes:1", on: canvas(app))
        app.buttons["editor.undo"].tap()
        waitForValue("strokes:0", on: canvas(app))
        app.buttons["editor.redo"].tap()
        waitForValue("strokes:1", on: canvas(app))

        for _ in 0..<2 {
            switchTo(a, in: app)
            waitForValue("Page 2 of 2", on: app.buttons["editor.pages"])
            waitForValue("strokes:1", on: canvas(app))
            XCTAssertFalse(app.buttons["editor.undo"].isEnabled)
            switchTo(b, in: app)
            waitForValue("Page 1 of 1", on: app.buttons["editor.pages"])
            waitForValue("strokes:1", on: canvas(app))
        }
        app.buttons["editor.notebooks"].tap()
        screenshot("notebook-switcher-portrait")
        app.buttons["Cancel"].tap()
        waitForValue(b, on: app.buttons["editor.notebooks"])
        XCUIDevice.shared.press(.home)
        app.activate()
        waitForValue("strokes:1", on: canvas(app))
        screenshot("editor-after-interruption")
        app.buttons["editor.close"].tap()
        let sidebar = app.descendants(matching: .any)["library.sidebar"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
        let recent = sidebar.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'sidebar.recent.'"))
        XCTAssertTrue(recent.containing(.staticText, identifier: a).firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(recent.containing(.staticText, identifier: b).firstMatch.exists)
        screenshot("library-recent-notebooks")
        app.terminate()
        app.launch()
        let resumed = app.descendants(matching: .any)["library.sidebar"].buttons
            .matching(NSPredicate(format: "identifier BEGINSWITH 'sidebar.recent.'"))
            .containing(.staticText, identifier: a).firstMatch
        XCTAssertTrue(resumed.waitForExistence(timeout: 5))
        resumed.tap()
        waitForValue("Page 2 of 2", on: app.buttons["editor.pages"])
        waitForValue("strokes:1", on: canvas(app))
    }

    @MainActor
    func testAnEraserGestureOverEmptyPaperDoesNotBlockClosing() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-select-eraser", "-handwriting.fingerDrawing", "true"]
        app.launch()
        let title = "Empty erase \(UUID().uuidString.prefix(6))"
        create(title, in: app)
        app.descendants(matching: .any)["library.contents"].staticTexts[title].tap()
        draw(in: app)
        waitForValue("strokes:0", on: canvas(app))
        app.buttons["editor.close"].tap()
        XCTAssertTrue(app.buttons["library.add"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testClosingAnActiveTextBoxCommitsBeforeDismissingTheNotebook() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-select-text"]
        app.launch()
        let title = "Active text \(UUID().uuidString.prefix(6))"
        create(title, in: app)
        app.descendants(matching: .any)["library.contents"].staticTexts[title].tap()
        canvas(app).coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.3)).tap()
        let text = app.textViews.firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        text.typeText("Keep this unfinished paragraph")
        app.buttons["editor.close"].tap()
        XCTAssertTrue(app.buttons["library.add"].waitForExistence(timeout: 5))
        app.terminate()
        app.launch()
        app.descendants(matching: .any)["library.contents"].staticTexts[title].tap()
        canvas(app).coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.3)).tap()
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        XCTAssertEqual(text.value as? String, "Keep this unfinished paragraph")
    }
}
