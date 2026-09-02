import XCTest

@testable import NotableKit

/// Drives `docs/couch-sync-vectors/markdown-blocks.json` — the same file notable's
/// `MarkdownBlocksTest` runs.
///
/// Block boundaries decide block ids, and ids decide what the merge treats as the same paragraph.
/// A splitting rule that lands in only one app therefore does not merely render differently: it
/// duplicates the user's paragraphs on the next sync. This fails when the two drift.
final class MarkdownBlocksTests: XCTestCase {

    private struct CaseFile: Decodable {
        var version: Int
        var cases: [Case]
    }

    private struct Case: Decodable {
        var name: String
        var why: String?
        var source: String
        var blocks: [String]
    }

    private static var casesURL: URL {
        // Canonical copy lives in docs/, shared verbatim with notable. Located relative to this
        // source file so there is no second copy inside the package to drift.
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // NotableKitTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // NotableKit
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("docs/couch-sync-vectors/markdown-blocks.json")
    }

    private func loadCases() throws -> [Case] {
        let data = try Data(contentsOf: Self.casesURL)
        return try JSONDecoder().decode(CaseFile.self, from: data).cases
    }

    func testCaseFileIsPresentAndNonEmpty() throws {
        XCTAssertGreaterThan(try loadCases().count, 0, "markdown-blocks.json is missing or empty")
    }

    func testEveryCaseSplitsAsAgreed() throws {
        for testCase in try loadCases() {
            XCTAssertEqual(
                MarkdownBlocks.split(testCase.source), testCase.blocks,
                "\(testCase.name): \(testCase.why ?? "")")
        }
    }

    /// The property that makes a page exportable as a `.md` file and readable back unchanged.
    /// It holds because no block contains a blank line outside a fence, none begins or ends with
    /// one, and an unclosed fence can only occur in the final block.
    func testJoiningAndResplittingIsIdentity() throws {
        for testCase in try loadCases() {
            XCTAssertEqual(
                MarkdownBlocks.split(MarkdownBlocks.join(testCase.blocks)), testCase.blocks,
                "\(testCase.name): joining then splitting changed the blocks")
        }
    }

    /// The same property over documents the case file does not name — every pair of cases, glued
    /// together — so the rule is exercised past the examples someone thought to write down.
    ///
    /// Skipping a left-hand document whose last block leaves a fence open is not the test dodging
    /// an awkward case; it is the precondition `join(_:)` documents. Such a block absorbs whatever
    /// follows it, so a document built by putting one in front of something else genuinely does not
    /// split back into its parts. `testAnUnclosedFenceIsOnlySafeLast` pins that as intended.
    func testJoiningAndResplittingIsIdentityForAssembledDocuments() throws {
        let cases = try loadCases()
        for left in cases where !(left.blocks.last.map(MarkdownBlocks.leavesFenceOpen) ?? false) {
            for right in cases {
                let blocks = left.blocks + right.blocks
                XCTAssertEqual(
                    MarkdownBlocks.split(MarkdownBlocks.join(blocks)), blocks,
                    "\(left.name) + \(right.name) did not survive a join and re-split")
            }
        }
    }

    /// The one documented limit of the round trip, asserted rather than described: a block that
    /// leaves a fence open is safe last and nowhere else. An editor that reorders blocks has to
    /// respect this, which is why the predicate is public.
    func testAnUnclosedFenceIsOnlySafeLast() throws {
        let open = "```\nnot closed"
        let after = "an ordinary paragraph"
        XCTAssertTrue(MarkdownBlocks.leavesFenceOpen(open))
        XCTAssertFalse(MarkdownBlocks.leavesFenceOpen(after))

        // Last: the document splits back into what it was built from.
        XCTAssertEqual(MarkdownBlocks.split(MarkdownBlocks.join([after, open])), [after, open])
        // Not last: the fence swallows the paragraph, and one block comes back instead of two.
        XCTAssertEqual(MarkdownBlocks.split(MarkdownBlocks.join([open, after])).count, 1)
    }

    /// Fence markers are counted in Unicode scalars, the way the BOOX counts UTF-16 units, not in
    /// grapheme clusters. A combining mark after the third backtick makes that backtick part of a
    /// two-scalar `Character` that no longer equals "`" — counted as graphemes, this line would be
    /// two backticks and no fence here while it is three and a fence there, and the two devices
    /// would split the same text into different blocks.
    func testAFenceMarkerFollowedByACombiningMarkStillOpensAFence() throws {
        let source = "```\u{0301}\nfirst\n\nsecond\n```"
        XCTAssertEqual(MarkdownBlocks.split(source), [source])
        XCTAssertTrue(MarkdownBlocks.leavesFenceOpen("```\u{0301}\nnot closed"))
    }
}
