import XCTest
@testable import NotableKit

final class TranscriptMarkdownTests: XCTestCase {
    func testOnlyExplicitMarkdownOptsInWithoutChangingSource() throws {
        let source = "# Literal\n- [x] **Text** | value"
        for format in [nil, "plain", "Markdown", "html"] {
            let decoded = try JSONDecoder().decode(ScribePageText.self,
                from: JSONEncoder().encode(ScribePageText(pageId: "p", notebookId: "b", text: source, format: format)))
            let content = TranscriptContent(text: decoded.text, format: decoded.format)
            XCTAssertFalse(content.isMarkdown); XCTAssertEqual(content.text, source)
        }
        XCTAssertTrue(TranscriptContent(text: source, format: "markdown").isMarkdown)
    }

    func testHeadingsNestedListsOrderedNumbersAndReadOnlyTasks() {
        let blocks = TranscriptMarkdown.parse("# Plan\n- Parent\n    - [X] **Done**\n\t- [ ] Later\n  7. Seven\n    9) Nine")
        XCTAssertEqual(blocks.count, 6)
        guard case .line(let heading, _, _) = blocks[0],
              case .line(let done, let doneIndent, let checked) = blocks[2],
              case .line(let later, let laterIndent, let unchecked) = blocks[3],
              case .line(let seven, let sevenIndent, _) = blocks[4],
              case .line(let nine, _, _) = blocks[5] else { return XCTFail("Expected structured lines") }
        XCTAssertEqual(heading.kind, .heading(level: 1)); XCTAssertEqual(heading.plainText, "Plan")
        XCTAssertEqual(doneIndent, 4); XCTAssertEqual(checked, true); XCTAssertEqual(done.plainText, "Done")
        XCTAssertTrue(done.spans[0].traits.contains(.bold))
        XCTAssertEqual(laterIndent, 4); XCTAssertEqual(unchecked, false); XCTAssertEqual(later.plainText, "Later")
        XCTAssertEqual(seven.kind, .numbered(7)); XCTAssertEqual(sevenIndent, 2)
        XCTAssertEqual(nine.kind, .numbered(9)); XCTAssertEqual(nine.plainText, "Nine")
    }

    func testTableKeepsEmptyCellsAlignmentEscapedPipesAndRaggedRows() {
        let blocks = TranscriptMarkdown.parse("| Item | Count | Note |\n| :--- | :---: | ---: |\n| Milk | | A\\|B |\n| Bread | 2 | `a|b` | extra |\n| Tea |\n\nAfter")
        guard case .table(let headers, let rows, let alignments) = blocks[0] else { return XCTFail("Expected table") }
        XCTAssertEqual(headers, ["Item", "Count", "Note", ""])
        XCTAssertEqual(rows, [["Milk", "", "A\\|B", ""], ["Bread", "2", "`a|b`", "extra"], ["Tea", "", "", ""]])
        XCTAssertEqual(alignments, [.leading, .center, .trailing, .leading])
        XCTAssertEqual(MarkdownText.parseInline(rows[0][2]).map(\.text).joined(), "A|B")
        XCTAssertEqual(blocks.count, 3)
    }

    func testMalformedTableAndCodeAreNotMisreadAsStructureOrNavigation() {
        let source = "a | b\n-- | ---\n```\n# literal\n- [x] unchanged\na | b\n--- | ---\n```"
        let blocks = TranscriptMarkdown.parse(source)
        XCTAssertEqual(blocks.count, 3)
        XCTAssertEqual(blocks[2], .code("# literal\n- [x] unchanged\na | b\n--- | ---"))
        let spans = MarkdownText.parseInline("[Label](https://example.invalid) <script> ![alt](https://example.invalid/image)")
        XCTAssertEqual(spans.map(\.text).joined(), "Label <script> !alt")
        XCTAssertFalse(spans.map(\.text).joined().contains("https://"))
    }
}
