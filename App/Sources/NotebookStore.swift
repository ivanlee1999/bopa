import Foundation
import NotableKit

/// Local notebook repository. Mirrors Notable's server layout on disk
/// (`Documents/notable/notebooks/<id>/manifest.json` + `pages/<pageId>.json`) so that the
/// M3 sync engine reduces to reconciling this directory with the WebDAV `/notable` tree.
@MainActor
final class NotebookStore: ObservableObject {
    /// Posted after any local mutation (a page save, a new notebook, a rename, a delete). The app
    /// listens so automatic sync can push shortly after the writing stops. Deliberately not posted
    /// by `refresh()`, which sync itself calls — that would be a feedback loop.
    static let didChangeLocallyNotification = Notification.Name("dev.ivan.bopa.storeDidChange")

    @Published private(set) var notebooks: [NotebookManifest] = []
    @Published private(set) var folders: [FolderDTO] = []
    /// What the server held at the end of the last sync; nil until this library has
    /// synced at least once. Read-only here — only the sync engine writes it.
    @Published private(set) var remoteIndex: RemoteIndex?

    let rootURL: URL

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.withoutEscapingSlashes]
        return e
    }()
    private let decoder = JSONDecoder()

    init(rootURL: URL? = nil) {
        self.rootURL = rootURL
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("notable", isDirectory: true)
        refresh()
    }

    private func notebookDir(_ id: String) -> URL {
        rootURL.appendingPathComponent("notebooks/\(id)", isDirectory: true)
    }

    nonisolated func notebookDirURL(_ id: String) -> URL {
        rootURL.appendingPathComponent("notebooks/\(id)", isDirectory: true)
    }
    private func manifestURL(_ id: String) -> URL {
        notebookDir(id).appendingPathComponent("manifest.json")
    }
    private func pageURL(notebookId: String, pageId: String) -> URL {
        notebookDir(notebookId).appendingPathComponent("pages/\(pageId).json")
    }
    private var foldersURL: URL {
        rootURL.appendingPathComponent("folders.json")
    }

    /// Which device this is, stamped into everything written so the merge can break ties.
    var deviceID: String = CouchSettings.defaultDeviceID

    /// Called with the CouchDB document ids each mutation touched, so sync can queue exactly
    /// those rather than re-sending the library.
    var didChangeDocuments: (([String]) -> Void)?

    /// `refresh()` plus the local-change signal. Every mutating method ends here; `refresh()`
    /// alone is for readers (and for sync, which must not retrigger itself).
    private func refreshAfterLocalChange(documents: [String] = []) {
        refresh()
        if !documents.isEmpty { didChangeDocuments?(documents) }
        NotificationCenter.default.post(name: Self.didChangeLocallyNotification, object: nil)
    }

    func refresh() {
        let notebooksDir = rootURL.appendingPathComponent("notebooks", isDirectory: true)
        let ids = (try? FileManager.default.contentsOfDirectory(atPath: notebooksDir.path)) ?? []
        notebooks = ids.compactMap { id in
            guard let data = try? Data(contentsOf: manifestURL(id)) else { return nil }
            return try? decoder.decode(NotebookManifest.self, from: data)
        }
        .sorted { ($0.updatedAt, $0.title) > ($1.updatedAt, $1.title) }

        folders = ((try? Data(contentsOf: foldersURL))
            .flatMap { try? decoder.decode(FoldersFile.self, from: $0) }?.folders ?? [])
            .sorted { ($0.title.localizedLowercase, $0.id) < ($1.title.localizedLowercase, $1.id) }

        remoteIndex = RemoteIndex.load(root: rootURL)
    }

    func createNotebook(
        title: String, parentFolderId: String? = nil, template: NativeTemplate = .blank
    ) throws -> NotebookManifest {
        let now = NotableDate.format(Date())
        let notebookId = UUID().uuidString.lowercased()
        let pageId = UUID().uuidString.lowercased()
        let plan = TemplateApplication.plan(pageCount: 1, from: .native(template))
        let pageFields = plan.pages[0]

        let page = PageFile(
            id: pageId, notebookId: notebookId,
            background: pageFields.background, backgroundType: pageFields.backgroundType,
            createdAt: now, updatedAt: now)
        let manifest = NotebookManifest(
            notebookId: notebookId, title: title, pageIds: [pageId], openPageId: pageId,
            parentFolderId: parentFolderId,
            defaultBackground: plan.notebookDefaults.background,
            defaultBackgroundType: plan.notebookDefaults.backgroundType,
            createdAt: now, updatedAt: now, serverTimestamp: now)

        try FileManager.default.createDirectory(
            at: notebookDir(notebookId).appendingPathComponent("pages"),
            withIntermediateDirectories: true)
        try encoder.encode(page).write(to: pageURL(notebookId: notebookId, pageId: pageId))
        try writeManifest(manifest)
        refreshAfterLocalChange(
            documents: [CouchDocID.notebook(notebookId), CouchDocID.page(pageId)])
        return manifest
    }

    func manifest(id: String) -> NotebookManifest? {
        notebooks.first { $0.notebookId == id }
    }

    func loadPage(notebookId: String, pageId: String) throws -> PageFile {
        let data = try Data(contentsOf: pageURL(notebookId: notebookId, pageId: pageId))
        return try decoder.decode(PageFile.self, from: data)
    }

    /// Persists a page and bumps the notebook's `updatedAt` (the sync conflict clock).
    ///
    /// The manifest is re-read from disk rather than taken from `notebooks`: that array is only as
    /// fresh as the last `refresh()`, and sync writes manifests from another thread throughout a
    /// run. Writing a cached copy back would resurrect a stale `pageIds` over a newer one, and the
    /// next upload's orphan cleanup would then delete the pages it omits.
    func savePage(_ page: PageFile) throws {
        guard let notebookId = page.notebookId,
              var manifest = readManifestFromDisk(notebookId)
        else { return }
        var page = page
        let now = NotableDate.format(Date())
        page.updatedAt = now
        page.updatedBy = deviceID

        // Whatever is no longer here was erased. Recording it is what stops the other device's
        // copy of an erased stroke from coming back on the next merge — absence alone cannot be
        // told apart from "that stroke has not reached this device yet".
        let previous = readPageFromDisk(notebookId: notebookId, pageId: page.id)
        page.deletedStrokes = CouchTombstones.derive(
            previousIDs: Set(previous?.strokes.map(\.id) ?? []),
            currentIDs: Set(page.strokes.map(\.id)),
            existing: previous?.deletedStrokes ?? [],
            deletedAt: now)

        try encoder.encode(page)
            .write(to: pageURL(notebookId: notebookId, pageId: page.id), options: .atomic)
        manifest.updatedAt = now
        manifest.updatedBy = deviceID
        try writeManifest(manifest)
        refreshAfterLocalChange(
            documents: [CouchDocID.page(page.id), CouchDocID.notebook(notebookId)])
    }

    private func readPageFromDisk(notebookId: String, pageId: String) -> PageFile? {
        guard let data = try? Data(contentsOf: pageURL(notebookId: notebookId, pageId: pageId))
        else { return nil }
        return try? decoder.decode(PageFile.self, from: data)
    }

    /// The manifest as it is on disk right now. `manifest(id:)` reads the published snapshot and is
    /// right for rendering; this is the one to use before writing.
    private func readManifestFromDisk(_ id: String) -> NotebookManifest? {
        guard let data = try? Data(contentsOf: manifestURL(id)) else { return nil }
        return try? decoder.decode(NotebookManifest.self, from: data)
    }

    /// Appends a page. Its paper follows the notebook's own default (what Notable does);
    /// `fallbackTemplate` applies only when that default is not a native template —
    /// a PDF-backed notebook's per-page PDF binding is not something we can invent here.
    func addPage(to notebookId: String, fallbackTemplate: NativeTemplate = .blank) throws -> PageFile {
        guard var manifest = readManifestFromDisk(notebookId) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let now = NotableDate.format(Date())
        let notebookDefault = PageBackground(
            background: manifest.defaultBackground, backgroundType: manifest.defaultBackgroundType)
        let template: NativeTemplate
        if case .native(let native) = notebookDefault {
            template = native
        } else {
            template = fallbackTemplate
        }
        let fields = TemplateApplication.pageFields(for: .native(template))
        let page = PageFile(
            id: UUID().uuidString.lowercased(), notebookId: notebookId,
            background: fields.background, backgroundType: fields.backgroundType,
            createdAt: now, updatedAt: now)
        try encoder.encode(page)
            .write(to: pageURL(notebookId: notebookId, pageId: page.id), options: .atomic)
        manifest.pageIds.append(page.id)
        manifest.updatedAt = now
        manifest.updatedBy = deviceID
        try writeManifest(manifest)
        refreshAfterLocalChange(
            documents: [CouchDocID.notebook(notebookId), CouchDocID.page(page.id)])
        return page
    }

    /// Atomic, because the sync engine reads these files from another thread: a torn read makes
    /// `loadPage` throw, and the editor's error path drops whatever strokes were pending.
    private func writeManifest(_ manifest: NotebookManifest) throws {
        try FileManager.default.createDirectory(
            at: notebookDir(manifest.notebookId), withIntermediateDirectories: true)
        try encoder.encode(manifest).write(to: manifestURL(manifest.notebookId), options: .atomic)
    }

    // MARK: - Notebook management

    func renameNotebook(id: String, title: String) throws {
        guard var manifest = manifest(id: id) else { throw CocoaError(.fileNoSuchFile) }
        manifest.title = title
        manifest.updatedAt = NotableDate.format(Date())
        manifest.updatedBy = deviceID
        try writeManifest(manifest)
        refreshAfterLocalChange(documents: [CouchDocID.notebook(id)])
    }

    func moveNotebook(id: String, toFolder folderId: String?) throws {
        guard var manifest = manifest(id: id) else { throw CocoaError(.fileNoSuchFile) }
        manifest.parentFolderId = folderId
        manifest.updatedAt = NotableDate.format(Date())
        manifest.updatedBy = deviceID
        try writeManifest(manifest)
        refreshAfterLocalChange(documents: [CouchDocID.notebook(id)])
    }

    /// Removes the local directory and records the id as a pending deletion; the sync
    /// engine uploads the tombstone at the start of the next sync (works offline).
    func deleteNotebook(id: String) throws {
        let pageIds = readManifestFromDisk(id)?.pageIds ?? []
        try FileManager.default.removeItem(at: notebookDir(id))
        PendingDeletions.add(id, root: rootURL)
        // The pages go with it, so name them too: the engine has to stop tracking them, and a
        // page left queued would be pushed back under a notebook that no longer exists.
        refreshAfterLocalChange(
            documents: [CouchDocID.notebook(id)] + pageIds.map(CouchDocID.page))
    }

    // MARK: - Folders

    @discardableResult
    func createFolder(title: String, parentFolderId: String? = nil) throws -> FolderDTO {
        let now = NotableDate.format(Date())
        let folder = FolderDTO(
            id: UUID().uuidString.lowercased(), title: title,
            parentFolderId: parentFolderId, createdAt: now, updatedAt: now)
        try writeFolders(folders + [folder])
        return folder
    }

    func renameFolder(id: String, title: String) throws {
        var all = folders
        guard let index = all.firstIndex(where: { $0.id == id }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        all[index].title = title
        all[index].updatedAt = NotableDate.format(Date())
        try writeFolders(all)
    }

    /// Only empty folders (no subfolders, no notebooks) may be deleted.
    func deleteFolder(id: String) throws {
        guard isFolderEmpty(id) else { throw CocoaError(.fileWriteInvalidFileName) }
        try writeFolders(folders.filter { $0.id != id })
    }

    private func writeFolders(_ folders: [FolderDTO]) throws {
        let file = FoldersFile(
            folders: folders.sorted { $0.id < $1.id },
            serverTimestamp: NotableDate.format(Date()))
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try encoder.encode(file).write(to: foldersURL)
        refreshAfterLocalChange(documents: folders.map { CouchDocID.folder($0.id) })
    }

    // MARK: - Folder queries

    func folders(in parentFolderId: String?) -> [FolderDTO] {
        folders.filter { $0.parentFolderId == parentFolderId }
    }

    func notebooks(in parentFolderId: String?) -> [NotebookManifest] {
        notebooks.filter { $0.parentFolderId == parentFolderId }
    }

    func folder(id: String) -> FolderDTO? {
        folders.first { $0.id == id }
    }

    /// Direct children (subfolders + notebooks) of a folder.
    func itemCount(in folderId: String) -> Int {
        folders(in: folderId).count + notebooks(in: folderId).count
    }

    func isFolderEmpty(_ id: String) -> Bool {
        itemCount(in: id) == 0
    }

    /// Notebooks anywhere in the library, used by the sidebar's "All Notes" count.
    var totalNotebookCount: Int { notebooks.count }

    // MARK: - Sync provenance

    /// Whether a notebook exists on the WebDAV server as of the last completed sync.
    func provenance(ofNotebook id: String) -> SyncProvenance {
        guard let remoteIndex else { return .unknown }
        return remoteIndex.hasNotebook(id) ? .onServer : .localOnly
    }

    /// Whether a folder appears in the server's `folders.json` as of the last sync.
    func provenance(ofFolder id: String) -> SyncProvenance {
        guard let remoteIndex else { return .unknown }
        return remoteIndex.hasFolder(id) ? .onServer : .localOnly
    }

    /// True once a sync has recorded a remote index — the cue for showing badges at all.
    var hasSyncedAtLeastOnce: Bool { remoteIndex != nil }
}
