import PencilKit
import XCTest

@testable import Bopa

/// Nib width, the highlighter, and the two ways of erasing.
///
/// The rail offered one fixed width per tool, no highlighter, and a single eraser mode, so writing
/// small was impossible and taking a whole stroke away had no gesture at all.
@MainActor
final class ToolSelectionWidthTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName = ""

    override func setUp() async throws {
        suiteName = "tool-selection-test-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeSelection() -> ToolSelection { ToolSelection(defaults: defaults) }

    func testWidthScalesTheToolsOwnNib() {
        let selection = makeSelection()
        selection.select(.pen)

        selection.select(width: .fine)
        XCTAssertEqual(inkingWidth(selection), ToolSelection.Kind.pen.baseWidth * 0.5, accuracy: 0.01)

        selection.select(width: .broad)
        XCTAssertEqual(inkingWidth(selection), ToolSelection.Kind.pen.baseWidth * 2, accuracy: 0.01)
    }

    /// A highlighter that came out the width of a pen would not highlight anything, so each
    /// implement keeps its own base and the width scales from that.
    func testEachToolKeepsItsOwnCharacter() {
        let selection = makeSelection()
        selection.select(.marker)
        selection.select(width: .medium)
        let marker = inkingWidth(selection)

        selection.select(.pen)
        selection.select(width: .medium)

        XCTAssertGreaterThan(marker, inkingWidth(selection) * 3)
    }

    /// Switching from a broad marker back to the pen must return to the pen you were writing
    /// with, not to a pen as broad as the marker.
    func testWidthIsRememberedPerTool() {
        let selection = makeSelection()
        selection.select(.pen)
        selection.select(width: .fine)
        selection.select(.marker)
        selection.select(width: .broad)

        selection.select(.pen)

        XCTAssertEqual(selection.width, .fine)
    }

    func testWidthSurvivesRelaunch() {
        let first = makeSelection()
        first.select(.pencil)
        first.select(width: .broad)

        XCTAssertEqual(makeSelection().widths[.pencil], .broad)
    }

    /// Reaching for a width while erasing means nothing rather than something odd.
    func testTheEraserHasNoWidth() {
        let selection = makeSelection()
        selection.select(.eraser)
        selection.select(width: .broad)

        XCTAssertNil(selection.widths[.eraser])
        XCTAssertTrue(selection.pkTool is PKEraserTool)
    }

    func testTheHighlighterIsAMarker() {
        let selection = makeSelection()
        selection.select(.marker)

        XCTAssertEqual((selection.pkTool as? PKInkingTool)?.inkType, .marker)
    }

    /// Rubbing out part of a stroke and taking the whole stroke away are different intentions.
    func testEraserModeChoosesTheEraser() {
        let selection = makeSelection()

        selection.select(eraserMode: .stroke)
        XCTAssertEqual((selection.pkTool as? PKEraserTool)?.eraserType, .vector)

        selection.select(eraserMode: .pixel)
        XCTAssertEqual((selection.pkTool as? PKEraserTool)?.eraserType, .bitmap)
    }

    /// Choosing how to erase means "erase", the same way choosing an ink means "write".
    func testChoosingAnEraserModeSelectsTheEraser() {
        let selection = makeSelection()
        selection.select(.pen)

        selection.select(eraserMode: .stroke)

        XCTAssertEqual(selection.kind, .eraser)
    }

    func testEraserModeSurvivesRelaunch() {
        let first = makeSelection()
        first.select(eraserMode: .stroke)

        XCTAssertEqual(makeSelection().eraserMode, .stroke)
    }

    /// A marker chosen by an Apple Pencil gesture has to land on the rail as the highlighter,
    /// not be quietly dropped.
    func testAdoptingAMarkerShowsTheHighlighter() {
        let selection = makeSelection()

        selection.adopt(PKInkingTool(.marker, color: .black, width: 24))

        XCTAssertEqual(selection.kind, .marker)
    }

    private func inkingWidth(_ selection: ToolSelection) -> CGFloat {
        (selection.pkTool as? PKInkingTool)?.width ?? 0
    }
}
