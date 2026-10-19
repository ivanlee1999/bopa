import XCTest

/// Exercise the presentation boundary as well as the store: a new notebook must not inherit
/// the previous editor's StateObject, drawing, page selection or undo manager.
final class NotebookSwitchingUITests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        // A failed navigation precondition makes later taps target the wrong screen.
        // Stop that test at its first failure rather than cascading long UI timeouts.
        continueAfterFailure = false
    }

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
    private func assertEditorFits(_ app: XCUIApplication, landscape: Bool) {
        let window = app.windows.firstMatch
        let rotated = NSPredicate { _, _ in
            let frame = window.frame
            return landscape ? frame.width > frame.height : frame.height > frame.width
        }
        XCTAssertEqual(XCTWaiter().wait(for: [expectation(
            for: rotated, evaluatedWith: window)], timeout: 8), .completed)
        for id in ["editor.close", "editor.notebooks", "editor.pages"] {
            let control = app.buttons[id]
            XCTAssertGreaterThanOrEqual(control.frame.width, 44, "\(id) needs a full touch target")
            XCTAssertGreaterThanOrEqual(control.frame.height, 44, "\(id) needs a full touch target")
            XCTAssertTrue(control.isHittable, "\(id) must stay reachable after rotation")
            XCTAssertTrue(window.frame.contains(control.frame), "\(id) must stay inside the window")
        }
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
        let alternate = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'switcher.notebook.'"))
            .containing(.staticText, identifier: a).firstMatch
        XCTAssertEqual(XCTWaiter().wait(for: [expectation(for: NSPredicate { _, _ in
            alternate.exists && alternate.isHittable && !alternate.frame.isEmpty
                && app.windows.firstMatch.frame.contains(alternate.frame)
        }, evaluatedWith: alternate)], timeout: 8), .completed)
        screenshot("notebook-switcher-portrait")
        app.buttons["Cancel"].tap()
        waitForValue(b, on: app.buttons["editor.notebooks"])
        XCUIDevice.shared.orientation = .landscapeLeft
        assertEditorFits(app, landscape: true)
        waitForValue("strokes:1", on: canvas(app))
        screenshot("editor-landscape")
        XCUIDevice.shared.orientation = .portrait
        assertEditorFits(app, landscape: false)
        XCUIDevice.shared.press(.home)
        app.activate()
        waitForValue("strokes:1", on: canvas(app))
        screenshot("editor-after-interruption")
        app.buttons["editor.close"].tap()
        let sidebar = app.descendants(matching: .any)["library.sidebar"]
        if !sidebar.exists { app.buttons["library.toggleSidebar"].tap() }
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
        let recent = sidebar.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'sidebar.recent.'"))
        XCTAssertTrue(recent.containing(.staticText, identifier: a).firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(recent.containing(.staticText, identifier: b).firstMatch.exists)
        screenshot("library-recent-notebooks")
        app.terminate()
        app.launch()
        if !app.descendants(matching: .any)["library.sidebar"].exists {
            app.buttons["library.toggleSidebar"].tap()
        }
        let resumed = app.descendants(matching: .any)["library.sidebar"].buttons
            .matching(NSPredicate(format: "identifier BEGINSWITH 'sidebar.recent.'"))
            .containing(.staticText, identifier: a).firstMatch
        XCTAssertTrue(resumed.waitForExistence(timeout: 5))
        resumed.tap()
        waitForValue("Page 2 of 2", on: app.buttons["editor.pages"])
        waitForValue("strokes:1", on: canvas(app))
    }

    @MainActor
    func testWritingControlsStayDiscoverableAndPageActionsDoNotDuplicate() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-reset-tool", "-handwriting.pageNavigation", "paged"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        let title = "Writing workspace \(UUID().uuidString.prefix(6))"
        create(title, in: app)
        app.descendants(matching: .any)["library.contents"].staticTexts[title].tap()
        let forward = app.buttons["editor.forwardPage"]
        XCTAssertTrue(forward.waitForExistence(timeout: 5))
        XCTAssertEqual(forward.label, "Add page")
        forward.tap()
        waitForValue("Page 2 of 2", on: app.buttons["editor.pages"])
        app.buttons["Previous page"].tap()
        waitForValue("Page 1 of 2", on: app.buttons["editor.pages"])
        XCTAssertEqual(forward.label, "Next page")
        forward.tap()
        waitForValue("Page 2 of 2", on: app.buttons["editor.pages"])
        app.buttons["Previous page"].tap()
        waitForValue("Page 1 of 2", on: app.buttons["editor.pages"])
        app.buttons["editor.options"].tap()
        let menuAdd = app.buttons["editor.addPageMenu"]
        XCTAssertTrue(menuAdd.waitForExistence(timeout: 5))
        // UIKit's menu accessibility can expose a visible row but no computed hit point.
        // Tap the observed row's center, then verify the actual page-creation result.
        XCTAssertGreaterThan(menuAdd.frame.width, 0)
        XCTAssertGreaterThan(menuAdd.frame.height, 0)
        XCTAssertTrue(app.windows.firstMatch.frame.contains(menuAdd.frame))
        menuAdd.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        waitForValue("Page 3 of 3", on: app.buttons["editor.pages"])

        for id in ["editor.tool.eraser", "editor.tool.lasso", "editor.tool.text", "editor.ink"] {
            let button = app.buttons[id]
            XCTAssertTrue(button.isHittable, "essential tools must not require a hidden scroll")
            XCTAssertGreaterThanOrEqual(button.frame.width, 44)
            XCTAssertGreaterThanOrEqual(button.frame.height, 44)
        }
        if app.buttons["editor.tools"].exists {
            app.buttons["editor.tools"].tap()
            XCTAssertTrue(app.buttons["editor.tool.pencil"].waitForExistence(timeout: 5))
            app.buttons["editor.tool.pencil"].tap()
            app.buttons["editor.width.fine"].tap()
            screenshot("compact-writing-settings")
            app.buttons["Done"].tap()
            XCTAssertTrue(app.buttons["editor.tools"].isHittable)
            app.buttons["editor.tool.eraser"].tap()
            app.buttons["editor.tools"].tap()
            XCTAssertEqual(app.buttons["editor.tools"].value as? String, "Pencil, Fine")
            XCTAssertFalse(app.buttons["editor.width.fine"].exists, "returning to writing is one tap")
        }
        assertEditorFits(app, landscape: false)
        screenshot("calm-writing-workspace")
    }

    @MainActor
    func testAccessibilityTextSizeKeepsNotebookAndPageControlsReachable() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-reset-tool", "-UIPreferredContentSizeCategoryName",
                               "UICTContentSizeCategoryAccessibilityXXXL"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        let title = "Large text notebook \(UUID().uuidString.prefix(6))"
        create(title, in: app)
        app.descendants(matching: .any)["library.contents"].staticTexts[title].tap()
        XCTAssertTrue(app.buttons["editor.pages"].waitForExistence(timeout: 5))
        assertEditorFits(app, landscape: false)
        XCTAssertFalse(app.buttons["editor.notebooks"].frame.intersects(app.buttons["editor.pages"].frame))
        screenshot("writing-accessibility-text")
        if app.buttons["editor.tools"].exists {
            app.buttons["editor.tools"].tap()
            XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["Done"].isHittable)
            XCTAssertTrue(app.buttons["editor.tool.pencil"].isHittable)
            let widths = app.buttons["editor.width.fine"]
            if !widths.isHittable { app.scrollViews["editor.strokeSettings"].swipeUp() }
            XCTAssertTrue(widths.isHittable)
            widths.tap()
            screenshot("writing-settings-accessibility-text")
            app.buttons["Done"].tap()
        }
        app.buttons["editor.forwardPage"].tap()
        waitForValue("Page 2 of 2", on: app.buttons["editor.pages"])
        app.buttons["editor.close"].tap()
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
        let text = app.textViews["editor.textbox.input"]
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        text.typeText("Keep this unfinished paragraph")
        app.buttons["editor.close"].tap()
        XCTAssertTrue(app.buttons["library.add"].waitForExistence(timeout: 5))
        app.terminate()
        app.launch()
        app.descendants(matching: .any)["library.contents"].staticTexts[title].tap()
        // Creation rounds page coordinates; tap inside the saved box, not its top-left edge.
        canvas(app).coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.3))
            .withOffset(CGVector(dx: 4, dy: 4)).tap()
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        waitForValue("Keep this unfinished paragraph", on: app.textViews["editor.textbox.input"])
    }

    @MainActor
    func testActiveTextSurvivesNotebookSwitchAndBackgroundRelaunch() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-select-text"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        let suffix = UUID().uuidString.prefix(6)
        let a = "Text source \(suffix)"
        let b = "Text destination \(suffix)"
        create(a, in: app)
        create(b, in: app)
        app.descendants(matching: .any)["library.contents"].staticTexts[a].tap()
        canvas(app).coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.3)).tap()
        let text = app.textViews["editor.textbox.input"]
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        text.typeText("Saved by switching")
        switchTo(b, in: app)
        switchTo(a, in: app)
        // Creation rounds page coordinates; tap inside the saved box, not its top-left edge.
        canvas(app).coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.3))
            .withOffset(CGVector(dx: 4, dy: 4)).tap()
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        waitForValue("Saved by switching", on: app.textViews["editor.textbox.input"])
        // Leave this new edit active. Reopening from disk prevents a live text view from
        // making a missing background flush look like successful persistence.
        text.typeText(" background edit ")
        let expected = text.value as? String
        XCTAssertTrue(expected?.contains("background edit") == true)
        XCUIDevice.shared.press(.home)
        if !app.wait(for: .runningBackground, timeout: 5), app.state == .runningForeground {
            // Retry one missed Home event, then still require a verified background state.
            XCUIDevice.shared.press(.home)
        }
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10)
                      || app.state == .runningBackgroundSuspended)
        app.terminate()
        app.launch()
        app.descendants(matching: .any)["library.contents"].staticTexts[a].tap()
        // Creation rounds page coordinates; tap inside the saved box, not its top-left edge.
        canvas(app).coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.3))
            .withOffset(CGVector(dx: 4, dy: 4)).tap()
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        waitForValue(expected ?? "", on: app.textViews["editor.textbox.input"])
    }

}
