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

    /// Posted after *sync* wrote files underneath the app — the CouchDB pull loop applying merged
    /// documents. The editor listens so ink that arrived while a page was open reaches the canvas
    /// instead of sitting in a file nobody re-reads. Deliberately separate from
    /// `didChangeLocallyNotification`, which is the push trigger and must not fire for downloads.
    static let didApplyRemoteChangesNotification =
        Notification.Name("dev.ivan.bopa.storeDidApplyRemoteChanges")

    @Published private(set) var notebooks: [NotebookManifest] = []
    @Published private(set) var folders: [FolderDTO] = []
    /// What the WebDAV server held at the end of the last sync; nil until this library has
    /// synced at least once. Read-only here — only the sync engine writes it.
    @Published private(set) var remoteIndex: RemoteIndex?

    /// The same fact under CouchDB: the ids of the documents the server has a revision for. That
    /// backend writes no `RemoteIndex` — its equivalent record is the rev map in the sync state —
    /// so it is handed in here instead. Nil unless CouchDB is the selected backend, which is what
    /// stops a `RemoteIndex` left behind by earlier WebDAV use from answering for a library that
    /// no longer syncs that way, and vice versa.
    @Published private(set) var remoteDocumentIDs: Set<String>?

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

    /// Called with the CouchDB document ids a local *deletion* removed, so sync can record the
    /// durable tombstone that makes the deletion travel. Fired from the store rather than from the
    /// menu item that asked for it: "absent from a list" is not something the peer can tell apart
    /// from "not arrived yet", so a call site that forgot left the document live on the server and
    /// it came back on the next pull — which is exactly what the sidebar's delete used to do.
    ///
    /// Deleting through the store is now the only way to reach it, so there is nothing left to
    /// forget.
    var didDeleteDocuments: (([String]) -> Void)?

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

    /// - Parameter pageSize: the sheet every page here is laid out on, recorded on the notebook
    ///   and stamped onto each page it creates. Both apps read it from the page, so this is the
    ///   one moment the choice is made — an existing notebook keeps the geometry it was written
    ///   with, including the notebooks that predate the field and declare nothing at all.
    func createNotebook(
        title: String, parentFolderId: String? = nil, template: NativeTemplate = .blank,
        pageSize: PageSize = PageSizePreset.default.size
    ) throws -> NotebookManifest {
        let now = NotableDate.format(Date())
        let notebookId = UUID().uuidString.lowercased()
        let pageId = UUID().uuidString.lowercased()
        let plan = TemplateApplication.plan(pageCount: 1, from: .native(template))
        let pageFields = plan.pages[0]

        let page = PageFile(
            id: pageId, notebookId: notebookId,
            background: pageFields.background, backgroundType: pageFields.backgroundType,
            pageWidth: pageSize.width, pageHeight: pageSize.height,
            createdAt: now, updatedAt: now)
        let manifest = NotebookManifest(
            notebookId: notebookId, title: title, pageIds: [pageId], openPageId: pageId,
            parentFolderId: parentFolderId,
            defaultBackground: plan.notebookDefaults.background,
            defaultBackgroundType: plan.notebookDefaults.backgroundType,
            defaultPageWidth: pageSize.width, defaultPageHeight: pageSize.height,
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
    ///
    /// The page is reconciled against the file rather than written over it, by the same rule the
    /// CouchDB merge uses: erasure beats drawing, everything else survives. That is needed because
    /// the CouchDB backend has no equivalent of the WebDAV engine's `uploadOnly` guard — its pull
    /// loop applies merged documents to disk while the editor holds a page open — so by the time an
    /// autosave lands, the file can hold ink this caller never saw.
    ///
    /// - Parameter baselineStrokeIDs: the ids the caller was working from, i.e. what it loaded or
    ///   last wrote. The file is *not* a safe stand-in: diffing against ink that arrived from the
    ///   BOOX would read it as ink the user erased and tombstone it on every device. Pass nil only
    ///   when the caller holds nothing in memory across the read and the write.
    /// - Returns: the page as it was actually written — the caller's content plus whatever landed
    ///   underneath it, which is what the caller must hold from here on.
    @discardableResult
    func savePage(_ page: PageFile, baselineStrokeIDs: Set<String>? = nil) throws -> PageFile {
        guard let notebookId = page.notebookId,
              var manifest = readManifestFromDisk(notebookId)
        else { return page }
        var page = page
        let now = NotableDate.format(Date())
        page.updatedAt = now
        page.updatedBy = deviceID

        let onDisk = readPageFromDisk(notebookId: notebookId, pageId: page.id)
        let baseline = baselineStrokeIDs ?? Set(onDisk?.strokes.map(\.id) ?? [])
        let saved = Set(page.strokes.map(\.id))

        // Nothing in this app names a page, so the caller's `title` is at best as fresh as the
        // file's and at worst stale — a rename that arrived from the BOOX while the page was open.
        // Taking the file's value stops an autosave from undoing it, the same way the stroke
        // fold-back below stops one from undoing the BOOX's ink.
        page.title = onDisk?.title ?? page.title
        // A page's sheet is set when it is created and never edited here, so the file's
        // declaration is at least as fresh as the caller's — and an autosave must not be able to
        // un-declare a size the merge just wrote, which would reflow the page under the ink.
        page.pageWidth = onDisk?.pageWidth ?? page.pageWidth
        page.pageHeight = onDisk?.pageHeight ?? page.pageHeight

        // Whatever the caller *had* and no longer has was erased. Recording it is what stops the
        // other device's copy of an erased stroke from coming back on the next merge — absence
        // alone cannot be told apart from "that stroke has not reached this device yet".
        page.deletedStrokes = CouchTombstones.derive(
            previousIDs: baseline,
            currentIDs: saved,
            existing: onDisk?.deletedStrokes ?? [],
            deletedAt: now)
        let erased = Set(page.deletedStrokes.map(\.id))

        // Erasure beats drawing: a stroke the other device tombstoned goes, even though this
        // caller still holds it.
        page.strokes.removeAll { erased.contains($0.id) }
        // Ink that reached this file after the caller loaded it was never the caller's to drop, so
        // it is folded back in rather than overwritten. Appended rather than sorted in: the merge
        // imposes the canonical z-order, and re-sorting here would shuffle the user's own ink.
        page.strokes += (onDisk?.strokes ?? []).filter {
            !saved.contains($0.id) && !baseline.contains($0.id) && !erased.contains($0.id)
        }
        // Images travel the same way and the editor never removes them, so an add-wins union is
        // the whole rule (the page format carries no image tombstones).
        let savedImages = Set(page.images.map(\.id))
        page.images += (onDisk?.images ?? []).filter { !savedImages.contains($0.id) }

        try encoder.encode(page)
            .write(to: pageURL(notebookId: notebookId, pageId: page.id), options: .atomic)
        manifest.updatedAt = now
        manifest.updatedBy = deviceID
        try writeManifest(manifest)
        refreshAfterLocalChange(
            documents: [CouchDocID.page(page.id), CouchDocID.notebook(notebookId)])
        return page
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
        // The sheet follows the notebook the same way the paper does. A notebook that declares
        // none keeps declaring none: page sizes are not retrofitted onto old notebooks, so a
        // notebook does not end up half-A4 and half-legacy.
        let pageSize = manifest.declaredDefaultPageSize
        let page = PageFile(
            id: UUID().uuidString.lowercased(), notebookId: notebookId,
            background: fields.background, backgroundType: fields.backgroundType,
            pageWidth: pageSize?.width, pageHeight: pageSize?.height,
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
        // Only once the files are actually gone, and before the change signal: a tombstone is
        // authoritative the moment it is written, so recording one for a removal that threw would
        // publish a deletion this device never made — while a push that ran before it existed
        // would load nothing, take that for "never created", and drop the id from the outbox.
        didDeleteDocuments?([CouchDocID.notebook(id)])
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
        try writeFolders(folders.filter { $0.id != id }, deleting: [CouchDocID.folder(id)])
    }

    /// - Parameter deleting: ids this write *removes* from the file. They have to be named
    ///   separately because the list itself only says which folders survive, and a deleted folder
    ///   is by definition not in it — so the one id that most needs syncing was the one id never
    ///   reported, and the folder simply stayed on the server.
    private func writeFolders(_ folders: [FolderDTO], deleting: [String] = []) throws {
        let file = FoldersFile(
            folders: folders.sorted { $0.id < $1.id },
            serverTimestamp: NotableDate.format(Date()))
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try encoder.encode(file).write(to: foldersURL)
        // Tombstones before the change signal, for the same reason as a notebook's: the folder is
        // already out of the file, so a push that got there first would find nothing to send.
        if !deleting.isEmpty { didDeleteDocuments?(deleting) }
        refreshAfterLocalChange(documents: folders.map { CouchDocID.folder($0.id) } + deleting)
    }

    // MARK: - Folder queries

    /// Ids of the folders the root has to show, because nothing else will.
    ///
    /// A folder can stop reaching the root without anything local going wrong: the peer is allowed
    /// to delete a folder that still has children here (protocol §6.4 deletes the folder alone),
    /// and a half-merged `folders.json` can leave a chain pointing at nothing or looping back on
    /// itself. The merge deliberately repairs neither — the library absorbs it. Hiding the
    /// remainder would lose real notebooks whose files are still on disk.
    ///
    /// Adoption is deliberately *not* "every folder that cannot reach the root": in an orphaned
    /// subtree every descendant fails that test too, and adopting them all would list each one at
    /// the root as well as under its own parent. Only the folders with nowhere else to appear are
    /// taken — the ones whose parent id names no folder we hold, plus one entry point per cycle,
    /// without which a loop would have no way in at all. Everything below them nests as usual, so
    /// each folder is drawn exactly once.
    private var rootAdoptedFolderIDs: Set<String> {
        let parents = Dictionary(
            folders.map { ($0.id, $0.parentFolderId) }, uniquingKeysWith: { first, _ in first })
        var adopted: Set<String> = []
        for (id, parent) in parents {
            // Nil parent means it sits at the root already; a parent id we hold no folder for
            // means the root is the only place left to draw it.
            let parentIsPresent = parent.map { parents[$0] != nil } ?? false
            if !parentIsPresent { adopted.insert(id) }
        }

        // Whatever is left either climbs to one of those or goes round forever. Walking each
        // chain once and settling it keeps this linear even when every folder shares an ancestor.
        var settled: Set<String> = []
        for id in parents.keys where !settled.contains(id) {
            var path: [String] = []
            var position: [String: Int] = [:]
            var cursor: String? = id
            while let current = cursor, !settled.contains(current) {
                if let start = position[current] {
                    // A loop closes here. Its lowest id is the entry point, chosen by id so the
                    // sidebar does not reshuffle itself between launches.
                    if let entry = path[start...].min() { adopted.insert(entry) }
                    break
                }
                position[current] = path.count
                path.append(current)
                guard let parent = parents[current] ?? nil else { break }
                cursor = parent
            }
            settled.formUnion(path)
        }
        return adopted
    }

    /// Subfolders of `parentFolderId`. The root additionally adopts the folders that nothing else
    /// would draw, so an orphaned subtree stays reachable instead of vanishing from the sidebar.
    func folders(in parentFolderId: String?) -> [FolderDTO] {
        guard parentFolderId == nil else {
            return folders.filter { $0.parentFolderId == parentFolderId }
        }
        let adopted = rootAdoptedFolderIDs
        return folders.filter { adopted.contains($0.id) }
    }

    /// Notebooks directly inside `parentFolderId`. The root additionally adopts every notebook
    /// whose `parentFolderId` names a folder that is gone — the case a peer's folder deletion
    /// leaves behind. A notebook filed under a folder that still exists stays there even if that
    /// folder is itself orphaned, because `folders(in: nil)` has already surfaced the folder.
    func notebooks(in parentFolderId: String?) -> [NotebookManifest] {
        guard parentFolderId == nil else {
            return notebooks.filter { $0.parentFolderId == parentFolderId }
        }
        let known = Set(folders.map(\.id))
        return notebooks.filter { notebook in
            guard let parent = notebook.parentFolderId else { return true }
            return !known.contains(parent)
        }
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

    /// Records what CouchDB holds, as of the last state the engine persisted — a flush that got a
    /// revision back, or a pull that applied one. Nil turns the CouchDB answer off, for when that
    /// backend is not the one running.
    ///
    /// Assigning only on a real change matters: the state is persisted on every local edit, and
    /// republishing an identical set would redraw the whole library each time someone writes.
    func noteRemoteDocuments(_ documentIDs: Set<String>?) {
        guard remoteDocumentIDs != documentIDs else { return }
        remoteDocumentIDs = documentIDs
    }

    /// Whether a notebook exists on the server as of the last completed sync.
    func provenance(ofNotebook id: String) -> SyncProvenance {
        if let remoteDocumentIDs {
            return remoteDocumentIDs.contains(CouchDocID.notebook(id)) ? .onServer : .localOnly
        }
        guard let remoteIndex else { return .unknown }
        return remoteIndex.hasNotebook(id) ? .onServer : .localOnly
    }

    /// Whether a folder is on the server — in its `folders.json` under WebDAV, or holding a
    /// revision under CouchDB — as of the last sync.
    func provenance(ofFolder id: String) -> SyncProvenance {
        if let remoteDocumentIDs {
            return remoteDocumentIDs.contains(CouchDocID.folder(id)) ? .onServer : .localOnly
        }
        guard let remoteIndex else { return .unknown }
        return remoteIndex.hasFolder(id) ? .onServer : .localOnly
    }

    /// True once a backend can say where things live — the cue for showing badges at all.
    var hasSyncedAtLeastOnce: Bool { remoteDocumentIDs != nil || remoteIndex != nil }
}
