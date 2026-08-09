import Foundation

/// What the WebDAV server held at the end of the last completed sync: the notebook ids
/// under `/notable/notebooks/` and the folder ids inside `/notable/folders.json`.
///
/// Persisted at `<root>/.bopa-remote-index.json` (dotfile — never uploaded, like
/// `.bopa-sync-state.json`). This is the app's read-only view of sync *provenance*: an id
/// present here exists on the server, an id missing from here is local-only and will be
/// uploaded on the next sync. Deliberately separate from `.bopa-sync-state.json`, whose
/// schema is the planner's private business.
public struct RemoteIndex: Codable, Equatable, Sendable {
    public static let fileName = ".bopa-remote-index.json"

    public var version: Int
    /// Notebook ids present under `/notable/notebooks/` after the last sync.
    public var notebookIds: Set<String>
    /// Folder ids present in the server's `folders.json` after the last sync.
    public var folderIds: Set<String>
    /// ISO-8601 UTC timestamp of the sync that produced this index.
    public var syncedAt: String

    public init(
        version: Int = 1,
        notebookIds: Set<String> = [],
        folderIds: Set<String> = [],
        syncedAt: String
    ) {
        self.version = version
        self.notebookIds = notebookIds
        self.folderIds = folderIds
        self.syncedAt = syncedAt
    }

    public func hasNotebook(_ id: String) -> Bool { notebookIds.contains(id) }
    public func hasFolder(_ id: String) -> Bool { folderIds.contains(id) }

    // MARK: - Persistence

    public static func fileURL(root: URL) -> URL {
        root.appendingPathComponent(fileName)
    }

    /// Reads the index written by the last sync, or nil when this root has never synced
    /// (in which case provenance is simply unknown — not "local only").
    public static func load(root: URL) -> RemoteIndex? {
        guard let data = try? Data(contentsOf: fileURL(root: root)) else { return nil }
        return try? JSONDecoder().decode(RemoteIndex.self, from: data)
    }

    public func save(root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: Self.fileURL(root: root))
    }

    // MARK: - Codable

    // Sets encode in arbitrary order; sort on the way out so the file is stable and
    // diffable, and accept plain arrays on the way in.
    private enum CodingKeys: String, CodingKey {
        case version, notebookIds, folderIds, syncedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        notebookIds = Set(try c.decodeIfPresent([String].self, forKey: .notebookIds) ?? [])
        folderIds = Set(try c.decodeIfPresent([String].self, forKey: .folderIds) ?? [])
        syncedAt = try c.decodeIfPresent(String.self, forKey: .syncedAt) ?? ""
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(notebookIds.sorted(), forKey: .notebookIds)
        try c.encode(folderIds.sorted(), forKey: .folderIds)
        try c.encode(syncedAt, forKey: .syncedAt)
    }
}
