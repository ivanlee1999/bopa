import Foundation

/// The markdown a text box understands, parsed into lines and styled spans.
///
/// **Deliberately a small fixed subset, and deliberately hand-written.** A text box stores
/// markdown *source* (protocol §3.3.1), and each app is free to render it however it likes — but
/// "free to differ" is a licence, not a goal. The same note opened on the iPad and on the BOOX
/// should look like the same note, and the cheapest way to guarantee that is for both apps to
/// implement the *same* small grammar rather than each adopting whichever full markdown library
/// its platform happens to offer. Two CommonMark implementations agree about far more than this
/// grammar covers, and disagree in exactly the places nobody can predict.
///
/// This type is the shared half: pure, platform-free, and mirrored line for line by
/// `MarkdownSpans.kt` in the Android app. The platform half turns these lines into an
/// `NSAttributedString` (see `TextBoxLayout`) or a `Spanned`.
///
/// Unlike ``MarkdownBlocks``, nothing here is normative. It decides what the user *sees*, never
/// what is stored or merged, so it can grow a feature without a protocol revision.
public enum MarkdownText {

    /// What a line is, which decides its font size and indent.
    public enum LineKind: Equatable, Sendable {
        case body
        case heading(level: Int)
        case bullet
        /// A numbered item, carrying the number the source wrote — a list starting at 3 keeps
        /// its 3, because renumbering it would edit what the user typed.
        case numbered(Int)
    }

    /// The inline styling of a run of characters. A set rather than an enum: `**bold `code`**`
    /// is both, and nothing here forbids a combination.
    public struct SpanTraits: OptionSet, Sendable, Hashable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let bold = SpanTraits(rawValue: 1 << 0)
        public static let italic = SpanTraits(rawValue: 1 << 1)
        public static let code = SpanTraits(rawValue: 1 << 2)
        /// A link's visible text. The destination is dropped: a text box is not a browser, and
        /// carrying a URL nothing can open only invites drawing it.
        public static let link = SpanTraits(rawValue: 1 << 3)
    }

    public struct Span: Equatable, Sendable {
        public var text: String
        public var traits: SpanTraits

        public init(text: String, traits: SpanTraits = []) {
            self.text = text
            self.traits = traits
        }
    }

    public struct Line: Equatable, Sendable {
        public var kind: LineKind
        public var spans: [Span]

        public init(kind: LineKind, spans: [Span]) {
            self.kind = kind
            self.spans = spans
        }

        /// The line's characters with the markup taken out — what gets laid out.
        public var plainText: String { spans.map(\.text).joined() }
    }

    /// Parses `source` into one ``Line`` per source line.
    ///
    /// Blank lines are kept as empty body lines rather than dropped: in a text box a blank line
    /// is the user asking for space, and swallowing it would close a gap they typed on purpose.
    public static func parse(_ source: String) -> [Line] {
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        return normalized.components(separatedBy: "\n").map(parseLine)
    }

    // MARK: Block level

    private static func parseLine(_ raw: String) -> Line {
        // Up to three leading spaces are ignored before a marker, the same tolerance CommonMark
        // allows and the same one `MarkdownBlocks` fences use. Beyond that the spaces are the
        // user's own indentation and stay in the text.
        let leading = raw.prefix { $0 == " " }
        let body = leading.count <= 3 ? String(raw.dropFirst(leading.count)) : raw

        if let heading = headingPrefix(body) {
            return Line(kind: .heading(level: heading.level), spans: parseInline(heading.rest))
        }
        if let rest = bulletPrefix(body) {
            return Line(kind: .bullet, spans: parseInline(rest))
        }
        if let numbered = numberedPrefix(body) {
            return Line(kind: .numbered(numbered.number), spans: parseInline(numbered.rest))
        }
        return Line(kind: .body, spans: parseInline(raw))
    }

    /// `#`, `##` or `###` followed by a space. Four or more hashes is not a heading — it is what
    /// a user typing a row of hashes meant, and CommonMark agrees.
    private static func headingPrefix(_ line: String) -> (level: Int, rest: String)? {
        let hashes = line.prefix { $0 == "#" }
        guard (1...3).contains(hashes.count) else { return nil }
        let rest = line.dropFirst(hashes.count)
        guard rest.first == " " else { return nil }
        return (hashes.count, String(rest.dropFirst()))
    }

    private static func bulletPrefix(_ line: String) -> String? {
        guard let first = line.first, first == "-" || first == "*" || first == "+" else {
            return nil
        }
        let rest = line.dropFirst()
        guard rest.first == " " else { return nil }
        return String(rest.dropFirst())
    }

    private static func numberedPrefix(_ line: String) -> (number: Int, rest: String)? {
        let digits = line.prefix(while: \.isASCIIDigit)
        // Bounded so a line beginning with a long number is text, not a list item nobody can
        // number — and so the ordinal always fits an `Int`.
        guard (1...9).contains(digits.count), let number = Int(digits) else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.first == "." else { return nil }
        let afterDot = rest.dropFirst()
        guard afterDot.first == " " else { return nil }
        return (number, String(afterDot.dropFirst()))
    }

    // MARK: Inline level

    /// Splits a line into styled runs.
    ///
    /// One left-to-right pass, no nesting except inside emphasis: code spans are literal (so
    /// `` `**x**` `` shows the asterisks), and a marker with no partner on the same line is
    /// itself literal — an unmatched `*` is a bullet somebody typed mid-sentence, not the start
    /// of emphasis that runs to the end of the paragraph.
    private static func parseInline(_ line: String) -> [Span] {
        var spans: [Span] = []
        var pending = ""
        // Never reassigned: a top-level run carries no styling of its own, and everything nested
        // receives its parent's traits through the recursion below.
        let traits: SpanTraits = []
        let chars = Array(line)
        var i = 0

        func flush() {
            guard !pending.isEmpty else { return }
            spans.append(Span(text: pending, traits: traits))
            pending = ""
        }

        while i < chars.count {
            let c = chars[i]

            // A backslash escapes the next character, which is the only way to type a literal
            // marker. It escapes anything, so the rule needs no list to stay in step with Kotlin.
            if c == "\\", i + 1 < chars.count {
                pending.append(chars[i + 1])
                i += 2
                continue
            }

            if c == "`", let end = indexOf("`", in: chars, from: i + 1) {
                flush()
                spans.append(Span(text: String(chars[(i + 1)..<end]), traits: traits.union(.code)))
                i = end + 1
                continue
            }

            if let marker = emphasisMarker(chars, at: i),
               let end = indexOfRun(marker.character, count: marker.count, in: chars, from: i + marker.count) {
                flush()
                let inner = String(chars[(i + marker.count)..<end])
                let added: SpanTraits = marker.count == 2 ? .bold : .italic
                // Recursed so `**bold *and italic***` keeps both, and so an inner code span is
                // still literal inside emphasis.
                for span in parseInline(inner) {
                    spans.append(Span(text: span.text, traits: span.traits.union(traits).union(added)))
                }
                i = end + marker.count
                continue
            }

            if c == "[", let close = indexOf("]", in: chars, from: i + 1),
               close + 1 < chars.count, chars[close + 1] == "(",
               let paren = indexOf(")", in: chars, from: close + 2) {
                flush()
                for span in parseInline(String(chars[(i + 1)..<close])) {
                    spans.append(Span(text: span.text, traits: span.traits.union(traits).union(.link)))
                }
                i = paren + 1
                continue
            }

            pending.append(c)
            i += 1
        }

        flush()
        return spans
    }

    /// The emphasis run starting at `index`, if one does. Two markers mean bold, one italic;
    /// three or more is read as bold plus italic by the recursion above.
    private static func emphasisMarker(
        _ chars: [Character], at index: Int
    ) -> (character: Character, count: Int)? {
        let c = chars[index]
        guard c == "*" || c == "_" else { return nil }
        var count = 0
        while index + count < chars.count, chars[index + count] == c { count += 1 }
        // Emphasis has to contain something, so a run at the very end of the line is literal.
        guard index + count < chars.count else { return nil }
        return (c, min(count, 2))
    }

    private static func indexOf(_ needle: Character, in chars: [Character], from start: Int) -> Int? {
        var i = start
        while i < chars.count {
            if chars[i] == "\\" { i += 2; continue }
            if chars[i] == needle { return i }
            i += 1
        }
        return nil
    }

    /// The next run of exactly `count` of `character`, skipping escaped ones.
    private static func indexOfRun(
        _ character: Character, count: Int, in chars: [Character], from start: Int
    ) -> Int? {
        var i = start
        while i < chars.count {
            if chars[i] == "\\" { i += 2; continue }
            if chars[i] == character {
                var run = 0
                while i + run < chars.count, chars[i + run] == character { run += 1 }
                if run >= count { return i }
                i += run
                continue
            }
            i += 1
        }
        return nil
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
