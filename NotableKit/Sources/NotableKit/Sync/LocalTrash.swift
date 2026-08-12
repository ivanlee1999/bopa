import Foundation

/// One thing waiting in the Trash.
public struct TrashedItem: Codable, Equatable, Sendable {
    public let id: String
    /// ISO-8601, the same stamp format as everything else written here.
    public let deletedAt: String

    public init(id: String, deletedAt: String) {
        self.id = id
        self.deletedAt = deletedAt
    }
}

/// The notebooks and folders staged for deletion on this device, persisted at
/// `<root>/.bopa-trash.json`.
///
/// A dotfile, like `.bopa-sync-state.json` and `.bopa-pending-deletions.json`, and for the same
/// reason: it is this device's private bookkeeping and is never uploaded. That is the whole design
/// of the Trash — a trashed notebook's directory stays exactly where it was and keeps syncing,
/// because it has not been deleted anywhere yet. A peer that still holds it is not wrong, and
/// restoring is one line leaving this file rather than a second set of files to move back.
///
/// It is deliberately *not* a staging directory. Moving `notebooks/<id>/` aside would take the
/// notebook out of what sync enumerates, which reads as "this device dropped it" — and the very
/// next pull would download the server's copy straight back, out of the Trash and into the
/// library. Deletion only becomes a fact for peers on purge, where a tombstone is written.
///
/// The twin of Notable's `Folder.deletedAt` / `Notebook.deletedAt` columns.
public enum LocalTrash {
    public static func fileURL(root: URL) -> URL {
        root.appendingPathComponent(".bopa-trash.json")
    }

    public struct Contents: Codable, Equatable, Sendable {
        public var notebooks: [TrashedItem]
        public var folders: [TrashedItem]

        public init(notebooks: [TrashedItem] = [], folders: [TrashedItem] = []) {
            self.notebooks = notebooks
            self.folders = folders
        }

        public var isEmpty: Bool { notebooks.isEmpty && folders.isEmpty }
        public var count: Int { notebooks.count + folders.count }

        public var notebookIDs: Set<String> { Set(notebooks.map(\.id)) }
        public var folderIDs: Set<String> { Set(folders.map(\.id)) }
    }

    public static func load(root: URL) -> Contents {
        guard let data = try? Data(contentsOf: fileURL(root: root)),
              let contents = try? JSONDecoder().decode(Contents.self, from: data)
        else { return Contents() }
        return contents
    }

    /// Persist, or delete the file when nothing is left — an empty Trash should leave no trace.
    ///
    /// Throws, unlike `PendingDeletions.save`: this is the record of what the user asked to
    /// delete, and a write that silently did nothing would put the item back in the library with
    /// no explanation. Every caller here surfaces the failure.
    public static func save(_ contents: Contents, root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = fileURL(root: root)
        if contents.isEmpty {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        } else {
            try JSONEncoder().encode(contents).write(to: url, options: .atomic)
        }
    }

    public static func addNotebook(_ id: String, at date: Date, root: URL) throws {
        var contents = load(root: root)
        guard !contents.notebookIDs.contains(id) else { return }
        contents.notebooks.append(TrashedItem(id: id, deletedAt: NotableDate.format(date)))
        try save(contents, root: root)
    }

    public static func addFolder(_ id: String, at date: Date, root: URL) throws {
        var contents = load(root: root)
        guard !contents.folderIDs.contains(id) else { return }
        contents.folders.append(TrashedItem(id: id, deletedAt: NotableDate.format(date)))
        try save(contents, root: root)
    }

    public static func removeNotebook(_ id: String, root: URL) throws {
        var contents = load(root: root)
        contents.notebooks.removeAll { $0.id == id }
        try save(contents, root: root)
    }

    public static func removeFolder(_ id: String, root: URL) throws {
        var contents = load(root: root)
        contents.folders.removeAll { $0.id == id }
        try save(contents, root: root)
    }

    /// Drop several at once, so emptying the Trash is one write rather than one per item.
    public static func remove(
        notebookIDs: Set<String>, folderIDs: Set<String>, root: URL
    ) throws {
        var contents = load(root: root)
        contents.notebooks.removeAll { notebookIDs.contains($0.id) }
        contents.folders.removeAll { folderIDs.contains($0.id) }
        try save(contents, root: root)
    }
}
