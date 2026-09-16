import CoreGraphics
import CoreText
import XCTest

@testable import NotableKit

/// The markdown subset a text box renders, and the geometry a box is given.
///
/// Nothing here is pinned by a conformance vector — rendering is deliberately each app's own
/// business (protocol §3.3.1). What these tests defend is that the *same grammar* is implemented
/// as the BOOX's `MarkdownSpansTest`, because a note that reads differently on the two devices is
/// a note the user cannot trust either copy of.
final class TextBoxLayoutTests: XCTestCase {

    // MARK: Block level

    func testHeadingLevelsAreRecognized() {
        XCTAssertEqual(MarkdownText.parse("# Title")[0].kind, .heading(level: 1))
        XCTAssertEqual(MarkdownText.parse("## Title")[0].kind, .heading(level: 2))
        XCTAssertEqual(MarkdownText.parse("### Title")[0].kind, .heading(level: 3))
        XCTAssertEqual(MarkdownText.parse("# Title")[0].plainText, "Title")
    }

    func testFourHashesIsNotAHeading() {
        let line = MarkdownText.parse("#### Title")[0]
        XCTAssertEqual(line.kind, .body)
        XCTAssertEqual(line.plainText, "#### Title")
    }

    func testHashWithoutSpaceIsNotAHeading() {
        XCTAssertEqual(MarkdownText.parse("#hashtag")[0].kind, .body)
    }

    func testBulletsAndNumbers() {
        XCTAssertEqual(MarkdownText.parse("- milk")[0].kind, .bullet)
        XCTAssertEqual(MarkdownText.parse("* milk")[0].kind, .bullet)
        XCTAssertEqual(MarkdownText.parse("+ milk")[0].kind, .bullet)
        XCTAssertEqual(MarkdownText.parse("- milk")[0].plainText, "milk")
        XCTAssertEqual(MarkdownText.parse("1. first")[0].kind, .numbered(1))
        // The source's own number is kept: renumbering a list that starts at three would edit
        // what the user typed.
        XCTAssertEqual(MarkdownText.parse("3. third")[0].kind, .numbered(3))
        XCTAssertEqual(MarkdownText.parse("3. third")[0].plainText, "third")
    }

    func testBlankLinesSurviveAsEmptyBodyLines() {
        let lines = MarkdownText.parse("one\n\ntwo")
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[1].kind, .body)
        XCTAssertEqual(lines[1].plainText, "")
    }

    func testCarriageReturnsAreNormalized() {
        XCTAssertEqual(MarkdownText.parse("a\r\nb").count, 2)
        XCTAssertEqual(MarkdownText.parse("a\rb").count, 2)
    }

    // MARK: Inline level

    private func spans(_ source: String) -> [MarkdownText.Span] {
        MarkdownText.parse(source)[0].spans
    }

    func testBoldAndItalic() {
        let bold = spans("say **loudly** now")
        XCTAssertEqual(bold.map(\.text), ["say ", "loudly", " now"])
        XCTAssertEqual(bold[1].traits, .bold)

        let italic = spans("say *softly* now")
        XCTAssertEqual(italic.map(\.text), ["say ", "softly", " now"])
        XCTAssertEqual(italic[1].traits, .italic)

        XCTAssertEqual(spans("__b__")[0].traits, .bold)
        XCTAssertEqual(spans("_i_")[0].traits, .italic)
    }

    func testCodeIsLiteralInside() {
        let runs = spans("run `a **b** c` now")
        XCTAssertEqual(runs.map(\.text), ["run ", "a **b** c", " now"])
        XCTAssertEqual(runs[1].traits, .code)
    }

    func testLinkKeepsItsTextAndDropsItsDestination() {
        let runs = spans("see [the docs](https://example.com) please")
        XCTAssertEqual(runs.map(\.text), ["see ", "the docs", " please"])
        XCTAssertTrue(runs[1].traits.contains(.link))
    }

    func testUnmatchedMarkerIsLiteral() {
        // A lone asterisk mid-sentence is a character somebody typed, not emphasis running to
        // the end of the line.
        XCTAssertEqual(spans("2 * 3 = 6").map(\.text), ["2 * 3 = 6"])
        XCTAssertEqual(spans("2 * 3 = 6")[0].traits, [])
    }

    func testBackslashEscapesAMarker() {
        let runs = spans("literal \\*stars\\* here")
        XCTAssertEqual(runs.map(\.text), ["literal *stars* here"])
        XCTAssertEqual(runs[0].traits, [])
    }

    func testNestedEmphasisCombinesTraits() {
        let runs = spans("**bold *and italic* here**")
        XCTAssertTrue(runs.allSatisfy { $0.traits.contains(.bold) })
        XCTAssertTrue(runs.contains { $0.traits.contains(.italic) && $0.text == "and italic" })
    }

    // MARK: Attributed string

    private func attributes(
        _ source: String, at index: Int
    ) -> [NSAttributedString.Key: Any] {
        TextBoxLayout.attributedString(source).attributes(at: index, effectiveRange: nil)
    }

    private func fontSize(_ source: String, at index: Int) -> CGFloat {
        let font = attributes(source, at: index)[
            NSAttributedString.Key(kCTFontAttributeName as String)] as! CTFont
        return CTFontGetSize(font)
    }

    func testHeadingIsLargerAndBoldThanBody() {
        let metrics = TextBoxMetrics.standard
        XCTAssertEqual(fontSize("# Title", at: 0), metrics.body * 2, accuracy: 0.01)
        XCTAssertEqual(fontSize("## Title", at: 0), metrics.body * 1.5, accuracy: 0.01)
        XCTAssertEqual(fontSize("plain", at: 0), metrics.body, accuracy: 0.01)

        let font = attributes("# Title", at: 0)[
            NSAttributedString.Key(kCTFontAttributeName as String)] as! CTFont
        XCTAssertTrue(CTFontGetSymbolicTraits(font).contains(.traitBold))
    }

    func testBoldRunCarriesTheBoldFace() {
        // "say " is plain, "loudly" is bold.
        let plain = attributes("say **loudly**", at: 0)[
            NSAttributedString.Key(kCTFontAttributeName as String)] as! CTFont
        let bold = attributes("say **loudly**", at: 5)[
            NSAttributedString.Key(kCTFontAttributeName as String)] as! CTFont
        XCTAssertFalse(CTFontGetSymbolicTraits(plain).contains(.traitBold))
        XCTAssertTrue(CTFontGetSymbolicTraits(bold).contains(.traitBold))
    }

    func testParagraphStyleIsACoreTextOne() {
        // The AppKit spelling looks identical and lays out with no line height at all, and only
        // on a device — the measurement agrees with it, so nothing else would catch this.
        let style = attributes("plain", at: 0)[
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String)]
        XCTAssertNotNil(style)
        XCTAssertTrue(CFGetTypeID(style as CFTypeRef) == CTParagraphStyleGetTypeID())
    }

    func testLinkIsUnderlined() {
        let runs = TextBoxLayout.attributedString("see [docs](https://example.com)")
        let underline = runs.attributes(at: 4, effectiveRange: nil)[
            NSAttributedString.Key(kCTUnderlineStyleAttributeName as String)]
        XCTAssertNotNil(underline)
    }

    func testRenderedTextDropsTheMarkup() {
        XCTAssertEqual(
            TextBoxLayout.attributedString("# Title\n- **milk**").string, "Title\n\u{2022} milk")
    }

    // MARK: Geometry

    func testDefaultWidthClampsAtTheRightMargin() {
        let metrics = TextBoxMetrics.standard
        // Room to spare: the preferred width.
        XCTAssertEqual(TextBoxLayout.defaultWidth(x: 100, pageWidth: 1400), metrics.preferredWidth)
        // Near the right edge: pulled in, stopping `rightMargin` short of it.
        XCTAssertEqual(TextBoxLayout.defaultWidth(x: 1000, pageWidth: 1400), 360)
        // Past the point where even the minimum fits: the minimum, not something unusable.
        XCTAssertEqual(TextBoxLayout.defaultWidth(x: 1390, pageWidth: 1400), metrics.minimumWidth)
    }

    func testMeasuredHeightIsAtLeastOneLine() {
        let empty = TextBoxLayout.measuredHeight(source: "", width: 560)
        let metrics = TextBoxMetrics.standard
        XCTAssertGreaterThanOrEqual(empty, metrics.body * metrics.lineHeightMultiple)
    }

    func testMeasuredHeightGrowsWithLines() {
        let one = TextBoxLayout.measuredHeight(source: "one", width: 560)
        let three = TextBoxLayout.measuredHeight(source: "one\ntwo\nthree", width: 560)
        XCTAssertGreaterThan(three, one)
    }

    func testMeasuredHeightGrowsWhenTheBoxNarrows() {
        let sentence = String(repeating: "word ", count: 40)
        let wide = TextBoxLayout.measuredHeight(source: sentence, width: 900)
        let narrow = TextBoxLayout.measuredHeight(source: sentence, width: 300)
        XCTAssertGreaterThan(narrow, wide)
    }

    // MARK: Which blocks are text boxes

    private func block(
        id: String, kind: String = "md", x: Int? = 10, y: Int? = 20, text: String? = "hi",
        createdAt: String = "2026-01-01T00:00:00.000Z"
    ) -> CouchBlock {
        CouchBlock(
            id: id, kind: kind, orderKey: "", text: text, imageAssetId: nil, segments: [],
            strokeIds: [], x: x, y: y, width: 560, height: 60, startedAt: nil,
            createdAt: createdAt, updatedAt: createdAt, deviceId: "ipad")
    }

    func testOnlyPositionedMarkdownBlocksAreTextBoxes() {
        let blocks = [
            block(id: "a"),
            block(id: "b", kind: "image"),
            block(id: "c", x: nil, y: nil),
            // Exactly one coordinate present is flowing, per protocol §3.3.1.
            block(id: "d", x: 10, y: nil),
            block(id: "e", kind: "future-kind"),
        ]
        XCTAssertEqual(TextBoxLayout.textBoxes(in: blocks).map(\.id), ["a"])
    }

    func testTextBoxesAreOrderedOldestFirst() {
        let blocks = [
            block(id: "b", createdAt: "2026-01-02T00:00:00.000Z"),
            block(id: "a", createdAt: "2026-01-01T00:00:00.000Z"),
        ]
        XCTAssertEqual(TextBoxLayout.textBoxes(in: blocks).map(\.id), ["a", "b"])
    }

    func testFrameIsTheBlockRectangle() {
        let frame = TextBoxLayout.frame(of: block(id: "a"))
        XCTAssertEqual(frame, CGRect(x: 10, y: 20, width: 560, height: 60))
        XCTAssertNil(TextBoxLayout.frame(of: block(id: "b", kind: "image")))
        XCTAssertNil(TextBoxLayout.frame(of: block(id: "c", x: nil, y: nil)))
    }

    // MARK: Drawing

    private func grayContext(width: Int, height: Int) -> CGContext {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context
    }

    /// Whether anything was painted.
    ///
    /// Walked row by row using the context's own stride, never as one flat run: CoreGraphics pads
    /// each row out to its alignment, the padding is zero (which is *black* in a grayscale
    /// buffer), and a flat scan reads it as ink. That made the "nothing was drawn" test fail and,
    /// worse, made the "something was drawn" test pass without drawing anything.
    private func hasInk(_ context: CGContext) -> Bool {
        guard let data = context.data else { return false }
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        for y in 0..<context.height {
            let row = y * context.bytesPerRow
            for x in 0..<context.width where bytes[row + x] < 200 { return true }
        }
        return false
    }

    /// Ink is drawn over text, so a box that paints nothing has to paint *nothing* — a filled
    /// background would rub out the strokes above it.
    func testDrawingLeavesTheBackgroundAloneWhereThereIsNoText() {
        let context = grayContext(width: 100, height: 40)
        TextBoxLayout.draw(blocks: [block(id: "a", kind: "image")], in: context, scale: 1)
        XCTAssertFalse(hasInk(context), "a non-text block must not paint anything")
    }

    func testDrawingPutsInkOnThePage() {
        let context = grayContext(width: 600, height: 200)
        TextBoxLayout.draw(
            blocks: [block(id: "a", x: 0, y: 0, text: "# Hello")], in: context, scale: 1)
        XCTAssertTrue(hasInk(context), "drawing a text box should darken some pixels")
    }

    func testSkippedBlockIsNotDrawn() {
        let context = grayContext(width: 600, height: 200)
        TextBoxLayout.draw(
            blocks: [block(id: "a", x: 0, y: 0, text: "# Hello")], in: context, scale: 1,
            skipping: ["a"])
        XCTAssertFalse(hasInk(context))
    }

    func testAFlowingBlockIsNotDrawn() {
        let context = grayContext(width: 600, height: 200)
        TextBoxLayout.draw(
            blocks: [block(id: "a", x: nil, y: nil, text: "# Hello")], in: context, scale: 1)
        XCTAssertFalse(hasInk(context), "a block with no place on the page has nowhere to draw")
    }
}
