import XCTest

/// Library controls must remain discoverable without a long press. Screenshots are
/// retained with the test results for reviewing the library, pages and settings together.
final class LibraryUITests: XCTestCase {
    @MainActor
    private func capture(_ name: String, app: XCUIApplication) {
        // Capture the display: application screenshots can crop using stale portrait bounds
        // during iPad rotation, even after the scene has adopted landscape geometry.
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testLibraryViewPagesAndSettingsHaveVisibleActions() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-reset-tool", "-navigator.tab", "pages"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        defer { XCUIDevice.shared.orientation = .portrait }

        let title = "Field notes \(Int.random(in: 10000...99999))"
        let addNotebook = app.buttons["library.add"]
        XCTAssertTrue(addNotebook.waitForExistence(timeout: 5))
        // Set this through the actual control: launch-argument defaults override later
        // UserDefaults writes and would prevent the Grid/List preference from changing.
        app.buttons["library.view"].tap()
        app.buttons["Grid"].tap()
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
        app.buttons["library.view"].tap()
        app.buttons["List"].tap()
        XCTAssertEqual(app.buttons["library.view"].value as? String, "List")
        XCTAssertTrue(shelf.staticTexts[title].isHittable)
        capture("library-list-portrait", app: app)

        shelf.staticTexts[title].tap()
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
