import XCTest
@testable import NotableKit

final class FlowTextTests: XCTestCase {
    private let before = "2026-11-12T09:00:00Z"
    private let now = "2026-11-12T10:00:00Z"
    private func block(_ id: String, _ text: String, key: String = "") -> CouchBlock {
        CouchBlock(id: id, kind: "md", orderKey: key, text: text,
                   createdAt: before, updatedAt: before, deviceId: "boox")
    }
    private func edit(_ base: [CouchBlock], current: [CouchBlock]? = nil, _ source: String) throws -> [CouchBlock] {
        var next = 0
        return try FlowText.replacing(base: base, in: current ?? base, with: source,
            stamp: now, deviceID: "mac", makeID: { next += 1; return "new-\(next)" })
    }

    func testUnchangedBodyKeepsEveryByteAndDoesNotOverwriteRemoteText() throws {
        let original = [block("a", "Original")]
        var remote = original; remote[0].text = "Changed on BOOX"
        XCTAssertEqual(try edit(original, current: remote, "Original"), remote)
    }

    func testTypingKeepsParagraphIdentityAndOrderKeys() throws {
        let base = [block("a", "One", key: "G"), block("b", "Two", key: "V")]
        let result = try edit(base, "One\n\nTwo edited")
        XCTAssertEqual(result.map(\.id), ["a", "b"])
        XCTAssertEqual(result.map(\.orderKey), ["G", "V"])
        XCTAssertEqual(result[0], base[0])
        XCTAssertEqual(result[1].text, "Two edited")
    }

    func testInsertionDoesNotStealTheEditedFollowingParagraphID() throws {
        let base = [block("a", "A"), block("b", "B"), block("c", "C")]
        let result = try edit(base, "New\n\nA\n\nB edited\n\nC")
        XCTAssertEqual(FlowText.ordered(result).map(\.id), ["new-1", "a", "b", "c"])
        XCTAssertEqual(result.first(where: { $0.id == "b" })?.text, "B edited")
    }

    func testReorderingAndDuplicatesKeepStableIDs() throws {
        let base = [block("a", "Same"), block("b", "Same"), block("c", "Last")]
        let result = try edit(base, "Same\n\nLast\n\nSame")
        XCTAssertEqual(FlowText.ordered(result).map(\.id), ["a", "c", "b"])
        XCTAssertEqual(Set(result.map(\.id)), Set(base.map(\.id)))
    }

    func testFixedCanvasAndNonMarkdownBoundariesRemainIntact() throws {
        var positioned = block("canvas", "Annotation"); positioned.x = 25; positioned.y = 50
        let first = block("a", "First", key: "A")
        let image = CouchBlock(id: "image", kind: "image", orderKey: "M", imageAssetId: "asset:photo",
                              createdAt: before, updatedAt: before, deviceId: "boox")
        let last = block("z", "Last", key: "Z")
        let result = try edit([first], current: [positioned, first, image, last], "First\n\nAdded")
        XCTAssertEqual(result.first(where: { $0.id == "canvas" }), positioned)
        XCTAssertEqual(FlowText.ordered(result).map(\.id), ["a", "new-1", "image", "z"])
        XCTAssertEqual(result.first(where: { $0.id == "image" })?.imageAssetId, image.imageAssetId)
        XCTAssertEqual(FlowText.sections(in: result).map(\.isMarkdown), [true, false, true])
    }

    func testIncomingBoundaryUnderDirtyRunRefusesRatherThanReorderingIt() {
        let base = [block("a", "A", key: "A"), block("b", "B", key: "Z")]
        let image = CouchBlock(id: "image", kind: "image", orderKey: "M",
                              createdAt: before, updatedAt: before, deviceId: "boox")
        XCTAssertThrowsError(try edit(base, current: [base[0], image, base[1]], "Changed\n\nB"))
    }

    func testFenceAndBlankLinesUseTheSharedTransportBoundaries() throws {
        let source = "Before\n\n```\ncode\n\nstill code\n```\n\nAfter"
        let result = try edit([], source)
        XCTAssertEqual(FlowText.ordered(result).count, 3)
        XCTAssertEqual(FlowText.markdown(in: result), source)
    }

    func testVersionsAreHiddenAndPartiallyPositionedBlocksFollowTheReaderRule() {
        var partial = block("partial", "Visible"); partial.x = 0
        let hidden = CouchBlock(id: "version", kind: "text-version", text: "Old",
                               createdAt: before, updatedAt: before, deviceId: "boox")
        XCTAssertEqual(FlowText.markdown(in: [partial, hidden]), "Visible")
    }

    func testAnInkReferenceDrawsEachStrokeOnceWithoutChangingItsSource() {
        let first = CouchBlock(id: "first", kind: "ink", orderKey: "A", strokeIds: ["one", "shared"], createdAt: before, updatedAt: before, deviceId: "boox")
        let second = CouchBlock(id: "second", kind: "ink", orderKey: "B", strokeIds: ["shared", "two"], createdAt: before, updatedAt: before, deviceId: "boox")
        let blocks = [second, first]
        XCTAssertEqual(FlowText.inkIDs(for: "first", in: blocks), ["one", "shared"])
        XCTAssertEqual(FlowText.inkIDs(for: "second", in: blocks), ["two"])
        XCTAssertEqual(blocks[0].strokeIds, ["shared", "two"])
    }
}
