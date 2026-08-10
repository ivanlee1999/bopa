import Foundation

/// `CouchLocalStore` over bopa's notebook directory — the bridge between the sync engine and
/// what the app actually reads and writes.
///
/// Deliberately talks to the filesystem rather than to `NotebookStore`: the engine runs off the
/// main actor and must not touch the store's published state, and reading the file is also the
/// only way to see writes the editor made after the last `refresh()`. The app is told to reload
/// afterwards via `didApplyChanges`.
///
/// Layout (same as the WebDAV engine used, so nothing had to move):
///
///     <root>/folders.json
///     <root>/notebooks/<notebookId>/manifest.json
///     <root>/notebooks/<notebookId>/pages/<pageId>.json
///     <root>/.bopa-couch-deletions.json     — local tombstones awaiting push
public final class FileCouchStore: CouchLocalStore, @unchecked Sendable {
    public let rootURL: URL
    public let deviceID: String
    /// Called after any change the engine applied, so the UI can reload. Never called for reads.
    public var didApplyChanges: (@Sendable () -> Void)?

    private let lock = NSLock()
    /// pageId → notebookId. A page document names only the page, but its file lives under the
    /// notebook, so the directory has to be searched; the answer is worth keeping.
    private var pageIndex: [String: String] = [:]

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }()
    private let decoder = JSONDecoder()

    public init(rootURL: URL, deviceID: String) {
        self.rootURL = rootURL
        self.deviceID = deviceID
    }

    // MARK: Paths

    private var notebooksURL: URL { rootURL.appendingPathComponent("notebooks", isDirectory: true) }
    private var foldersURL: URL { rootURL.appendingPathComponent("folders.json") }
    private var deletionsURL: URL { rootURL.appendingPathComponent(".bopa-couch-deletions.json") }

    private func notebookDir(_ id: String) -> URL {
        notebooksURL.appendingPathComponent(id, isDirectory: true)
    }
    private func manifestURL(_ id: String) -> URL {
        notebookDir(id).appendingPathComponent("manifest.json")
    }
    private func pageURL(notebookId: String, pageId: String) -> URL {
        notebookDir(notebookId).appendingPathComponent("pages/\(pageId).json")
    }

    // MARK: CouchLocalStore

    public func load(_ documentID: String) throws -> CouchDocBody? {
        guard let (type, id) = CouchDocID.split(documentID) else { return nil }

        // A local deletion outranks whatever is still on disk: the directory may not have been
        // reaped yet, and the engine needs to push the tombstone regardless.
        if let deletedAt = deletions()[documentID] {
            return .deleted(CouchDeletedDoc(
                type: type, deletedAt: deletedAt, updatedBy: deviceID))
        }

        switch type {
        case CouchDocType.notebook:
            guard let manifest = readManifest(id) else { return nil }
            return .notebook(CouchMapping.couchNotebook(from: manifest, deviceID: deviceID))

        case CouchDocType.page:
            guard let notebookId = notebookID(forPage: id),
                  let page = readPage(notebookId: notebookId, pageId: id)
            else { return nil }
            return .page(CouchMapping.couchPage(from: page, deviceID: deviceID))

        case CouchDocType.folder:
            guard let folder = readFolders().first(where: { $0.id == id }) else { return nil }
            return .folder(CouchMapping.couchFolder(from: folder, deviceID: deviceID))

        default:
            return nil
        }
    }

    public func apply(_ documentID: String, _ body: CouchDocBody) throws {
        guard let (type, id) = CouchDocID.split(documentID) else { return }

        switch body {
        case .page(let page):
            guard let notebookId = page.notebookId ?? notebookID(forPage: id) else { return }
            let existing = readPage(notebookId: notebookId, pageId: id)
            let file = CouchMapping.pageFile(from: page, id: id, existing: existing)
            try write(encoder.encode(file), to: pageURL(notebookId: notebookId, pageId: id))
            lock.withLock { pageIndex[id] = notebookId }

        case .notebook(let notebook):
            let existing = readManifest(id)
            let manifest = CouchMapping.manifest(from: notebook, id: id, existing: existing)
            try write(encoder.encode(manifest), to: manifestURL(id))
            // A notebook arriving from the server un-deletes it here — that decision was already
            // made by the merge, which resurrects only when the edit is newer than the deletion.
            clearDeletion(documentID)

        case .folder(let folder):
            var folders = readFolders().filter { $0.id != id }
            folders.append(CouchMapping.folderDTO(from: folder, id: id))
            try writeFolders(folders)
            clearDeletion(documentID)

        case .deleted:
            switch type {
            case CouchDocType.notebook:
                try? FileManager.default.removeItem(at: notebookDir(id))
                lock.withLock { pageIndex = pageIndex.filter { $0.value != id } }
            case CouchDocType.folder:
                try writeFolders(readFolders().filter { $0.id != id })
            default:
                break
            }
            // The tombstone is dropped, not kept: it came *from* the server, so there is nothing
            // left to push. Locally-initiated deletions go through `recordDeletion` instead.
            clearDeletion(documentID)
        }
        didApplyChanges?()
    }

    /// Protocol §6.5. The local copy is left exactly as it is and the remote one is written
    /// alongside under a fresh identity, so a document this build cannot understand costs the
    /// user a duplicate rather than their work.
    public func applyConflictCopy(_ documentID: String, json: Data) throws {
        guard let (type, _) = CouchDocID.split(documentID), type == CouchDocType.page ||
                type == CouchDocType.notebook
        else { return }

        let stamp = ISO8601DateFormatter().string(from: Date()).prefix(10)
        let newNotebookId = UUID().uuidString.lowercased()
        let newPageId = UUID().uuidString.lowercased()
        let now = NotableDate.format(Date())

        // Whatever could not be decoded is preserved verbatim next to the notebook, because the
        // point of this path is that we do not understand it well enough to rewrite it.
        let manifest = NotebookManifest(
            notebookId: newNotebookId,
            title: "Unreadable sync copy (\(stamp))",
            pageIds: [newPageId],
            createdAt: now, updatedAt: now, serverTimestamp: now, updatedBy: deviceID)
        let page = PageFile(
            id: newPageId, notebookId: newNotebookId, createdAt: now, updatedAt: now,
            updatedBy: deviceID)

        try write(encoder.encode(manifest), to: manifestURL(newNotebookId))
        try write(encoder.encode(page), to: pageURL(notebookId: newNotebookId, pageId: newPageId))
        try write(json, to: notebookDir(newNotebookId)
            .appendingPathComponent("original-\(documentID.replacingOccurrences(of: ":", with: "-")).json"))
        didApplyChanges?()
    }

    // MARK: Local deletions

    /// Records a locally-initiated deletion so the engine pushes a tombstone. Survives a restart,
    /// which is what makes deleting a notebook while offline work.
    public func recordDeletion(_ documentID: String, deletedAt: String? = nil) {
        var all = deletions()
        all[documentID] = deletedAt ?? NotableDate.format(Date())
        writeDeletions(all)
    }

    public func pendingDeletionIDs() -> [String] {
        deletions().keys.sorted()
    }

    private func clearDeletion(_ documentID: String) {
        var all = deletions()
        guard all.removeValue(forKey: documentID) != nil else { return }
        writeDeletions(all)
    }

    private func deletions() -> [String: String] {
        lock.withLock {
            guard let data = try? Data(contentsOf: deletionsURL),
                  let all = try? decoder.decode([String: String].self, from: data)
            else { return [:] }
            return all
        }
    }

    private func writeDeletions(_ all: [String: String]) {
        lock.withLock {
            guard let data = try? encoder.encode(all) else { return }
            try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
            try? data.write(to: deletionsURL, options: .atomic)
        }
    }

    // MARK: Enumerating what is here

    /// Every document this device holds, for the first push after setup.
    public func allDocumentIDs() -> [String] {
        var ids: [String] = readFolders().map { CouchDocID.folder($0.id) }
        for notebookId in notebookIDs() {
            ids.append(CouchDocID.notebook(notebookId))
            guard let manifest = readManifest(notebookId) else { continue }
            ids.append(contentsOf: manifest.pageIds.map(CouchDocID.page))
        }
        return (ids + pendingDeletionIDs()).sorted()
    }

    private func notebookIDs() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: notebooksURL.path))?
            .filter { FileManager.default.fileExists(atPath: manifestURL($0).path) } ?? []
    }

    // MARK: Reading

    private func readManifest(_ id: String) -> NotebookManifest? {
        guard let data = try? Data(contentsOf: manifestURL(id)) else { return nil }
        return try? decoder.decode(NotebookManifest.self, from: data)
    }

    private func readPage(notebookId: String, pageId: String) -> PageFile? {
        guard let data = try? Data(contentsOf: pageURL(notebookId: notebookId, pageId: pageId))
        else { return nil }
        return try? decoder.decode(PageFile.self, from: data)
    }

    private func readFolders() -> [FolderDTO] {
        guard let data = try? Data(contentsOf: foldersURL),
              let file = try? decoder.decode(FoldersFile.self, from: data)
        else { return [] }
        return file.folders
    }

    private func writeFolders(_ folders: [FolderDTO]) throws {
        let file = FoldersFile(
            folders: folders.sorted { $0.id < $1.id },
            serverTimestamp: NotableDate.format(Date()))
        try write(encoder.encode(file), to: foldersURL)
    }

    /// Resolves which notebook owns a page, consulting the cache before walking the directory.
    private func notebookID(forPage pageId: String) -> String? {
        if let cached = lock.withLock({ pageIndex[pageId] }) { return cached }
        for notebookId in notebookIDs() {
            if FileManager.default.fileExists(
                atPath: pageURL(notebookId: notebookId, pageId: pageId).path) {
                lock.withLock { pageIndex[pageId] = notebookId }
                return notebookId
            }
        }
        // Fall back to the manifests: a page may be listed before its file has been written.
        for notebookId in notebookIDs() where readManifest(notebookId)?.pageIds.contains(pageId) == true {
            lock.withLock { pageIndex[pageId] = notebookId }
            return notebookId
        }
        return nil
    }

    private func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Atomic because the editor reads these files on another thread; a torn read makes the
        // page fail to load and drops whatever strokes were pending.
        try data.write(to: url, options: .atomic)
    }
}
