import Foundation

/// A disposable label for an unnamed note; it never changes the authored title or content.
public enum ContentTitle {
    public static func firstLine(_ source: String) -> String? {
        for raw in source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n") {
            var line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("```") || line.hasPrefix("~~~") || line.hasPrefix("![") { continue }
            var heading = false
            while true {
                let before = line
                line = line.replacingOccurrences(of: #"^(?:>\s*)+"#, with: "", options: .regularExpression)
                if line.range(of: #"^#{1,6}\s+"#, options: .regularExpression) != nil { heading = true }
                line = line.replacingOccurrences(of: #"^#{1,6}\s+"#, with: "", options: .regularExpression)
                    .replacingOccurrences(of: #"^(?:[-*+•]\s+|[0-9]{1,9}[.)]\s+|[①-⑳]\s*)"#, with: "", options: .regularExpression)
                    .replacingOccurrences(of: #"^\[[ xX]\]\s*"#, with: "", options: .regularExpression)
                if line == before { break }
            }
            if heading { line = line.replacingOccurrences(of: #"\s+#+\s*$"#, with: "", options: .regularExpression) }
            if line.hasPrefix("|") { line.removeFirst() }
            if line.hasSuffix("|"), !line.hasSuffix("\\|") { line.removeLast() }
            line = line.replacingOccurrences(of: #"\[\[[^\]|]*\|([^\]]+)\]\]"#, with: "$1", options: .regularExpression)
                .replacingOccurrences(of: #"\[\[([^\]]+)\]\]"#, with: "$1", options: .regularExpression)
                .replacingOccurrences(of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
                .replacingOccurrences(of: #"`([^`]+)`"#, with: "$1", options: .regularExpression)
            for marker in [#"\*\*"#, "__", #"\*"#, "_"] {
                line = line.replacingOccurrences(of: #"(?<![\\\p{L}\p{N}])"# + marker + #"([^\n]+?)"# + marker + #"(?![\p{L}\p{N}])"#,
                    with: "$1", options: .regularExpression)
            }
            line = line.replacingOccurrences(of: #"\\([\\`*_{}\[\]()#+.!>|~=-])"#, with: "$1", options: .regularExpression)
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard line.range(of: #"[\p{L}\p{N}\p{So}]"#, options: .regularExpression) != nil else { continue }
            let scalars = Array(line.unicodeScalars)
            return scalars.count > 60 ? String(String.UnicodeScalarView(scalars.prefix(60))).trimmingCharacters(in: .whitespaces) + "…" : line
        }
        return nil
    }
}

/// Derived display only. Unknown/legacy formats and local OCR remain literal text.
public struct TranscriptContent: Equatable, Sendable {
    public var text: String
    public var format: String?
    public init(text: String, format: String? = nil) { self.text = text; self.format = format }
    public var isMarkdown: Bool { format == "markdown" }
}

/// A small native rendering grammar; it never rewrites the source or follows destinations.
public enum TranscriptMarkdown {
    public enum Alignment: Equatable, Sendable { case leading, center, trailing }
    public enum Block: Equatable, Sendable {
        case line(MarkdownText.Line, indent: Int, checked: Bool?)
        case table(headers: [String], rows: [[String]], alignments: [Alignment])
        case code(String)
    }

    public static func parse(_ source: String) -> [Block] {
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        var blocks: [Block] = [], i = 0
        while i < lines.count {
            let raw = lines[i], trimmed = raw.trimmingCharacters(in: .whitespaces)
            let fence = trimmed.prefix { $0 == "`" || $0 == "~" }
            if fence.count >= 3, Set(fence).count == 1, let marker = fence.first {
                var code: [String] = []; i += 1
                while i < lines.count {
                    let candidate = lines[i].trimmingCharacters(in: .whitespaces)
                    let run = candidate.prefix { $0 == marker }
                    if run.count >= fence.count, candidate.dropFirst(run.count).trimmingCharacters(in: .whitespaces).isEmpty { break }
                    code.append(lines[i]); i += 1
                }
                blocks.append(.code(code.joined(separator: "\n"))); i += 1; continue
            }
            if i + 1 < lines.count, let headers = cells(raw), !headers.isEmpty, let separators = cells(lines[i + 1]), headers.count == separators.count,
               separators.allSatisfy({ $0.range(of: #"^:?-{3,}:?$"#, options: .regularExpression) != nil }) {
                var rows: [[String]] = []; i += 2
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).isEmpty, let row = cells(lines[i]) {
                    rows.append(row); i += 1
                }
                let count = max(headers.count, rows.map(\.count).max() ?? 0)
                let alignments: [Alignment] = separators.map { $0.hasSuffix(":") ? ($0.hasPrefix(":") ? .center : .trailing) : .leading }
                blocks.append(.table(headers: padded(headers, count), rows: rows.map { padded($0, count) },
                    alignments: alignments + Array(repeating: .leading, count: count - alignments.count)))
                continue
            }
            let whitespace = raw.prefix { $0 == " " || $0 == "\t" }
            let indent = whitespace.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
            let body = String(raw.dropFirst(whitespace.count))
            var line = MarkdownText.parse(body)[0], checked: Bool?
            if let range = body.range(of: #"^#{1,6} "#, options: .regularExpression) {
                line = MarkdownText.Line(kind: .heading(level: body[range].count - 1), spans: MarkdownText.parseInline(String(body[range.upperBound...])))
            }
            if case .bullet = line.kind {
                let content = String(body.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                if let range = content.range(of: #"^\[[ xX]\](?:[ \t]+|$)"#, options: .regularExpression) {
                    checked = !content.hasPrefix("[ ]"); line.spans = MarkdownText.parseInline(String(content[range.upperBound...]))
                }
            } else if let range = body.range(of: #"^[0-9]{1,9}\) "#, options: .regularExpression),
                      let number = Int(body[range].dropLast(2)) {
                line = MarkdownText.Line(kind: .numbered(number), spans: MarkdownText.parseInline(String(body[range.upperBound...])))
            }
            // Indent list items, keeping ordinary leading whitespace literal.
            switch line.kind {
            case .bullet, .numbered: blocks.append(.line(line, indent: indent, checked: checked))
            case .heading: blocks.append(.line(line, indent: 0, checked: nil))
            default: blocks.append(.line(MarkdownText.parse(raw)[0], indent: 0, checked: nil))
            }
            i += 1
        }
        return blocks
    }

    private static func padded(_ row: [String], _ count: Int) -> [String] { row + Array(repeating: "", count: count - row.count) }

    /// Keep empty cells and escaped/code-span pipes. Only actual separators define a table.
    private static func cells(_ raw: String) -> [String]? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        var cells: [String] = [], cell = "", escaped = false, codeRun = 0, separatorCount = 0
        let chars = Array(text); var i = 0
        while i < chars.count {
            let char = chars[i]
            if escaped { cell.append(char); escaped = false; i += 1; continue }
            if char == "\\" { cell.append(char); escaped = true; i += 1; continue }
            if char == "`" {
                var run = 1
                while i + run < chars.count, chars[i + run] == "`" { run += 1 }
                if codeRun == 0 { codeRun = run } else if codeRun == run { codeRun = 0 }
                cell += String(repeating: "`", count: run); i += run; continue
            }
            if char == "|", codeRun == 0 { cells.append(cell); cell = ""; separatorCount += 1 }
            else { cell.append(char) }
            i += 1
        }
        guard separatorCount > 0 else { return nil }
        cells.append(cell)
        if text.hasPrefix("|") { cells.removeFirst() }
        if cells.last == "", text.hasSuffix("|") { cells.removeLast() }
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
