import CryptoKit
import Foundation

/// Exact source snapshots retained when text revisions meet during a merge.
public enum TextVersions {
    public static let kind = "text-version"
    private static let prefix = "\(kind):"

    public static func fingerprint(_ source: String) -> String {
        SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public static func versionID(sourceID: String, text: String) -> String {
        "\(prefix)\(sourceID):\(fingerprint(text))"
    }

    public static func sourceID(_ versionID: String) -> String? {
        guard versionID.hasPrefix(prefix), let end = versionID.lastIndex(of: ":") else { return nil }
        let start = versionID.index(versionID.startIndex, offsetBy: prefix.count)
        guard end > start else { return nil }
        let digest = versionID[versionID.index(after: end)...]
        guard digest.utf8.count == 64, digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        return String(versionID[start..<end])
    }

    /// Swift String equality folds canonical Unicode spellings; source snapshots must not.
    public static func sameSource(_ a: String?, _ b: String?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (a?, b?): return a.utf8.elementsEqual(b.utf8)
        default: return false
        }
    }

    public static func conflicts(baseText: String?, currentText: String?, draftText: String) -> Bool {
        !sameSource(currentText, baseText) && !sameSource(currentText, draftText)
    }

    public static func recovery(_ block: CouchBlock) -> CouchBlock {
        precondition(block.kind == "md" && block.text != nil)
        var version = block
        version.id = versionID(sourceID: block.id, text: block.text!)
        version.kind = kind
        return version
    }

    /// Both heads join history after divergent source, removal, or a change of block kind.
    /// Existing versions (including their tombstones) retain that marker for subsequent merges.
    /// See the Kotlin twin: loser-only archives are not associative across deletion or later
    /// equal-text updates. Copying all metadata also preserves the original block's LWW order.
    static func recoveries(_ a: [CouchBlock], _ b: [CouchBlock], removed: Set<String>) -> [CouchBlock] {
        let observed = a + b
        let history = Set(observed.filter { $0.kind == kind }.compactMap { sourceID($0.id) } + removed.compactMap(sourceID))
        let groups = Dictionary(grouping: observed.filter { $0.kind != kind }, by: \.id)
        return groups.flatMap { id, heads -> [CouchBlock] in
            let markdown = heads.contains { $0.kind == "md" && $0.text != nil }
            let distinct = Set(heads.map { $0.text.map(fingerprint) }).count > 1
            let crossing = heads.contains { $0.kind != "md" }
            if history.contains(id) || (markdown && (removed.contains(id) || distinct || crossing)) {
                return heads.filter { $0.kind == "md" && $0.text != nil }.map(recovery)
            }
            return []
        }
    }
}
