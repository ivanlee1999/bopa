import Foundation
import NotableKit

/// A page's handwriting, as text, stored beside the page it came from.
///
/// Derived data: regenerable from ink, so it deliberately takes no part in the library's sync.
/// It reaches the BOOX and Obsidian through a separate CouchDB database instead — see
/// `docs/recognized-text.md`, which is the contract this and its publisher implement.
///
/// Every field is decoded leniently. These files are written by this app, but the same shape
/// arrives from the BOOX's recognizer, and a decode that threw on an absent optional would leave
/// a page permanently unreadable rather than merely unrecognized.
struct PageTextFile: Codable, Equatable, Sendable {
    var pageId: String
    var text: String
    var engine: String
    var language: String?
    /// The page's `updatedAt` when the recognized strokes were read, copied verbatim. The page
    /// moving past this is what makes the text stale.
    var recognizedClock: String
    var updatedAt: String
    var updatedBy: String
    /// Whether this text still has to reach the server. Kept in the file so text recognized while
    /// offline survives the app being closed.
    var pendingPush: Bool

    init(
        pageId: String,
        text: String,
        engine: String,
        language: String?,
        recognizedClock: String,
        updatedAt: String,
        updatedBy: String,
        pendingPush: Bool = true
    ) {
        self.pageId = pageId
        self.text = text
        self.engine = engine
        self.language = language
        self.recognizedClock = recognizedClock
        self.updatedAt = updatedAt
        self.updatedBy = updatedBy
        self.pendingPush = pendingPush
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pageId = try container.decodeIfPresent(String.self, forKey: .pageId) ?? ""
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        engine = try container.decodeIfPresent(String.self, forKey: .engine) ?? ""
        language = try container.decodeIfPresent(String.self, forKey: .language)
        // An absent clock loses every freshness comparison, which is the safe direction: the page
        // reads as needing recognition rather than as permanently current.
        recognizedClock = try container.decodeIfPresent(String.self, forKey: .recognizedClock) ?? ""
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt) ?? ""
        updatedBy = try container.decodeIfPresent(String.self, forKey: .updatedBy) ?? ""
        pendingPush = try container.decodeIfPresent(Bool.self, forKey: .pendingPush) ?? false
    }

    /// True when [pageUpdatedAt] is later than the ink this text was read from.
    func isStale(pageUpdatedAt: String) -> Bool {
        guard let page = PageTextClock.millis(pageUpdatedAt),
              let recognized = PageTextClock.millis(recognizedClock)
        else { return true }
        return page > recognized
    }
}

/// Comparing the ISO stamps these documents carry.
///
/// Stamps stay strings on the model rather than becoming Dates: `recognizedClock` is copied
/// verbatim from the page it describes, and a round trip through Date would re-render it in this
/// app's spelling — turning a value that is only ever compared into one that differs from the
/// page's by a trailing zero.
enum PageTextClock {
    /// Milliseconds for a stamp, or nil when it cannot be read.
    ///
    /// Nil rather than zero: callers compare freshness with it, and a stamp nobody can parse must
    /// not become "the beginning of time", which would mark its page stale forever and recognize
    /// it on a loop.
    static func millis(_ stamp: String) -> Int64? {
        guard !stamp.isEmpty, let date = NotableDate.parse(stamp) else { return nil }
        return Int64(date.timeIntervalSince1970 * 1000)
    }
}
