import Foundation

/// Local conservative matching. Names are canonical labels, not raw tag-field input.
public func contentTags(text: String, known: [String]) -> [String] {
    var fence: (marker: Character, count: Int)?
    let prose = text.components(separatedBy: .newlines).map { line -> String in
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let marker = trimmed.first.flatMap { $0 == "`" || $0 == "~" ? $0 : nil }
        let count = marker.map { marker in trimmed.prefix { $0 == marker }.count } ?? 0
        if let open = fence {
            if marker == open.marker, count >= open.count,
               trimmed.dropFirst(count).trimmingCharacters(in: .whitespaces).isEmpty { fence = nil }
            return ""
        }
        if let marker, count >= 3 { fence = (marker, count); return "" }
        return line
    }.joined(separator: "\n")
    var source = prose.precomposedStringWithCanonicalMapping
    for pattern in [#"`+[^`\n]*`+"#, #"(?:https?://|www\.)\S+|(?<!\S)\S+@\S+"#] {
        source = source.replacingOccurrences(of: pattern, with: " ", options: [.regularExpression, .caseInsensitive])
    }
    let folded = contentTagKey(source)
    var names: [String: String] = [:]
    for name in known.sorted() where names[contentTagKey(name)] == nil { names[contentTagKey(name)] = name }
    var result: [String] = [], found = Set<String>()
    for key in names.keys.sorted() {
        let name = names[key]!
        guard !name.hasPrefix("#"), name.unicodeScalars.count >= 2 else { continue }
        let phrase = key.components(separatedBy: " ").map(NSRegularExpression.escapedPattern(for:)).joined(separator: #"\s+"#)
        let pattern = #"(?<![\p{L}\p{M}\p{N}_#])"# + phrase + #"(?![\p{L}\p{M}\p{N}_/-])"#
        if folded.range(of: pattern, options: .regularExpression) != nil {
            result.append(name); found.insert(key)
        }
    }
    let expression = try! NSRegularExpression(pattern: #"(?<![\p{L}\p{M}\p{N}_#\\])#([\p{L}\p{N}_][\p{L}\p{M}\p{N}_/-]*)"#)
    for match in expression.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
        guard let range = Range(match.range(at: 1), in: source) else { continue }
        let name = String(source[range]).replacingOccurrences(of: #"[-/]+$"#, with: "", options: .regularExpression)
        guard name.unicodeScalars.count <= 64 else { continue }
        let key = contentTagKey(name)
        if found.insert(key).inserted { result.append(names[key] ?? name) }
    }
    return result
}

private func contentTagKey(_ name: String) -> String {
    String(String.UnicodeScalarView(name.unicodeScalars.map { scalar in
        (65...90).contains(scalar.value) ? Unicode.Scalar(scalar.value + 32)! : scalar
    }))
}
