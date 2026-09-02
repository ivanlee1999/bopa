import Foundation

/// Cutting a markdown document into blocks, and putting it back together — protocol §9.
///
/// This is deliberately **not** a markdown parser, and that is the whole design. Block boundaries
/// decide block *ids*, ids decide what the merge treats as the same paragraph, so two
/// implementations in two languages have to agree on them exactly and for ever. Asking each of them
/// what markdown *means* is the one way to guarantee they eventually won't: CommonMark has
/// revisions, two libraries track them at different times, and a dependency bump on one side would
/// silently move a boundary, change an id, and duplicate somebody's paragraph on the next merge.
///
/// So the contract is defined over the one thing neither language can disagree about — where the
/// blank lines are, with fences excepted. Same instinct as the merge comparing bytes rather than
/// strings, and IEEE-754 bit patterns rather than printed floats.
///
/// Splitting is a *transport granularity, not a rendering decision*. Each app renders a block with
/// whatever markdown renderer it likes, and the two may legitimately disagree about rendering while
/// never disagreeing about the merge.
///
/// Pinned by `docs/couch-sync-vectors/markdown-blocks.json`, which is byte-identical in both repos
/// and diffed by both CIs — see `MarkdownBlocksTests`.
public enum MarkdownBlocks {
    /// The blocks of `source`, in document order.
    public static func split(_ source: String) -> [String] {
        let lines = normalized(source).components(separatedBy: "\n")

        var blocks: [String] = []
        var current: [String] = []
        var fence: Fence?
        var index = 0

        // Front matter is one block. Splitting it would put an id on each key and let two devices
        // merge half of one document's front matter with half of another's. It only counts when the
        // first non-blank line opens it *and* a line closes it *before the next blank line*: three
        // dashes on their own are a thematic break, and a document beginning with one must not be
        // swallowed whole.
        //
        // The "before the next blank line" clause is what keeps the decision local. Without it,
        // whether a document opens with front matter depends on whether a `---` turns up anywhere
        // later — so gluing two documents together could retroactively change the meaning of the
        // first one's opening, and the blocks would no longer split back into the blocks they were
        // built from.
        //
        // The first *non-blank* line, not line 1, for the same reason: leading blank lines are
        // separators and are dropped, so the first block always starts at the first non-blank line
        // and `join` never puts anything in front of it. A test on line 1 would find front matter
        // in `join(split(x))` that it had not found in `x`, and split the two differently.
        let start = lines.firstIndex { !isBlank($0) } ?? lines.count
        if start < lines.count, lines[start] == "---",
           let close = lines[(start + 1)...]
               .prefix(while: { !isBlank($0) })
               .firstIndex(of: "---") {
            blocks.append(lines[start...close].joined(separator: "\n"))
            index = close + 1
        }

        while index < lines.count {
            let line = lines[index]
            defer { index += 1 }

            if let open = fence {
                current.append(line)
                if closes(line, open) { fence = nil }
                continue
            }
            if let open = opensFence(line) {
                current.append(line)
                fence = open
                continue
            }
            if isBlank(line) {
                if !current.isEmpty {
                    blocks.append(current.joined(separator: "\n"))
                    current = []
                }
                continue
            }
            current.append(line)
        }
        if !current.isEmpty { blocks.append(current.joined(separator: "\n")) }
        return blocks
    }

    /// The document `blocks` came from. `split(join(blocks)) == blocks` for any blocks `split`
    /// produced — which is what lets a page be exported as a `.md` file and read back unchanged.
    ///
    /// One precondition, and it is not theoretical: at most one block may leave a fence open, and
    /// it must be the last. Join a block that opens a fence and never closes it in front of
    /// anything else and the fence swallows what follows, so the document no longer splits back
    /// into the blocks it was built from. `leavesFenceOpen(_:)` is how a caller checks.
    public static func join(_ blocks: [String]) -> String {
        blocks.joined(separator: "\n\n")
    }

    /// Whether this block ends inside a fence it never closed — a paragraph mid-typing, usually.
    ///
    /// Such a block is only safe in last position: anywhere else it absorbs the blocks after it
    /// (see `join(_:)`). An editor that reorders blocks, or pastes one into the middle of a
    /// document, has to know that, so the rule is exposed rather than left as a comment.
    public static func leavesFenceOpen(_ block: String) -> Bool {
        var fence: Fence?
        for line in normalized(block).components(separatedBy: "\n") {
            if let open = fence {
                if closes(line, open) { fence = nil }
            } else if let open = opensFence(line) {
                fence = open
            }
        }
        return fence != nil
    }

    // MARK: - The rules

    /// Strip a byte-order mark, and make every line ending `\n`. Nothing else: tabs are not
    /// expanded and interior whitespace is untouched, because both would edit the user's text.
    private static func normalized(_ source: String) -> String {
        var text = source
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        return text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    /// A separator: nothing on the line but spaces and tabs.
    private static func isBlank(_ line: String) -> Bool {
        !line.contains { $0 != " " && $0 != "\t" }
    }

    private struct Fence {
        let marker: Unicode.Scalar
        let count: Int
    }

    /// The fence this line opens, or nil. Up to three leading spaces are allowed — the same
    /// allowance CommonMark makes, and the one a fence inside a list item needs. A fourth space is
    /// indented code, and treating it as a fence would swallow the rest of the document.
    private static func opensFence(_ line: String) -> Fence? {
        let (marker, count, _) = markerRun(line)
        guard let marker, count >= 3 else { return nil }
        return Fence(marker: marker, count: count)
    }

    /// Whether this line closes `fence`: at least as long a run of the same character, and nothing
    /// after it but trailing whitespace. "At least as long" is what lets a four-backtick fence hold
    /// three backticks as content.
    private static func closes(_ line: String, _ fence: Fence) -> Bool {
        let (marker, count, rest) = markerRun(line)
        guard marker == fence.marker, count >= fence.count else { return false }
        return isBlank(rest)
    }

    /// The run of fence characters this line starts with after its indent, and what follows it.
    ///
    /// Counted in Unicode scalars, not `Character`s. A grapheme cluster is a rendering unit — a
    /// backtick followed by a combining accent is *one* `Character` and no longer equal to "`" —
    /// whereas the BOOX counts UTF-16 code units, which for these ASCII markers is the same as
    /// counting scalars. Counting graphemes here would open a fence on one device and not the
    /// other, and the two would split the same text into different blocks.
    private static func markerRun(_ line: String) -> (Unicode.Scalar?, Int, String) {
        var rest = Substring(line).unicodeScalars
        var indent = 0
        while indent < 3, rest.first == " " {
            rest.removeFirst()
            indent += 1
        }
        // A fourth space means indented code, never a fence.
        guard let marker = rest.first, marker == "`" || marker == "~" else { return (nil, 0, "") }
        var count = 0
        while rest.first == marker {
            rest.removeFirst()
            count += 1
        }
        return (marker, count, String(rest))
    }
}
