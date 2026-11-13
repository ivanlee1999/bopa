import XCTest
@testable import NotableKit

final class ContentTagsTests: XCTestCase {
    func testAssignsKnownPhrasesAndNewHashtagsWithoutDuplicates() {
        XCTAssertEqual(contentTags(text: "WORK update for book\nclub. #work #travel #travel", known: ["Work", "Book Club"]), ["Book Club", "Work", "travel"])
    }

    func testRequiresWholeNamesAndKeepsShortNamesExplicit() {
        XCTAssertEqual(contentTags(text: "Daily chair workshop. AI plan #a", known: ["AI", "Work", "a"]), ["AI", "a"])
        XCTAssertFalse(contentTags(text: "#workshop and #work-life", known: ["Work"]).contains("Work"))
    }

    func testIgnoresCodeLinksEmailsAndMarkdownHeadings() {
        let text = """
        # Work heading
        ```
        #hidden work
        ```
        ~~~
        #hidden work
        ~~~
        `#inline work` https://example.com/#remote www.example.com/#remote name#mail@example.com
        ##heading #real
        """
        XCTAssertEqual(contentTags(text: text, known: []), ["real"])
    }

    func testSupportsUnicodeNormalizationAndNestedTags() {
        XCTAssertEqual(contentTags(text: "Cafe\u{0301} #研究 #work/project/", known: ["Café"]), ["Café", "研究", "work/project"])
    }

    func testPreservesKnownCanonicalSpellingAndRejectsUnboundedHashtags() {
        XCTAssertEqual(contentTags(text: "#WORK #" + String(repeating: "x", count: 65), known: ["Work"]), ["Work"])
    }

    func testUsesTheSyncedAsciiIdentityForMatching() {
        XCTAssertEqual(contentTags(text: "CAFÉ", known: ["Café", "CafÉ"]), ["CafÉ"])
        XCTAssertEqual(contentTags(text: "#z #Áb", known: ["Áb", "z"]), ["z", "Áb"])
    }

    func testHandlesLongUnbrokenProse() {
        XCTAssertEqual(contentTags(text: String(repeating: "研", count: 80_000) + " Work", known: ["Work"]), ["Work"])
    }

    func testKeepsShorterAndInfoBearingFencesInsideCode() {
        XCTAssertEqual(contentTags(text: "````markdown\n```\n#hidden\n````example\n#hidden\n````\n#real", known: []), ["real"])
    }

    func testIgnoresEscapedHashtags() {
        XCTAssertEqual(contentTags(text: "\\#literal ##heading #real", known: []), ["real"])
    }

    func testOneHashtagCannotAssignBothALiteralHashLabelAndAnOrdinaryTag() {
        XCTAssertEqual(contentTags(text: "#Work", known: ["#Work", "Work"]), ["Work"])
        XCTAssertEqual(contentTags(text: "##Work", known: ["#Work", "Work"]), [])
    }
}
