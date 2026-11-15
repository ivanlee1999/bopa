import XCTest

/// Library controls must remain discoverable without a long press. Screenshots are
/// retained with the test results for reviewing the library, pages and settings together.
final class LibraryUITests: XCTestCase {
    @MainActor
    func testFlowTypingSurvivesRelaunchAndStartsAnotherThought() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-editor.prefersTyping", "YES"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        let write = app.buttons["Write"]
        XCTAssertTrue(write.waitForExistence(timeout: 8))
        write.tap()
        let input = app.textViews["editor.flowText"].firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 8))
        let source = "A flowing thought \(Int.random(in: 10000...99999))\n\nA second paragraph"
        input.tap(); input.typeText(source)
        capture("flow-typing-portrait", app: app)
        for id in ["editor.title", "editor.inputSurface", "editor.tags", "editor.pages"] {
            let control = app.buttons[id]
            XCTAssertGreaterThanOrEqual(control.frame.width, 44)
            XCTAssertTrue(app.windows.firstMatch.frame.contains(control.frame), "\(id) must fit the phone header")
            XCTAssertTrue(control.isHittable)
        }
        XCTAssertTrue(app.buttons["New thought"].firstMatch.isHittable)
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertEqual(input.value as? String, source)
        capture("flow-typing-wide-workspace", app: app)
        XCUIDevice.shared.orientation = .portrait
        // Leave immediately, before the debounce; lifecycle flushing must keep both paragraphs.
        XCUIDevice.shared.press(.home)
        app.terminate(); app.launch()
        if !app.descendants(matching: .any)["library.sidebar"].exists { app.buttons["Browse"].tap() }
        let recent = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'sidebar.recent.'")).firstMatch
        XCTAssertTrue(recent.waitForExistence(timeout: 8)); recent.tap()
        XCTAssertTrue(input.waitForExistence(timeout: 8))
        XCTAssertEqual(input.value as? String, source)
        app.buttons["New thought"].firstMatch.tap()
        XCTAssertTrue(input.waitForExistence(timeout: 8))
        XCTAssertEqual(input.value as? String, "")
        app.buttons["editor.inputSurface"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["editor.canvas"].firstMatch.waitForExistence(timeout: 8))
        app.buttons["editor.close"].tap()
    }

    @MainActor
    private func capture(_ name: String, app: XCUIApplication) {
        // Capture the display: application screenshots can crop using stale portrait bounds
        // during iPad rotation, even after the scene has adopted landscape geometry.
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Layout now lives in the library's options menu rather than on a control of its own, so
    /// choosing it is two taps — the gear, then the option.
    @MainActor
    private func selectLayout(_ shape: String, app: XCUIApplication) {
        let options = app.buttons["library.options"]
        XCTAssertTrue(options.waitForExistence(timeout: 5))
        options.tap()
        let option = app.buttons[shape]
        XCTAssertTrue(option.waitForExistence(timeout: 5))
        option.tap()
    }

    @MainActor
    func testReadingFeedScrollsAllFourPagesAndOpensTheTappedPage() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-reset-tool", "-editor.prefersTyping", "YES"]
        app.launch()
        if !app.buttons["sidebar.library"].exists, app.buttons["Browse"].exists {
            app.buttons["Browse"].tap()
        }
        app.openLibraryForTests()

        let suffix = String(UUID().uuidString.prefix(6)), title = "Reading four pages \(suffix)"
        app.buttons["library.add"].tap()
        let name = app.textFields["newNotebook.title"]
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText(title)
        app.buttons["newNotebook.create"].tap()
        // Keep retained notebooks from earlier runs out of this scrolling fixture.
        let search = app.textFields["library.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText(title)
        let edit = app.buttons["Edit \(title)"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5)); edit.tap()
        let input = app.textViews["editor.flowText"].firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 5))

        func waitValue(_ value: String, on element: XCUIElement) {
            XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: NSPredicate(format: "value == %@", value),
                evaluatedWith: element)], timeout: 6), .completed)
        }
        let starts = (1...4).map { "Reading page \($0) start \(suffix)" }
        let ends = (1...4).map { "Reading page \($0) end \(suffix)" }
        let sources = (0..<4).map { page in
            ([starts[page]] + (1...14).map { "Page \(page + 1) line \($0)" } + [ends[page]]).joined(separator: "\n")
        }
        for page in 0..<4 {
            if page > 0 {
                let done = app.buttons["Done"].firstMatch
                if done.exists { done.tap() }
                app.buttons["editor.options"].tap()
                let add = app.buttons["editor.addPageMenu"]
                XCTAssertTrue(add.waitForExistence(timeout: 5)); add.tap()
                waitValue("Page \(page + 1) of \(page + 1)", on: app.buttons["editor.pages"])
                waitValue("", on: input)
            }
            XCTAssertTrue(input.isHittable); input.tap(); input.typeText(sources[page])
        }
        app.buttons["editor.close"].tap()
        selectLayout("Reading feed", app: app)
        let shelf = app.scrollViews["library.contents"]
        XCTAssertTrue(shelf.waitForExistence(timeout: 5))
        XCTAssertTrue(shelf.staticTexts[starts[0]].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(shelf.staticTexts[starts[0]].firstMatch.isHittable,
                      "Reading starts at the first page even when the editor last showed page four")

        func reveal(_ text: String) -> XCUIElement {
            let line = shelf.staticTexts[text].firstMatch
            for _ in 0..<10 {
                if line.exists && line.isHittable { break }
                shelf.swipeUp()
            }
            XCTAssertTrue(line.exists && line.isHittable, "Reading must expose \(text) by vertical scrolling")
            XCTAssertFalse(app.buttons["editor.close"].isHittable, "Browsing must not enter the editor")
            return line
        }
        for page in 0..<4 {
            _ = reveal(starts[page])
            _ = reveal(ends[page])
        }
        capture("reading-feed-fourth-page-after-vertical-scroll", app: app)
        shelf.staticTexts[ends[3]].firstMatch.tap()
        XCTAssertTrue(app.buttons["editor.pages"].waitForExistence(timeout: 5))
        waitValue("Page 4 of 4", on: app.buttons["editor.pages"])
        waitValue(sources[3], on: input)
        capture("reading-feed-tapped-page-four-opens-in-editor", app: app)
        app.buttons["editor.close"].tap()
    }

    @MainActor
    func testLibraryViewPagesAndSettingsHaveVisibleActions() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-reset-tool", "-navigator.tab", "pages"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        app.openLibraryForTests()
        defer { XCUIDevice.shared.orientation = .portrait }

        let title = "Field notes \(Int.random(in: 10000...99999))"
        let addNotebook = app.buttons["library.add"]
        XCTAssertTrue(addNotebook.waitForExistence(timeout: 5))
        // Set this through the actual control: launch-argument defaults override later
        // UserDefaults writes and would prevent the Grid/List preference from changing.
        selectLayout("2 × 2", app: app)
        addNotebook.tap()
        let name = app.textFields["newNotebook.title"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText(title)
        XCTAssertTrue(app.descendants(matching: .any)["newNotebook.paper"].firstMatch.exists)
        capture("new-notebook-paper", app: app)
        app.buttons["newNotebook.create"].tap()

        let shelf = app.descendants(matching: .any)["library.contents"]
        XCTAssertTrue(shelf.staticTexts[title].waitForExistence(timeout: 5))
        capture("library-grid-portrait", app: app)
        selectLayout("Compact list", app: app)
        XCTAssertEqual(app.buttons["library.options"].value as? String, "List")
        XCTAssertTrue(shelf.staticTexts[title].isHittable)
        capture("library-list-portrait", app: app)

        shelf.buttons["Edit \(title)"].tap()
        XCTAssertTrue(app.buttons["editor.pages"].waitForExistence(timeout: 5))
        app.buttons["editor.pages"].tap()
        let done = app.buttons["pageOverview.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["pages.add"].exists)
        let pageOptions = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "pageOverview.options.")).firstMatch
        XCTAssertTrue(pageOptions.isHittable)
        capture("page-overview", app: app)
        done.tap()
        app.buttons["editor.close"].tap()

        XCTAssertTrue(app.buttons["library.options"].waitForExistence(timeout: 5))
        app.buttons["library.options"].tap()
        app.buttons["library.settings"].tap()
        let settingsDone = app.buttons["settings.done"]
        XCTAssertTrue(settingsDone.waitForExistence(timeout: 5))
        capture("settings", app: app)
        settingsDone.tap()
        XCTAssertTrue(addNotebook.waitForExistence(timeout: 5))

        XCUIDevice.shared.orientation = .landscapeLeft
        let landscape = NSPredicate { _, _ in
            app.windows.firstMatch.frame.width > app.windows.firstMatch.frame.height
        }
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: landscape, evaluatedWith: app)], timeout: 5), .completed)
        XCTAssertTrue(addNotebook.isHittable)
        capture("library-list-landscape", app: app)
    }
}

// Existing ink tests use the optional Library, while the app opens into Today.
extension XCUIApplication {
    func openLibraryForTests() {
        let root = buttons["sidebar.library"]
        if root.waitForExistence(timeout: 5) { root.tap() }
        let options = buttons["library.options"]
        if options.waitForExistence(timeout: 5) {
            options.tap()
            buttons["Compact list"].tap()
        }
    }
}
