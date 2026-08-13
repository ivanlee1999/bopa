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

/// The notebooks and folders staged for deletion, persisted at `<root>/.bopa-trash.json`.
///
/// The file is local, but what it records is **not**: the Trash is a state of the document, and it
/// travels as the `deletedAt` field of the `notebook`/`folder` document (protocol §3.1, §3.2). So
/// throwing something away on the BOOX empties it out of the library here too, and restoring it
/// from either device brings it back on both. `FileCouchStore` is what keeps this file and that
/// field in step, in each direction.
///
/// It stays a dotfile beside `.bopa-sync-state.json` rather than a column in the manifest because
/// the manifest is also the WebDAV wire format, which has no `deletedAt` and must not grow one.
///
/// It is deliberately *not* a staging directory. Moving `notebooks/<id>/` aside would take the
/// notebook out of what sync enumerates, which reads as "this device dropped it" — and the very
/// next pull would download the server's copy straight back, out of the Trash and into the
/// library. A trashed notebook keeps syncing, ink and all; only emptying the Trash deletes it,
/// which writes the tombstone §6.4 describes.
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

    /// Put a notebook in the Trash, or take it out, at a stamp decided elsewhere — the merge,
    /// rather than this device. Nil is "in the library".
    ///
    /// The stamp is written verbatim instead of being re-taken from the clock: it is the peer's
    /// `deletedAt`, and re-stamping it here would make the two devices disagree about when the
    /// notebook was thrown away — which is the value §5.5 compares to decide who wins next.
    public static func setNotebook(_ id: String, deletedAt: String?, root: URL) throws {
        var contents = load(root: root)
        contents.notebooks.removeAll { $0.id == id }
        if let deletedAt { contents.notebooks.append(TrashedItem(id: id, deletedAt: deletedAt)) }
        try save(contents, root: root)
    }

    /// The folder twin of `setNotebook`.
    public static func setFolder(_ id: String, deletedAt: String?, root: URL) throws {
        var contents = load(root: root)
        contents.folders.removeAll { $0.id == id }
        if let deletedAt { contents.folders.append(TrashedItem(id: id, deletedAt: deletedAt)) }
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
