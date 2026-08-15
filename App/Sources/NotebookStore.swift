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

        // Read alongside the library rather than derived from it: `notebooks` and `folders` are
        // still the complete set — sync reads them and a trashed item has to keep syncing — so
        // what is hidden is a separate fact and the listing queries apply it.
        trash = LocalTrash.load(root: rootURL)

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

    /// Reconciles a notebook's `pageIds` with the page files actually on disk, and returns whether
    /// anything had to be repaired.
    ///
    /// `pageIds` is the only record of page *order*, so it is authoritative — but it is a list of
    /// ids kept in a separate file from the pages themselves, and the two can come apart. Two ways
    /// that has been seen, both of which leave the notebook looking wrong rather than broken:
    ///
    /// - **A repeated id.** The page count is taken from `pageIds.count` while the overview is a
    ///   `ForEach` keyed by page id, and SwiftUI collapses rows that share an id — so a notebook
    ///   whose list reads `[A, A, A, A]` says "4" in the editor and draws a single thumbnail.
    /// - **An orphan page file.** A page written to disk whose id never made it into the list is
    ///   invisible everywhere and, worse, the next upload's orphan cleanup deletes it.
    ///
    /// Repairing on open rather than on every `refresh()` keeps it off the library's path, where it
    /// would cost a directory listing per notebook. A tombstoned page is never re-attached: erasure
    /// beats recovery, the same rule the merge uses, or a page deleted on the BOOX would walk back
    /// in here on the next open.
    @discardableResult
    func repairPageList(in notebookId: String) -> Bool {
        guard var manifest = readManifestFromDisk(notebookId) else { return false }

        var seen = Set<String>()
        var repaired = manifest.pageIds.filter { seen.insert($0).inserted }

        let tombstoned = Set(manifest.deletedPageIds.map(\.id))
        let pagesDir = notebookDir(notebookId).appendingPathComponent("pages", isDirectory: true)
        let onDisk = (try? FileManager.default.contentsOfDirectory(atPath: pagesDir.path)) ?? []
        let orphans = onDisk
            .filter { $0.hasSuffix(".json") }
            .map { String($0.dropLast(".json".count)) }
            .filter { !seen.contains($0) && !tombstoned.contains($0) }
            // A stable order, and the one that matches how they were made: the file's own
            // `createdAt`, falling back to the id so the result never depends on directory order.
            .sorted {
                let left = readPageFromDisk(notebookId: notebookId, pageId: $0)?.createdAt ?? ""
                let right = readPageFromDisk(notebookId: notebookId, pageId: $1)?.createdAt ?? ""
                return (left, $0) < (right, $1)
            }
        repaired.append(contentsOf: orphans)

        guard repaired != manifest.pageIds else { return false }
        manifest.pageIds = repaired
        // The repair has to travel: a peer holding the same damaged list would otherwise merge it
        // straight back, and `updatedAt` is the clock the merge reads.
        manifest.updatedAt = NotableDate.format(Date())
        manifest.updatedBy = deviceID
        if let openPageId = manifest.openPageId, !repaired.contains(openPageId) {
            manifest.openPageId = repaired.first
        }
        try? writeManifest(manifest)
        refreshAfterLocalChange(documents: [CouchDocID.notebook(notebookId)])
        return true
    }

    /// Appends a page. Its paper follows the notebook's own default (what Notable does);
    /// `fallbackTemplate` applies only when that default is not a native template —
    /// a PDF-backed notebook's per-page PDF binding is not something we can invent here.
    func addPage(to notebookId: String, fallbackTemplate: NativeTemplate = .blank) throws -> PageFile {
        try insertPage(into: notebookId, at: nil, fallbackTemplate: fallbackTemplate)
    }

    /// Adds a page at [index], or at the end when it is nil.
    ///
    /// Inserting rather than only appending is what the page overview needs: "add a page here" is
    /// the ordinary way to make room in the middle of a notebook, and the BOOX has had it since
    /// its overview existed.
    @discardableResult
    func insertPage(
        into notebookId: String, at index: Int?, fallbackTemplate: NativeTemplate = .blank
    ) throws -> PageFile {
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
        manifest.pageIds.insert(
            page.id, at: (index ?? manifest.pageIds.count).clamped(to: manifest.pageIds))
        manifest.updatedAt = now
        manifest.updatedBy = deviceID
        try writeManifest(manifest)
        refreshAfterLocalChange(
            documents: [CouchDocID.notebook(notebookId), CouchDocID.page(page.id)])
        return page
    }

    // MARK: - Page management

    /// Copies a page, contents and all, and files the copy right after the original.
    ///
    /// A fresh id for the page and for every stroke and image on it: the copy is a new document,
    /// and reusing an id would have the merge treat the two as the same page on the other device.
    @discardableResult
    func duplicatePage(in notebookId: String, pageId: String) throws -> PageFile {
        guard var manifest = readManifestFromDisk(notebookId),
              let index = manifest.pageIds.firstIndex(of: pageId)
        else { throw CocoaError(.fileNoSuchFile) }
        let source = try loadPage(notebookId: notebookId, pageId: pageId)

        let now = NotableDate.format(Date())
        var copy = source
        copy.id = UUID().uuidString.lowercased()
        copy.createdAt = now
        copy.updatedAt = now
        copy.updatedBy = deviceID
        copy.scroll = 0
        // Nothing was erased from a page that did not exist a moment ago; carrying the original's
        // tombstones over would tell peers to delete strokes from the copy by id.
        copy.deletedStrokes = []
        copy.strokes = source.strokes.map { stroke in
            var fresh = stroke
            fresh.id = UUID().uuidString.lowercased()
            return fresh
        }
        copy.images = source.images.map { image in
            var fresh = image
            fresh.id = UUID().uuidString.lowercased()
            return fresh
        }

        try encoder.encode(copy)
            .write(to: pageURL(notebookId: notebookId, pageId: copy.id), options: .atomic)
        manifest.pageIds.insert(copy.id, at: index + 1)
        manifest.updatedAt = now
        manifest.updatedBy = deviceID
        try writeManifest(manifest)
        refreshAfterLocalChange(
            documents: [CouchDocID.notebook(notebookId), CouchDocID.page(copy.id)])
        return copy
    }

    /// Removes a page from its notebook.
    ///
    /// The tombstone in `deletedPageIds` is the point: a page has no lifecycle of its own — it
    /// lives and dies with its notebook's page list (protocol §6.4) — so a peer that still lists
    /// the page would simply add it back on the next merge without one.
    ///
    /// The last page of a notebook cannot be deleted. A notebook with no pages is the empty
    /// leftover the library already has to warn about, and reaching that state deliberately, from
    /// the page overview, would be a worse way to arrive at it.
    func deletePage(from notebookId: String, pageId: String) throws {
        guard var manifest = readManifestFromDisk(notebookId),
              manifest.pageIds.contains(pageId)
        else { throw CocoaError(.fileNoSuchFile) }
        guard manifest.pageIds.count > 1 else { throw LastPageError() }

        let now = NotableDate.format(Date())
        manifest.pageIds.removeAll { $0 == pageId }
        manifest.deletedPageIds.append(CouchTombstone(id: pageId, deletedAt: now))
        // The bookmark can simply go — the merge filters starred pages by the tombstone too. The
        // outline entries have to be *marked* removed instead, because the merge deliberately does
        // not filter those (protocol §5.2.2) and a peer still holding them would otherwise add them
        // straight back. Doing it here, as an ordinary stamped edit, is what makes the removal
        // travel.
        manifest.bookmarks.removeAll { $0.pageId == pageId }
        for index in manifest.outline.indices where manifest.outline[index].pageId == pageId {
            manifest.outline[index].removed = true
            manifest.outline[index].updatedAt = now
        }
        if manifest.openPageId == pageId { manifest.openPageId = manifest.pageIds.first }
        manifest.updatedAt = now
        manifest.updatedBy = deviceID
        try writeManifest(manifest)

        // The file goes after the manifest, not before: the manifest is what says the page is
        // gone, and a crash between the two leaves a page file nothing lists rather than a page
        // listed with no file — which is the one of the two that makes `loadPage` throw.
        try? FileManager.default.removeItem(
            at: pageURL(notebookId: notebookId, pageId: pageId))
        refreshAfterLocalChange(documents: [CouchDocID.notebook(notebookId)])
    }

    /// Reorders a page within its notebook.
    // MARK: Bookmarks

    /// Every page starred in this notebook, in page order — not the order the entries happen to be
    /// stored in, which is sorted by id to keep the merged document byte-stable.
    func bookmarkedPageIds(in notebookId: String) -> [String] {
        guard let manifest = manifest(id: notebookId) else { return [] }
        let starred = Set(manifest.bookmarks.filter { !$0.removed }.map(\.pageId))
        return manifest.pageIds.filter { starred.contains($0) }
    }

    func isBookmarked(notebookId: String, pageId: String) -> Bool {
        manifest(id: notebookId)?.bookmarks
            .first { $0.pageId == pageId }
            .map { !$0.removed } ?? false
    }

    /// Star or un-star a page. Un-starring writes a `removed` entry rather than dropping the
    /// bookmark, so the un-starring reaches the other device instead of being undone by it.
    func setBookmark(notebookId: String, pageId: String, bookmarked: Bool) throws {
        guard var manifest = readManifestFromDisk(notebookId),
              manifest.pageIds.contains(pageId)
        else { throw CocoaError(.fileNoSuchFile) }

        let now = NotableDate.format(Date())
        let entry = CouchBookmark(pageId: pageId, updatedAt: now, removed: !bookmarked)
        manifest.bookmarks.removeAll { $0.pageId == pageId }
        manifest.bookmarks.append(entry)
        manifest.bookmarks.sort { $0.pageId < $1.pageId }
        manifest.updatedAt = now
        manifest.updatedBy = deviceID
        try writeManifest(manifest)
        refreshAfterLocalChange(documents: [CouchDocID.notebook(notebookId)])
    }

    // MARK: Outline

    /// The notebook's table of contents: live entries whose page still exists, in stored order.
    ///
    /// Dangling entries are skipped rather than repaired. The merge cannot drop them and stay
    /// idempotent (protocol §5.2.2), so hiding them here is what keeps a deleted page from leaving
    /// a line that does nothing when tapped.
    func outline(in notebookId: String) -> [CouchOutlineEntry] {
        guard let manifest = manifest(id: notebookId) else { return [] }
        let pages = Set(manifest.pageIds)
        return manifest.outline.filter { !$0.removed && pages.contains($0.pageId) }
    }

    func addOutlineEntry(notebookId: String, pageId: String, title: String, depth: Int = 0) throws {
        guard var manifest = readManifestFromDisk(notebookId),
              manifest.pageIds.contains(pageId)
        else { throw CocoaError(.fileNoSuchFile) }

        let now = NotableDate.format(Date())
        // Appended at the page's position rather than at the end: an outline is read against the
        // notebook, so a new entry belongs beside the pages it sits between, not after everything.
        let entry = CouchOutlineEntry(
            id: UUID().uuidString.lowercased(), pageId: pageId, title: title, depth: depth,
            updatedAt: now)
        let order = pageOrder(manifest)
        let insertion = manifest.outline.firstIndex {
            (order[$0.pageId] ?? Int.max) > (order[pageId] ?? Int.max)
        } ?? manifest.outline.endIndex
        manifest.outline.insert(entry, at: insertion)
        manifest.updatedAt = now
        manifest.updatedBy = deviceID
        try writeManifest(manifest)
        refreshAfterLocalChange(documents: [CouchDocID.notebook(notebookId)])
    }

    /// Rename an entry, change its nesting depth, or both. Depth is clamped to what the format
    /// allows rather than rejected, matching the decoder.
    func updateOutlineEntry(
        notebookId: String, entryId: String, title: String? = nil, depth: Int? = nil
    ) throws {
        try editOutline(notebookId: notebookId, entryId: entryId) { entry, now in
            if let title { entry.title = title }
            if let depth { entry.depth = min(max(depth, 0), CouchOutlineEntry.maxDepth) }
            entry.updatedAt = now
        }
    }

    /// Delete an entry by marking it removed — an ordinary edit the merge carries, rather than a
    /// drop the peer would undo.
    func removeOutlineEntry(notebookId: String, entryId: String) throws {
        try editOutline(notebookId: notebookId, entryId: entryId) { entry, now in
            entry.removed = true
            entry.updatedAt = now
        }
    }

    /// Reorder the outline, addressing positions in the *live* list the reader can see rather than
    /// in the stored one, which also holds removed entries they cannot.
    func moveOutlineEntry(in notebookId: String, from source: Int, to destination: Int) throws {
        guard var manifest = readManifestFromDisk(notebookId) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let live = manifest.outline.enumerated().filter { !$0.element.removed }
        guard live.indices.contains(source) else { throw CocoaError(.fileNoSuchFile) }

        let entry = manifest.outline.remove(at: live[source].offset)
        let target = live.indices.contains(destination)
            ? live[destination].offset - (live[destination].offset > live[source].offset ? 1 : 0)
            : manifest.outline.endIndex
        manifest.outline.insert(entry, at: min(max(target, 0), manifest.outline.endIndex))
        manifest.updatedAt = NotableDate.format(Date())
        manifest.updatedBy = deviceID
        try writeManifest(manifest)
        refreshAfterLocalChange(documents: [CouchDocID.notebook(notebookId)])
    }

    private func editOutline(
        notebookId: String, entryId: String, _ edit: (inout CouchOutlineEntry, String) -> Void
    ) throws {
        guard var manifest = readManifestFromDisk(notebookId),
              let index = manifest.outline.firstIndex(where: { $0.id == entryId })
        else { throw CocoaError(.fileNoSuchFile) }

        let now = NotableDate.format(Date())
        edit(&manifest.outline[index], now)
        manifest.updatedAt = now
        manifest.updatedBy = deviceID
        try writeManifest(manifest)
        refreshAfterLocalChange(documents: [CouchDocID.notebook(notebookId)])
    }

    private func pageOrder(_ manifest: NotebookManifest) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: manifest.pageIds.enumerated().map { ($1, $0) })
    }

    func movePage(in notebookId: String, from source: Int, to destination: Int) throws {
        guard var manifest = readManifestFromDisk(notebookId),
              manifest.pageIds.indices.contains(source)
        else { throw CocoaError(.fileNoSuchFile) }

        let page = manifest.pageIds.remove(at: source)
        manifest.pageIds.insert(page, at: destination.clamped(to: manifest.pageIds))
        manifest.updatedAt = NotableDate.format(Date())
        manifest.updatedBy = deviceID
        try writeManifest(manifest)
        refreshAfterLocalChange(documents: [CouchDocID.notebook(notebookId)])
    }

    /// Names a page, or clears its name with nil.
    ///
    /// The field has been carried through bopa untouched since it existed, so that a round trip
    /// through this device did not erase a name given on the BOOX. This is the first thing here
    /// that can set one.
    func renamePage(in notebookId: String, pageId: String, title: String?) throws {
        var page = try loadPage(notebookId: notebookId, pageId: pageId)
        page.title = title
        page.updatedAt = NotableDate.format(Date())
        page.updatedBy = deviceID
        try encoder.encode(page)
            .write(to: pageURL(notebookId: notebookId, pageId: pageId), options: .atomic)
        refreshAfterLocalChange(documents: [CouchDocID.page(pageId)])
    }

    /// Thrown rather than silently ignored, so the overview can say why the button did nothing.
    struct LastPageError: LocalizedError {
        var errorDescription: String? {
            "A notebook needs at least one page."
        }
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

    // MARK: - Trash

    /// What is staged for deletion. Synced, not local: an item the BOOX throws away lands here
    /// too, and one restored anywhere comes back everywhere. See `LocalTrash`.
    @Published private(set) var trash = LocalTrash.Contents()

    var trashedNotebooks: [NotebookManifest] {
        let ids = trash.notebookIDs
        return notebooks.filter { ids.contains($0.notebookId) }
    }

    var trashedFolders: [FolderDTO] {
        let ids = trash.folderIDs
        return folders.filter { ids.contains($0.id) }
    }

    /// When an item was thrown away, for the Trash screen's subtitle.
    func trashedAt(notebookId: String) -> Date? {
        trash.notebooks.first { $0.id == notebookId }.flatMap { NotableDate.parse($0.deletedAt) }
    }

    func trashedAt(folderId: String) -> Date? {
        trash.folders.first { $0.id == folderId }.flatMap { NotableDate.parse($0.deletedAt) }
    }

    /// Tell the peer about the trashings that were only ever local, so the two libraries can agree
    /// again.
    ///
    /// Until the Trash became a field of the document, throwing something away here wrote
    /// `.bopa-trash.json` and stopped: no `updatedAt` stamp, no queued document. The item left this
    /// library and stayed in the BOOX's, and shipping the fix does not rescue it — the notebook has
    /// been through the server already, so it is in the engine's rev map and the "never sent" scan
    /// deliberately cannot see it, while the item being hidden here means no edit will ever queue
    /// it either. Without this it stays hidden on one device and listed on the other, permanently.
    ///
    /// `touchNotebook`/`touchFolder` are exactly what a trashing does today, which is the point:
    /// the stamp is what makes `deletedAt` outrank the peer's live copy under §5.5, and queueing
    /// alone would push a trashing that ties with it and loses.
    ///
    /// Called by `SyncBackendHost` once the CouchDB queue exists, not from `init`: the stamp is
    /// only half of a republish, and running before `didChangeDocuments` is wired would write the
    /// stamp into a queue that is not listening, clear the flag, and stand the item down for good
    /// having told nobody. It is confined to the CouchDB backend for the same reason — under
    /// WebDAV or with sync off there is no peer to tell, and burning the flag would strand the
    /// item permanently the moment CouchDB was switched on.
    ///
    /// Failures are swallowed per item: an item that could not be written keeps its missing flag
    /// and is retried on the next launch.
    func republishStrandedTrashings() {
        let stranded = LocalTrash.unpublished(root: rootURL)
        guard !stranded.notebookIDs.isEmpty || !stranded.folderIDs.isEmpty else { return }

        var republishedNotebooks: Set<String> = []
        var republishedFolders: Set<String> = []
        for id in stranded.notebookIDs where (try? touchNotebook(id)) != nil {
            republishedNotebooks.insert(id)
        }
        for id in stranded.folderIDs where (try? touchFolder(id)) != nil {
            republishedFolders.insert(id)
        }
        try? LocalTrash.markPublished(
            notebookIDs: republishedNotebooks, folderIDs: republishedFolders, root: rootURL)
        refresh()
    }

    /// Throw a notebook away. Its files stay and it goes on syncing — only emptying the Trash
    /// deletes anything — but the Trash itself is published, so the notebook leaves the library on
    /// every device and can be restored from any of them.
    ///
    /// The timestamp bump is not decoration: `deletedAt` travels in the scalar envelope, which
    /// §5.5 decides by `updatedAt`. Without it this write would tie with the peer's live copy and
    /// the notebook could come straight back out of the Trash.
    func trashNotebook(id: String) throws {
        try LocalTrash.addNotebook(id, at: Date(), root: rootURL)
        try touchNotebook(id)
    }

    /// Throw a folder away. Only the folder itself is marked — its contents become unreachable
    /// because their container is no longer listed, so restoring the subtree is one line leaving
    /// the file rather than a second cascade to get wrong. That holds on the peer too: it hides
    /// the same subtree from the same one field.
    func trashFolder(id: String) throws {
        try LocalTrash.addFolder(id, at: Date(), root: rootURL)
        try touchFolder(id)
    }

    /// Bring a notebook back, here and everywhere. If the folder it was filed under has since been
    /// purged — or is itself still in the Trash — it returns to the root, because restoring it into
    /// an invisible folder would look exactly like the restore having quietly failed.
    func restoreNotebook(id: String) throws {
        try LocalTrash.removeNotebook(id, root: rootURL)
        if let manifest = manifest(id: id), !isReachable(manifest.parentFolderId) {
            // Re-homing already stamps and queues the notebook, which is the whole of a restore.
            try moveNotebook(id: id, toFolder: nil)
        } else {
            try touchNotebook(id)
        }
    }

    func restoreFolder(id: String) throws {
        try LocalTrash.removeFolder(id, root: rootURL)
        if let folder = folder(id: id), !isReachable(folder.parentFolderId) {
            var all = folders
            guard let index = all.firstIndex(where: { $0.id == id }) else { return }
            all[index].parentFolderId = nil
            all[index].updatedAt = NotableDate.format(Date())
            try writeFolders(all)
        } else {
            try touchFolder(id)
        }
    }

    /// Stamp a notebook as written by this device now, and queue it. Called when what changed is
    /// not in the manifest at all — the Trash — but still has to travel and still has to carry a
    /// timestamp newer than the copy it is racing.
    ///
    /// A notebook with no manifest is not an error here: it can be trashed while its files are
    /// still arriving. The Trash entry is written either way, and the next merge that brings the
    /// manifest in will find it.
    private func touchNotebook(_ id: String) throws {
        if var manifest = manifest(id: id) {
            manifest.updatedAt = NotableDate.format(Date())
            manifest.updatedBy = deviceID
            try writeManifest(manifest)
        }
        refreshAfterLocalChange(documents: [CouchDocID.notebook(id)])
    }

    /// The folder twin of `touchNotebook`.
    private func touchFolder(_ id: String) throws {
        var all = folders
        guard let index = all.firstIndex(where: { $0.id == id }) else {
            refreshAfterLocalChange(documents: [CouchDocID.folder(id)])
            return
        }
        all[index].updatedAt = NotableDate.format(Date())
        try writeFolders(all)
    }

    /// The root is always there; a folder is only a place to put something if it is neither gone
    /// nor itself in the Trash.
    private func isReachable(_ parentFolderId: String?) -> Bool {
        guard let parentFolderId else { return true }
        guard folders.contains(where: { $0.id == parentFolderId }) else { return false }
        return !trash.folderIDs.contains(parentFolderId)
    }

    // MARK: - Deleting for good

    /// Everything a folder deletion would take, gathered before anything is removed.
    struct DeletionScope {
        var folderIDs: [String] = []
        var notebookIDs: [String] = []
        var pageCount: Int = 0

        /// Descendants, i.e. not counting the folder being deleted.
        var childFolderCount: Int { max(folderIDs.count - 1, 0) }
        var isEmpty: Bool { childFolderCount == 0 && notebookIDs.isEmpty && pageCount == 0 }
    }

    /// Walk a folder and everything under it.
    ///
    /// Iterative with a visited set, because the folder tree is merged data: `folders.json` can
    /// come back from a peer with a chain that loops, and the library already has to cope with
    /// that (see `rootAdoptedFolderIDs`) rather than assume it away.
    func deletionScope(ofFolder folderId: String) -> DeletionScope {
        var scope = DeletionScope(folderIDs: [folderId])
        var seen: Set<String> = [folderId]
        var queue = [folderId]

        while let current = queue.popLast() {
            for child in folders where child.parentFolderId == current {
                guard seen.insert(child.id).inserted else { continue }
                scope.folderIDs.append(child.id)
                queue.append(child.id)
            }
            for notebook in notebooks where notebook.parentFolderId == current {
                scope.notebookIDs.append(notebook.notebookId)
                scope.pageCount += notebook.pageIds.count
            }
        }
        return scope
    }

    func deletionScope(ofNotebook notebookId: String) -> DeletionScope {
        DeletionScope(
            notebookIDs: [notebookId],
            pageCount: manifest(id: notebookId)?.pageIds.count ?? 0)
    }

    /// Delete a notebook for good: its files go, and a tombstone says so.
    ///
    /// The order is deliberate and is the fix for the defect this replaces. The deletion intent is
    /// recorded *first*, because it is a small local write that either succeeds or throws before
    /// anything is destroyed; the directory removal follows. If the removal fails, the intent is
    /// rolled back and the error is thrown, so a notebook that is still on this iPad can never
    /// have its deletion published. The old path did the reverse and dropped the removal's error
    /// with `try?`, which could leave the notebook here while its tombstone was already queued for
    /// the server and the BOOX.
    func purgeNotebook(id: String) throws {
        // Throws when there is no such notebook, rather than quietly succeeding: purging
        // something that is not there is a caller's mistake, and treating it as done would record
        // a tombstone for a document this device never had — which on the peer deletes a notebook
        // nobody deleted.
        guard let manifest = readManifestFromDisk(id) else { throw CocoaError(.fileNoSuchFile) }
        let pageIds = manifest.pageIds

        PendingDeletions.add(id, root: rootURL)
        do {
            try FileManager.default.removeItem(at: notebookDir(id))
        } catch {
            PendingDeletions.remove(id, root: rootURL)
            throw error
        }
        // Only once the files are actually gone, and before the change signal: a tombstone is
        // authoritative the moment it is written, so recording one for a removal that threw would
        // publish a deletion this device never made — while a push that ran before it existed
        // would load nothing, take that for "never created", and drop the id from the outbox.
        didDeleteDocuments?([CouchDocID.notebook(id)])

        try? LocalTrash.removeNotebook(id, root: rootURL)
        // The pages go with it, so name them too: the engine has to stop tracking them, and a
        // page left queued would be pushed back under a notebook that no longer exists.
        refreshAfterLocalChange(
            documents: [CouchDocID.notebook(id)] + pageIds.map(CouchDocID.page))
    }

    /// Delete a folder and its whole subtree for good.
    ///
    /// Notebooks first, then the folder rows in one rewrite of `folders.json`. A notebook that
    /// fails to be removed stops the whole purge with its error, and every folder row is left
    /// alone — so the subtree stays whole and visible in the Trash rather than half gone, which is
    /// the state that has no name in the UI and no way back.
    @discardableResult
    func purgeFolder(id: String) throws -> DeletionScope {
        let scope = deletionScope(ofFolder: id)

        for notebookId in scope.notebookIDs {
            try purgeNotebook(id: notebookId)
        }

        let removedFolders = Set(scope.folderIDs)
        try writeFolders(
            folders.filter { !removedFolders.contains($0.id) },
            deleting: scope.folderIDs.map(CouchDocID.folder))
        try? LocalTrash.remove(
            notebookIDs: Set(scope.notebookIDs), folderIDs: removedFolders, root: rootURL)
        refreshAfterLocalChange()
        return scope
    }

    /// Purge everything staged.
    ///
    /// Folders go first: one of them may contain a notebook that is *also* in the Trash in its own
    /// right, and purging the folder already takes it, so the notebook pass reads what is left
    /// rather than a list captured up front.
    @discardableResult
    func emptyTrash() throws -> DeletionScope {
        var total = DeletionScope()

        for folder in trashedFolders {
            let removed = try purgeFolder(id: folder.id)
            total.folderIDs += removed.folderIDs
            total.notebookIDs += removed.notebookIDs
            total.pageCount += removed.pageCount
        }
        for notebook in trashedNotebooks {
            total.notebookIDs.append(notebook.notebookId)
            total.pageCount += notebook.pageIds.count
            try purgeNotebook(id: notebook.notebookId)
        }
        return total
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
        let trashed = trash.folderIDs
        guard parentFolderId == nil else {
            return folders.filter {
                $0.parentFolderId == parentFolderId && !trashed.contains($0.id)
            }
        }
        let adopted = rootAdoptedFolderIDs
        return folders.filter { adopted.contains($0.id) && !trashed.contains($0.id) }
    }

    /// Notebooks directly inside `parentFolderId`. The root additionally adopts every notebook
    /// whose `parentFolderId` names a folder that is gone — the case a peer's folder deletion
    /// leaves behind. A notebook filed under a folder that still exists stays there even if that
    /// folder is itself orphaned, because `folders(in: nil)` has already surfaced the folder.
    func notebooks(in parentFolderId: String?) -> [NotebookManifest] {
        let trashed = trash.notebookIDs
        guard parentFolderId == nil else {
            return notebooks.filter {
                $0.parentFolderId == parentFolderId && !trashed.contains($0.notebookId)
            }
        }
        // `known` counts trashed folders too, which is what keeps a folder's notebooks inside it
        // when it goes to the Trash. Treating a trashed folder as gone would adopt every notebook
        // under it straight to the root — the opposite of what throwing the folder away meant.
        let known = Set(folders.map(\.id))
        return notebooks.filter { notebook in
            guard !trashed.contains(notebook.notebookId) else { return false }
            guard let parent = notebook.parentFolderId else { return true }
            return !known.contains(parent)
        }
    }

    func folder(id: String) -> FolderDTO? {
        folders.first { $0.id == id }
    }

    /// Everything in the library whose name answers [query], wherever it is filed.
    ///
    /// Deliberately not scoped to the folder you are standing in: the reason to search is that you
    /// do not know where the thing is. Trashed items stay out — they are not in the library — and
    /// so does anything inside a trashed folder, which is why this filters on the same reachability
    /// rule the listings do rather than on the query alone.
    func search(_ query: String) -> (folders: [FolderDTO], notebooks: [NotebookManifest]) {
        let trashedFolderIDs = trash.folderIDs
        let trashedNotebookIDs = trash.notebookIDs

        func isReachable(_ parentFolderId: String?) -> Bool {
            var seen: Set<String> = []
            var cursor = parentFolderId
            while let id = cursor {
                guard seen.insert(id).inserted else { return false }  // a cycle reaches no root
                guard let folder = folders.first(where: { $0.id == id }) else { return true }
                if trashedFolderIDs.contains(id) { return false }
                cursor = folder.parentFolderId
            }
            return true
        }

        return (
            folders: folders.filter {
                !trashedFolderIDs.contains($0.id)
                    && isReachable($0.parentFolderId)
                    && LibrarySort.matches(title: $0.title, query: query)
            },
            notebooks: notebooks.filter {
                !trashedNotebookIDs.contains($0.notebookId)
                    && isReachable($0.parentFolderId)
                    && LibrarySort.matches(title: $0.title, query: query)
            }
        )
    }

    /// The folder path of an item, outermost first — what a search result needs to say where it
    /// found something. Bounded against a cycle in `folders.json`, which the merge is allowed to
    /// produce and the library absorbs rather than repairs.
    func breadcrumb(of parentFolderId: String?) -> [FolderDTO] {
        var path: [FolderDTO] = []
        var seen: Set<String> = []
        var cursor = parentFolderId
        while let id = cursor, seen.insert(id).inserted,
              let folder = folders.first(where: { $0.id == id }) {
            path.append(folder)
            cursor = folder.parentFolderId
        }
        return path.reversed()
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

extension Int {
    /// This index, pulled inside `0...array.count` — the valid range for an insertion.
    ///
    /// Page order arrives from drag gestures and from a peer's merge, neither of which is obliged
    /// to be in range; an out-of-range insert traps rather than misbehaving, which is the one
    /// failure mode a reorder must not have.
    func clamped<T>(to array: [T]) -> Int {
        Swift.max(0, Swift.min(self, array.count))
    }
}
