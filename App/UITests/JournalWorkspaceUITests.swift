import XCTest

final class JournalWorkspaceUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    @MainActor private func waitValue(_ value: String, _ element: XCUIElement) {
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: NSPredicate(format: "value == %@", value), evaluatedWith: element)], timeout: 6), .completed)
    }
    @MainActor private func rename(_ app: XCUIApplication, suffix: String) -> String {
        let field = app.textFields["rename.title"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText(suffix)
        let result = (field.value as? String ?? suffix).trimmingCharacters(in: .whitespacesAndNewlines)
        app.buttons["rename.save"].tap()
        return result
    }
    @MainActor private func launch() -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-reset-tool", "-editor.prefersTyping", "YES", "-library.layout", "feed"]
        app.launch(); return app
    }

    @MainActor
    func testCalendarKeepsTheStreamAndRepeatedTodayJumpsAndTitlesRename() {
        let app = launch()
        XCTAssertTrue(app.buttons["Write"].waitForExistence(timeout: 8)); app.buttons["Write"].tap()
        let input = app.textViews["editor.flowText"].firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 5)); input.tap()
        input.typeText((0..<55).map { "Journal line \($0)" }.joined(separator: "\n"))
        app.buttons["editor.title"].tap()
        let title = rename(app, suffix: " Calendar \(Int.random(in: 1000...9999))")
        app.buttons["editor.options"].tap(); app.buttons["Rename page"].tap()
        _ = rename(app, suffix: "Opening thought")
        app.buttons["editor.options"].tap(); app.buttons["Rename page"].tap()
        XCTAssertEqual(app.textFields["rename.title"].value as? String, "Opening thought")
        app.buttons["Cancel"].tap(); app.buttons["editor.close"].tap()

        let timeline = app.scrollViews["journal.timeline"]
        XCTAssertTrue(timeline.waitForExistence(timeout: 5))
        app.buttons["Expand"].firstMatch.tap()
        app.buttons["journal.calendar"].tap()
        XCTAssertTrue(app.buttons["Choose month and year"].waitForExistence(timeout: 5))
        app.buttons["Choose month and year"].tap()
        XCTAssertTrue(app.buttons["Go"].waitForExistence(timeout: 5)); app.buttons["Cancel"].tap()
        let day = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'journal.day.' AND label ENDSWITH ', 0 notes'")).firstMatch
        XCTAssertTrue(day.waitForExistence(timeout: 5)); day.tap()
        // Selection moves in the same stream. The note from today must still be above it.
        capture("calendar-return-to-today-neighbor")
        XCTAssertTrue(app.staticTexts["No notes"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["journal.today"].tap()
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: app.buttons["Rename \(title)"])], timeout: 6), .completed)
        timeline.swipeUp(); timeline.swipeUp()
        app.buttons["journal.today"].tap()
        XCTAssertTrue(app.buttons["Rename \(title)"].waitForExistence(timeout: 5))
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: app.buttons["Rename \(title)"])], timeout: 6), .completed,
                       "Today must jump even when it was already selected")
        capture("continuous-journal-calendar-and-renamed-title")
    }

    @MainActor
    func testPreviewFingerSwipesAndFavoritePensCanBePinnedReorderedAndSelected() {
        let app = launch()
        let library = app.buttons["sidebar.library"]
        if !library.exists { app.buttons["Browse"].tap() }
        XCTAssertTrue(library.waitForExistence(timeout: 5)); library.tap()
        app.buttons["library.add"].tap()
        let title = "Preview \(Int.random(in: 10000...99999))"
        let field = app.textFields["newNotebook.title"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText(title)
        app.buttons["newNotebook.create"].tap()
        let edit = app.buttons["Edit \(title)"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5)); edit.tap()
        let input = app.textViews["editor.flowText"].firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 5)); input.tap(); input.typeText("FIRST PAGE CONTENT")
        let typingDone = app.buttons["Done"].firstMatch
        if typingDone.waitForExistence(timeout: 2) { typingDone.tap() }
        app.buttons["editor.options"].tap()
        let addPage = app.buttons["editor.addPageMenu"]
        XCTAssertTrue(addPage.waitForExistence(timeout: 5)); XCTAssertTrue(addPage.isHittable); addPage.tap()
        waitValue("Page 2 of 2", app.buttons["editor.pages"])
        waitValue("", input)
        XCTAssertTrue(input.isHittable); input.tap(); input.typeText("SECOND PAGE CONTENT")
        app.buttons["editor.inputSurface"].tap()

        let compact = app.buttons["editor.tools"].exists
        if compact { app.buttons["editor.tools"].tap() }
        app.buttons["editor.tool.fountain"].tap(); app.buttons["editor.width.broad"].tap()
        if compact { app.buttons["Done"].firstMatch.tap() }
        app.buttons["editor.ink"].tap(); app.buttons["Blue"].tap()
        if compact {
            app.buttons["editor.tools"].tap(); app.buttons["Edit favorites"].tap()
        } else {
            app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'editor.favorite.'")).firstMatch.press(forDuration: 0.8)
            app.buttons["Edit favorites"].tap()
        }
        let pin = app.buttons["favorite.pin"]
        XCTAssertTrue(pin.waitForExistence(timeout: 5)); if pin.isEnabled { pin.tap() }
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'favorite.row.'"))
        XCTAssertGreaterThanOrEqual(rows.count, 2)
        let first = rows.element(boundBy: 0), last = rows.element(boundBy: rows.count - 1)
        let moved = last.identifier
        let handles = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Reorder'"))
        let start = handles.count >= rows.count ? handles.element(boundBy: handles.count - 1).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)) : last.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5))
        let end = handles.count >= rows.count ? handles.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)) : first.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.1))
        start.press(forDuration: 0.7, thenDragTo: end)
        XCTAssertEqual(rows.firstMatch.identifier, moved)
        capture("favorite-pen-order")
        app.buttons["favorite.done"].tap()
        XCTAssertTrue(app.buttons["favorite.done"].waitForNonExistence(timeout: 5))
        if compact {
            app.buttons["Done"].firstMatch.tap()
            XCTAssertTrue(app.buttons["Done"].firstMatch.waitForNonExistence(timeout: 5))
        }
        if compact { app.buttons["editor.tools"].tap() }
        app.buttons["editor.tool.pen"].tap()
        if compact { app.buttons["Done"].firstMatch.tap() }
        let favorite = app.buttons["Favorite: Fountain pen, Blue, Broad"]
        XCTAssertTrue(favorite.waitForExistence(timeout: 5)); favorite.tap()
        XCTAssertTrue(favorite.isSelected)
        app.buttons["editor.close"].tap()

        let counters = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'preview.pages.'"))
        let counter = counters.firstMatch
        XCTAssertTrue(counter.waitForExistence(timeout: 5)); waitValue("1/2", counter)
        let content = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'preview.content.'")).firstMatch
        XCTAssertTrue(content.waitForExistence(timeout: 5))
        content.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).press(forDuration: 0.05, thenDragTo: content.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)))
        waitValue("2/2", counter)
        XCTAssertTrue(app.staticTexts["SECOND PAGE CONTENT"].waitForExistence(timeout: 5))
        content.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)).press(forDuration: 0.05, thenDragTo: content.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)))
        waitValue("1/2", counter)
        XCTAssertTrue(app.staticTexts["FIRST PAGE CONTENT"].waitForExistence(timeout: 5))
        capture("preview-finger-page-navigation")
        counter.tap()
        XCTAssertTrue(app.buttons["pageOverview.done"].waitForExistence(timeout: 5))
    }
}
