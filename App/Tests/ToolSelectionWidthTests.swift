import PencilKit
import XCTest

@testable import Bopa

/// Nib width, ink, the highlighter, and the two ways of erasing.
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

    // MARK: The width ramp

    /// Every step has to be visibly broader than the one before it, or the rail is offering a
    /// choice that makes no mark.
    func testTheWidthRampOnlyEverGetsBroader() {
        let selection = makeSelection()
        selection.select(.pen)

        var previous: CGFloat = 0
        for width in ToolSelection.Width.allCases {
            selection.select(width: width)
            let nib = inkingWidth(selection)
            XCTAssertGreaterThan(nib, previous, "\(width.label) is not broader than the step before it")
            previous = nib
        }
    }

    /// The ramp used to start at fine and stop at broad, so annotating printed text and lettering
    /// a title were both off the end of it.
    func testTheRampReachesPastTheOldEnds() {
        XCTAssertLessThan(ToolSelection.Width.hair.scale, ToolSelection.Width.fine.scale)
        XCTAssertGreaterThan(ToolSelection.Width.heavy.scale, ToolSelection.Width.broad.scale)
        XCTAssertEqual(ToolSelection.Width.allCases.count, 5)
    }

    /// The dots stand for the nibs, so they have to rank the same way.
    func testTheDotsRankLikeTheNibs() {
        let dots = ToolSelection.Width.allCases.map(\.dotSize)
        XCTAssertEqual(dots, dots.sorted())
    }

    /// The three original steps are already written to defaults on people's devices. Renaming one
    /// would silently reset the pen it belonged to, so the stored spellings are a contract.
    func testWidthsStoredByTheOldRailStillLoad() {
        defaults.set("broad", forKey: "editor.width.pen")

        XCTAssertEqual(makeSelection().widths[.pen], .broad)
    }

    // MARK: Ink

    func testChoosingAnInkChangesWhatIsWrittenWith() {
        let selection = makeSelection()
        selection.select(.pen)

        selection.select(inkIndex: 8)

        XCTAssertEqual((selection.pkTool as? PKInkingTool)?.color, Modernist.inks[8].uiColor)
    }

    func testAnInkOutsideThePaletteIsIgnored() {
        let selection = makeSelection()
        selection.select(inkIndex: 2)

        selection.select(inkIndex: Modernist.inks.count)

        XCTAssertEqual(selection.inkIndex, 2)
    }

    /// Picking an ink while erasing means "go back to writing with it".
    func testPickingAnInkWhileErasingReturnsToThePen() {
        let selection = makeSelection()
        selection.select(.eraser)

        selection.select(inkIndex: 6)

        XCTAssertEqual(selection.kind, .pen)
        XCTAssertEqual(selection.inkIndex, 6)
    }

    /// A colour that reset to black on every launch would not be a choice, only a detour — the
    /// widths have survived a relaunch since they existed and the ink did not.
    func testInkSurvivesRelaunch() {
        let first = makeSelection()
        first.select(inkIndex: 10)

        XCTAssertEqual(makeSelection().inkIndex, 10)
    }

    /// A palette shrunk below a stored index must not strand the rail on an ink that is gone.
    func testAStoredInkBeyondThePaletteFallsBackToTheFirst() {
        defaults.set(Modernist.inks.count + 3, forKey: "editor.ink")

        XCTAssertEqual(makeSelection().inkIndex, 0)
    }

    /// Ids are what the rail selects by and what `inkIndex(matching:)` hands back, so they have to
    /// stay the positions in the array — and every colour has to be far enough from every other
    /// for that lookup to name it.
    func testEveryInkIsItsOwnColour() {
        XCTAssertGreaterThanOrEqual(Modernist.inks.count, 12)
        for (index, ink) in Modernist.inks.enumerated() {
            XCTAssertEqual(ink.id, index)
            XCTAssertEqual(
                Modernist.inkIndex(matching: ink.uiColor), ink.id,
                "\(ink.name) is not distinguishable from an earlier ink")
        }
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
