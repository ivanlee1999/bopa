import NotableKit
import XCTest

@testable import Bopa

final class HandwritingSettingsTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suiteName = "bopa-handwriting-test-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testDefaultsMatchCurrentBehaviour() {
        let config = HandwritingConfig.load(from: defaults)

        // The out-of-the-box canvas: finger inks, page scrolls, fit width, and the tools
        // come from the docked rail (the only tool UI there is).
        XCTAssertTrue(config.fingerDrawing)
        XCTAssertFalse(config.scrollLocked)
        XCTAssertEqual(config.pageFit, .fitWidth)
        XCTAssertEqual(config.doubleTapAction, .system)
        XCTAssertEqual(config.squeezeAction, .system)
        XCTAssertEqual(config.defaultTemplate, .blank)
    }

    func testRoundTripsThroughUserDefaults() {
        var config = HandwritingConfig()
        config.fingerDrawing = false
        config.scrollLocked = true
        config.pageFit = .actualSize
        config.doubleTapAction = .eraser
        config.squeezeAction = .undo
        config.defaultTemplate = .dotted
        config.save(to: defaults)

        XCTAssertEqual(HandwritingConfig.load(from: defaults), config)
    }

    /// A `false` toggle must survive a reload — the reason loading goes through
    /// `object(forKey:)` rather than `bool(forKey:)`.
    func testStoredFalseIsNotMistakenForMissing() {
        var config = HandwritingConfig()
        config.fingerDrawing = false
        config.save(to: defaults)

        XCTAssertFalse(HandwritingConfig.load(from: defaults).fingerDrawing)
    }

    func testStringBackedBooleansFromArgumentDomainAreAccepted() {
        defaults.set("false", forKey: HandwritingConfig.Key.fingerDrawing)
        defaults.set("true", forKey: HandwritingConfig.Key.scrollLocked)

        let config = HandwritingConfig.load(from: defaults)

        XCTAssertFalse(config.fingerDrawing)
        XCTAssertTrue(config.scrollLocked)
    }

    func testUnknownStoredValuesFallBackToDefaults() {
        defaults.set("sparkles", forKey: HandwritingConfig.Key.defaultTemplate)
        defaults.set("teleport", forKey: HandwritingConfig.Key.doubleTapAction)

        let config = HandwritingConfig.load(from: defaults)
        XCTAssertEqual(config.defaultTemplate, .blank)
        XCTAssertEqual(config.doubleTapAction, .system)
    }

    /// The page fit outgrew its "zoom on open" name but kept its defaults key, so anyone who
    /// had already chosen "actual size" keeps it instead of being silently re-fitted.
    func testPageFitStillReadsTheOriginalDefaultsKey() {
        defaults.set("actualSize", forKey: "handwriting.zoomOnOpen")

        XCTAssertEqual(HandwritingConfig.load(from: defaults).pageFit, .actualSize)
    }

    /// A pencil gesture set to the retired "Show/hide tool palette" must not fall back to
    /// `.system` — that would hand the gesture to the system-wide Apple Pencil preference,
    /// which is exactly what choosing an action overrode.
    func testRetiredPencilActionLoadsAsDoNothing() {
        defaults.set("toggleToolPicker", forKey: HandwritingConfig.Key.doubleTapAction)
        defaults.set("toggleToolPicker", forKey: HandwritingConfig.Key.squeezeAction)

        let config = HandwritingConfig.load(from: defaults)
        XCTAssertEqual(config.doubleTapAction, .ignore)
        XCTAssertEqual(config.squeezeAction, .ignore)
    }

    @MainActor
    func testSettingsObjectPersistsOnMutation() {
        let settings = HandwritingSettings(defaults: defaults)
        settings.config.fingerDrawing = false
        settings.config.defaultTemplate = .lined

        let reloaded = HandwritingSettings(defaults: defaults)
        XCTAssertFalse(reloaded.config.fingerDrawing)
        XCTAssertEqual(reloaded.config.defaultTemplate, .lined)
    }

    /// NotableKit's `NativeTemplate` preserves an unrecognized stored name as `.custom` rather
    /// than folding it to blank; `HandwritingConfig` is the layer that refuses to pick an
    /// undrawable template as the app default (see `testUnknownStoredValuesFallBackToDefaults`).
    func testDefaultTemplateOnlyEverPicksADrawableBuiltIn() {
        XCTAssertEqual(
            NativeTemplate.builtIn.map(\.name),
            ["blank", "dotted", "lined", "squared", "hexed"])
        for template in NativeTemplate.builtIn {
            XCTAssertTrue(template.isDrawable)
        }
        XCTAssertFalse(NativeTemplate(name: "legalPad").isDrawable)
    }
}
