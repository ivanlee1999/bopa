import Foundation

/// Per-page facts committed at the last successful transfer of that page.
///
/// This is what makes lossless merging possible: with it, edits to *different* pages of one
/// notebook are provably independent and need no prompt, and only a page changed on both sides is
/// a real conflict. Notable keeps the same row per page (`page_sync_state`).
public struct PageSyncState: Codable, Equatable, Sendable {
    /// The page's local `updatedAt` when we last committed a transfer of it, epoch ms.
    public var syncedLocalUpdatedAt: Int64
    public var etag: String?

    public init(syncedLocalUpdatedAt: Int64, etag: String?) {
        self.syncedLocalUpdatedAt = syncedLocalUpdatedAt
        self.etag = etag
    }
}

/// Per-notebook facts committed at the end of each successful transfer, used by the planner
/// next time. Persisted locally (never uploaded).
public struct NotebookSyncState: Codable, Equatable, Sendable {
    public var localUpdatedAtAtSync: Int64   // epoch ms
    public var etag: String?
    public var pages: [String: PageSyncState]

    public init(
        localUpdatedAtAtSync: Int64, etag: String?, pages: [String: PageSyncState] = [:]
    ) {
        self.localUpdatedAtAtSync = localUpdatedAtAtSync
        self.etag = etag
        self.pages = pages
    }

    /// Lenient so a state file written before per-page tracking existed still loads — those
    /// notebooks simply start with no page rows, which reads as "never synced per page" and is
    /// therefore never a conflict.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        localUpdatedAtAtSync = try c.decode(Int64.self, forKey: .localUpdatedAtAtSync)
        etag = try c.decodeIfPresent(String.self, forKey: .etag)
        pages = try c.decodeIfPresent([String: PageSyncState].self, forKey: .pages) ?? [:]
    }
}

/// One notebook that changed on both sides in a way bopa will not resolve on its own.
///
/// Nothing is transferred for a notebook in this state — neither copy is touched until the user
/// chooses. Recomputed from scratch every sync, so it is safe to lose (Notable treats its
/// equivalent flag the same way).
public struct NotebookConflict: Equatable, Sendable, Identifiable {
    public var notebookId: String
    /// Pages edited on both sides since the last common sync.
    public var pageIds: [String]
    /// The manifests disagree about structure (pages added/removed/reordered, title, folder,
    /// paper defaults). A structural conflict is settled for the whole notebook at once.
    public var structural: Bool

    public var id: String { notebookId }

    public init(notebookId: String, pageIds: [String], structural: Bool) {
        self.notebookId = notebookId
        self.pageIds = pageIds
        self.structural = structural
    }
}

/// How the user settled one conflicted page. Mirrors Notable's `PageConflictResolution`.
public enum PageResolution: Sendable, Equatable {
    case keepMine
    case useRemote
    case skip
}

/// How the user settled a structurally conflicted notebook.
public enum NotebookResolution: Sendable, Equatable {
    case keepMine
    case useRemote
}

public struct SyncReport: Equatable, Sendable {
    /// What the shared tree looked like when this run inventoried it.
    ///
    /// A run against the wrong folder and a healthy run with nothing to do otherwise produce
    /// byte-identical empty reports, so "everything is already in sync" is indistinguishable from
    /// "there is nothing here at all" — which is exactly the confusion a misconfigured base URL
    /// creates.
    public enum RemoteTreeState: Sendable, Equatable {
        case unknown        // the run bailed before it got to the inventory
        case absent         // we created /notable ourselves: nobody has ever written here
        case empty          // it existed, but held no notebooks, tombstones or folders.json
        case populated
    }

    public var uploaded: [String] = []
    public var downloaded: [String] = []
    public var skipped: [String] = []
    /// Notebooks whose two sides changed independently and were combined without asking — pages
    /// edited here went up, pages edited there came down. Reported separately from `skipped`
    /// because a merge really did move data.
    public var merged: [String] = []
    public var deletedLocally: [String] = []
    /// Notebooks changed on both sides that need the user to choose. Nothing was transferred for
    /// these — both copies are exactly as they were.
    public var conflicts: [NotebookConflict] = []
    /// 412s: a concurrent writer won the race. Not a semantic conflict — re-plan next sync.
    public var preconditionFailures: [String] = []
    public var errors: [String] = []        // "notebookId: message"
    public var remoteTree: RemoteTreeState = .unknown

    public init() {}
}

/// Two-way sync between a local directory in Notable's layout and a WebDAV server.
///
/// Reconciliation is notebook-granular last-writer-wins, ETag-guarded — matching Notable's
/// engine so both clients converge on the same state (see docs/notable-sync-protocol.md §8).
public actor SyncEngine {
    let dav: WebDAVClient
    let rootURL: URL
    let stateURL: URL
    let remoteIndexURL: URL

    private var state: [String: NotebookSyncState] = [:]

    public init(transport: HTTPTransport, rootURL: URL) {
        self.dav = WebDAVClient(transport: transport)
        self.rootURL = rootURL
        self.stateURL = rootURL.appendingPathComponent(".bopa-sync-state.json")
        self.remoteIndexURL = RemoteIndex.fileURL(root: rootURL)
    }

    // MARK: - Entry point

    /// - Parameter uploadOnly: notebooks that may be pushed but must never be written to. Used for
    ///   the notebook currently open in the editor: the editor holds authoritative in-memory state
    ///   that disk does not have, so a download landing under it is reverted by the next autosave
    ///   and then re-uploaded as the winner — remote work would vanish from both sides. Deferring
    ///   costs nothing, because `.skipUploadOnly` deliberately leaves sync state untouched, so the
    ///   download simply happens on the first run after the notebook is closed.
    public func sync(uploadOnly: Set<String> = []) async -> SyncReport {
        var report = SyncReport()
        loadState()

        // Whether we had to create the shared root is the only evidence available that nobody else
        // has ever written here, and it has to be captured now: every later step finds the tree in
        // place regardless.
        let createdRoot: Bool
        do {
            createdRoot = try await dav.makeCollection(NotableSyncPaths.root)
            try await dav.makeCollection(NotableSyncPaths.notebooksDir)
            try await dav.makeCollection(NotableSyncPaths.tombstonesDir)
        } catch {
            report.errors.append("server: cannot prepare directories (\(error))")
            return report
        }

        // 1. Flush deletions recorded while offline: PUT a zero-byte tombstone per pending
        // id, then clear it. Failed ids stay pending for the next sync.
        for id in PendingDeletions.load(root: rootURL) {
            do {
                try await dav.put(NotableSyncPaths.tombstone(id), data: Data())
                try? FileManager.default.removeItem(at: localNotebookDir(id))
                state[id] = nil
                PendingDeletions.remove(id, root: rootURL)
            } catch {
                report.errors.append("\(id): pending deletion failed (\(error))")
            }
        }

        // 2. Folder tree (single-file union merge, docs §2).
        let (remoteFolderIds, sawRemoteFoldersFile) = await syncFolders(&report)

        // 3. Tombstones: a deletion wins over existence.
        let tombstones = await fetchTombstoneIds(&report)
        for id in tombstones {
            if localNotebookExists(id) {
                try? FileManager.default.removeItem(at: localNotebookDir(id))
                state[id] = nil
                report.deletedLocally.append(id)
            }
        }

        // 4. Inventory.
        let localIds = listLocalNotebookIds().subtracting(tombstones)
        var remoteIds = Set<String>()
        do {
            remoteIds = Set(try await dav.list(NotableSyncPaths.notebooksDir)
                .filter(\.isCollection).map(\.name))
        } catch WebDAVError.notFound {
            remoteIds = []
        } catch {
            report.errors.append("server: cannot list notebooks (\(error))")
            return report
        }
        remoteIds.subtract(tombstones)

        // A folders.json on its own still counts as populated: a BOOX that has only ever made
        // folders is a working setup, not a wrong address.
        report.remoteTree =
            createdRoot ? .absent
            : (remoteIds.isEmpty && tombstones.isEmpty && !sawRemoteFoldersFile) ? .empty
            : .populated

        // 5. Reconcile the union. `serverNotebookIds` tracks what the server holds as we
        // go, so a freshly uploaded notebook lands in the remote index right away.
        var serverNotebookIds = remoteIds
        for id in localIds.union(remoteIds).sorted() {
            do {
                switch (localIds.contains(id), remoteIds.contains(id)) {
                case (true, false):
                    try await upload(id, ifMatch: nil, report: &report)
                    serverNotebookIds.insert(id)
                    report.uploaded.append(id)
                case (false, true):
                    // Remote-only and excluded: there is no local copy to protect, but creating one
                    // under an open editor would be just as surprising. Defer it wholesale.
                    guard !uploadOnly.contains(id) else {
                        report.skipped.append(id)
                        break
                    }
                    try await download(id, report: &report)
                    report.downloaded.append(id)
                case (true, true):
                    try await reconcile(
                        id, uploadOnly: uploadOnly.contains(id), report: &report)
                case (false, false):
                    break
                }
            } catch WebDAVError.preconditionFailed {
                report.preconditionFailures.append(id)
            } catch {
                report.errors.append("\(id): \(error)")
            }
        }

        saveState()
        saveRemoteIndex(notebookIds: serverNotebookIds, folderIds: remoteFolderIds)
        return report
    }

    // MARK: - Reconciliation

    private func reconcile(
        _ id: String, uploadOnly: Bool = false, report: inout SyncReport
    ) async throws {
        guard let localManifest = readLocalManifest(id),
              let localUpdatedAt = epochMs(localManifest.updatedAt)
        else {
            report.errors.append("\(id): unreadable local manifest")
            return
        }
        let stored = state[id]

        // Conditional GET of the remote manifest.
        var remoteChanged = true
        var remoteInfo: RemoteManifestInfo?
        var remoteManifestData: Data?
        do {
            let result = try await dav.get(
                NotableSyncPaths.manifestFile(id), ifNoneMatch: stored?.etag)
            if result.notModified {
                remoteChanged = false
            } else {
                remoteManifestData = result.data
                let manifest = try? JSONDecoder().decode(NotebookManifest.self, from: result.data)
                remoteInfo = RemoteManifestInfo(
                    updatedAt: manifest.flatMap { epochMs($0.updatedAt) },
                    etag: result.etag)
            }
        } catch WebDAVError.notFound {
            try await upload(id, ifMatch: nil, report: &report)
            report.uploaded.append(id)
            return
        }

        let action = SyncPlanner.decide(
            localUpdatedAt: localUpdatedAt,
            syncedLocalUpdatedAt: stored?.localUpdatedAtAtSync,
            storedEtag: stored?.etag,
            remoteChanged: remoteChanged,
            remote: remoteInfo,
            uploadOnly: uploadOnly)

        switch action {
        case .reconcile:
            guard let data = remoteManifestData,
                  let remoteManifest = try? JSONDecoder().decode(NotebookManifest.self, from: data)
            else {
                // An unreadable remote manifest is structural by definition — we cannot prove the
                // two agree, so we must not guess.
                report.conflicts.append(
                    NotebookConflict(notebookId: id, pageIds: [], structural: true))
                return
            }
            try await reconcileDiverged(
                id, local: localManifest, remote: remoteManifest,
                remoteManifestData: data, remoteEtag: remoteInfo?.etag, report: &report)
        case .upload(let ifMatch):
            try await upload(id, ifMatch: ifMatch, report: &report)
            report.uploaded.append(id)
        case .download:
            guard let data = remoteManifestData else {
                report.errors.append("\(id): download planned but no manifest data")
                return
            }
            try await downloadContent(
                id, manifestData: data, etag: remoteInfo?.etag, report: &report)
            report.downloaded.append(id)
        case .skip:
            // Both sides agree: commit the freshest facts so the next sync's conditional
            // GET can hit 304. Keeping a stale ETag here would force a full manifest
            // download on every future sync.
            state[id] = NotebookSyncState(
                localUpdatedAtAtSync: localUpdatedAt,
                etag: remoteInfo?.etag ?? stored?.etag,
                pages: stored?.pages ?? [:])
            report.skipped.append(id)
        case .skipUploadOnly, .skipDownloadOnly:
            // A transfer was deliberately suppressed by a one-directional mode. Recording
            // "in sync" here would strand the pending change: once the mode is lifted,
            // the planner would see no local movement (or an unchanged remote) and never
            // transfer it. Leave the state untouched.
            report.skipped.append(id)
        }
    }

    // MARK: - Divergence

    /// Both sides moved since the last common sync. Work out whether that is a real clash.
    ///
    /// Edits to *different* pages are not a conflict and are merged with no prompt — the common
    /// case for one person on two devices. Only a page changed on both sides, or a manifest whose
    /// structure disagrees, needs the user. When it does, **nothing is transferred**: both copies
    /// stay exactly as they are and the sync state is left untouched, so the same conclusion is
    /// reached again next run until it is settled.
    private func reconcileDiverged(
        _ id: String,
        local: NotebookManifest,
        remote: NotebookManifest,
        remoteManifestData: Data,
        remoteEtag: String?,
        report: inout SyncReport
    ) async throws {
        let structural = Self.structurallyDiverges(local: local, remote: remote)
        let remoteEtags = (try? await dav.list(NotableSyncPaths.pagesDir(id)))
            .map { Self.pageEtags(from: $0) } ?? [:]

        var conflicted: [String] = []
        var toDownload: [String] = []
        var toUpload: [String] = []
        for pageId in local.pageIds where remote.pageIds.contains(pageId) {
            // No row means we have never committed this page, so we have no basis to call it
            // changed — matching Notable, which never invents a conflict from missing state.
            guard let row = state[id]?.pages[pageId] else { continue }
            let localDirty = localPageUpdatedAt(id, pageId).map {
                $0 > row.syncedLocalUpdatedAt        // strict: both sides of this are our own clock
            } ?? false
            // A server that omits ETags can never produce a conflict, by design.
            let remoteMoved = remoteEtags[pageId].map { $0 != row.etag } ?? false

            switch (localDirty, remoteMoved) {
            case (true, true): conflicted.append(pageId)
            case (false, true): toDownload.append(pageId)
            case (true, false): toUpload.append(pageId)
            case (false, false): break
            }
        }

        guard conflicted.isEmpty, !structural else {
            report.conflicts.append(
                NotebookConflict(
                    notebookId: id, pageIds: conflicted.sorted(), structural: structural))
            return
        }

        // Nothing actually differs — the manifest ETag moved without the content following it
        // (a rewrite with identical bytes, or a server that rotates ETags on touch). Adopt the new
        // ETag and stop: re-publishing an identical manifest would just rotate it again and make
        // every future sync repeat this.
        if toDownload.isEmpty, toUpload.isEmpty {
            state[id] = NotebookSyncState(
                localUpdatedAtAtSync: epochMs(local.updatedAt) ?? 0,
                etag: remoteEtag ?? state[id]?.etag,
                pages: state[id]?.pages ?? [:])
            report.skipped.append(id)
            return
        }

        // Independent edits: take both sides. Pages first, manifest last, as everywhere else.
        for pageId in toDownload {
            let page = try await dav.get(NotableSyncPaths.pageFile(id, pageId))
            try page.data.write(to: localPageURL(id, pageId), options: .atomic)
            recordPageState(id, pageId, etag: page.etag)
        }
        for pageId in toUpload {
            guard let data = try? Data(contentsOf: localPageURL(id, pageId)) else { continue }
            let etag = try await dav.put(
                NotableSyncPaths.pageFile(id, pageId), data: data,
                ifMatch: state[id]?.pages[pageId]?.etag)
            recordPageState(id, pageId, etag: etag)
        }

        // The manifests agree structurally, so either is correct; keep the newer clock so the
        // merged result reads as at least as fresh as both inputs on the next comparison.
        var merged = local
        if let localMs = epochMs(local.updatedAt), let remoteMs = epochMs(remote.updatedAt),
           remoteMs > localMs
        {
            merged.updatedAt = remote.updatedAt
        }
        let mergedData = try JSONEncoder().encode(merged)
        let newEtag = try await dav.put(
            NotableSyncPaths.manifestFile(id), data: mergedData, ifMatch: remoteEtag)
        try mergedData.write(to: localManifestURL(id), options: .atomic)
        if let mergedMs = epochMs(merged.updatedAt) {
            state[id]?.localUpdatedAtAtSync = mergedMs
            state[id]?.etag = newEtag
        }
        report.merged.append(id)
    }

    /// The manifest fields that must agree for two copies to be mergeable page by page.
    ///
    /// `updatedAt` and `openPageId` are deliberately excluded: they differ on every independent
    /// edit and on merely opening a notebook, and neither says anything about structure. This list
    /// matches Notable's `structurallyDiverges` exactly — if the two clients disagree here they
    /// will disagree about what is a conflict.
    static func structurallyDiverges(local: NotebookManifest, remote: NotebookManifest) -> Bool {
        local.pageIds != remote.pageIds
            || local.title != remote.title
            || local.parentFolderId != remote.parentFolderId
            || local.defaultBackground != remote.defaultBackground
            || local.defaultBackgroundType != remote.defaultBackgroundType
            || local.linkedExternalUri != remote.linkedExternalUri
            || local.createdAt != remote.createdAt
    }

    /// `pageId -> etag` from a listing of the pages directory. Notable stages uploads as
    /// `<pageId>.json.<uuid>.tmp`, so anything that is not exactly `<pageId>.json` is ignored
    /// rather than mistaken for a page.
    static func pageEtags(from resources: [DavResource]) -> [String: String] {
        var result: [String: String] = [:]
        for res in resources where !res.isCollection && res.name.hasSuffix(".json") {
            let pageId = String(res.name.dropLast(".json".count))
            guard !pageId.isEmpty, !pageId.contains("."), let etag = res.etag else { continue }
            result[pageId] = etag
        }
        return result
    }

    private func localPageUpdatedAt(_ id: String, _ pageId: String) -> Int64? {
        guard let data = try? Data(contentsOf: localPageURL(id, pageId)),
              let page = try? JSONDecoder().decode(PageFile.self, from: data)
        else { return nil }
        return epochMs(page.updatedAt)
    }

    private func recordPageState(_ id: String, _ pageId: String, etag: String?) {
        guard let updatedAt = localPageUpdatedAt(id, pageId) else { return }
        state[id, default: NotebookSyncState(localUpdatedAtAtSync: 0, etag: nil)]
            .pages[pageId] = PageSyncState(syncedLocalUpdatedAt: updatedAt, etag: etag)
    }

    // MARK: - Upload

    private func upload(_ id: String, ifMatch: String?, report: inout SyncReport) async throws {
        guard let manifest = readLocalManifest(id),
              let manifestData = try? Data(contentsOf: localManifestURL(id))
        else { throw WebDAVError.notFound(path: "local manifest \(id)") }

        try await dav.makeCollection(NotableSyncPaths.notebookDir(id))
        try await dav.makeCollection(NotableSyncPaths.pagesDir(id))

        // Pages first, manifest last: a concurrent reader never sees a manifest that
        // references missing pages.
        //
        // Guarded by the ETag we last saw for that page, so a page changed underneath us 412s
        // instead of being silently flattened. A page we have never committed has no ETag to guard
        // with and goes up unguarded — that is a first upload, not a race. A 412 propagates out of
        // `upload` before the manifest is published, so a failed run commits nothing.
        for pageId in manifest.pageIds {
            let url = localPageURL(id, pageId)
            guard let data = try? Data(contentsOf: url) else { continue }
            let etag = try await dav.put(
                NotableSyncPaths.pageFile(id, pageId), data: data,
                ifMatch: state[id]?.pages[pageId]?.etag)
            recordPageState(id, pageId, etag: etag)
        }

        // Orphan cleanup, mirroring Notable v0.2.6. The path is always rebuilt from the pages dir
        // rather than reusing `res.path`: a PROPFIND href is server-absolute and carries the
        // transport's base prefix, while `delete` takes base-relative paths. Passing the href
        // through would aim the DELETE outside our tree on any base URL that has a path.
        if let remotePages = try? await dav.list(NotableSyncPaths.pagesDir(id)) {
            let valid = Set(manifest.pageIds.map { "\($0).json" })
            for res in remotePages where !res.isCollection && !valid.contains(res.name) {
                try? await dav.delete(NotableSyncPaths.pagesDir(id) + "/" + res.name)
            }
        }

        // Assets before the manifest, for the same reason as pages. Failures are recorded and
        // stepped over — a background that will not upload must not cost the user their strokes.
        await uploadAssets(
            id, from: localImagesDir(id), to: NotableSyncPaths.imagesDir(id), report: &report)
        await uploadAssets(
            id, from: localBackgroundsDir(id), to: NotableSyncPaths.backgroundsDir(id),
            report: &report)

        var newEtag = try await dav.put(
            NotableSyncPaths.manifestFile(id), data: manifestData, ifMatch: ifMatch)
        if newEtag == nil {
            // Server didn't return an ETag on PUT (allowed); fetch it.
            newEtag = (try? await dav.list(NotableSyncPaths.notebookDir(id)))?
                .first { $0.name == "manifest.json" }?.etag
        }
        if let localUpdatedAt = epochMs(manifest.updatedAt) {
            state[id] = NotebookSyncState(
                localUpdatedAtAtSync: localUpdatedAt, etag: newEtag,
                pages: state[id]?.pages ?? [:])
        }
    }

    // MARK: - Download

    private func download(_ id: String, report: inout SyncReport) async throws {
        let result = try await dav.get(NotableSyncPaths.manifestFile(id))
        try await downloadContent(
            id, manifestData: result.data, etag: result.etag, report: &report)
    }

    private func downloadContent(
        _ id: String, manifestData: Data, etag: String?, report: inout SyncReport
    ) async throws {
        let manifest = try JSONDecoder().decode(NotebookManifest.self, from: manifestData)
        let pagesDir = localNotebookDir(id).appendingPathComponent("pages")
        try FileManager.default.createDirectory(at: pagesDir, withIntermediateDirectories: true)

        // Atomic: the app reads these files on the main thread while this runs, and a torn read
        // surfaces as "could not open page" over work that is actually fine.
        for pageId in manifest.pageIds {
            let page = try await dav.get(NotableSyncPaths.pageFile(id, pageId))
            try page.data.write(to: localPageURL(id, pageId), options: .atomic)
            recordPageState(id, pageId, etag: page.etag)
        }

        // Remove local pages no longer in the manifest.
        let valid = Set(manifest.pageIds.map { "\($0).json" })
        let existing = (try? FileManager.default.contentsOfDirectory(atPath: pagesDir.path)) ?? []
        for file in existing where !valid.contains(file) {
            try? FileManager.default.removeItem(at: pagesDir.appendingPathComponent(file))
        }

        // Page images and PDF/image backgrounds. Without these a notebook written on the BOOX
        // opens as blank paper — BackgroundRenderer resolves them by name under the notebook dir
        // and degrades silently to nil when they are missing.
        await downloadAssets(
            id, from: NotableSyncPaths.imagesDir(id), to: localImagesDir(id), report: &report)
        await downloadAssets(
            id, from: NotableSyncPaths.backgroundsDir(id), to: localBackgroundsDir(id),
            report: &report)

        // Manifest last: local dir is never a manifest pointing at missing pages.
        try manifestData.write(to: localManifestURL(id), options: .atomic)

        if let updatedAt = epochMs(manifest.updatedAt) {
            state[id] = NotebookSyncState(
                localUpdatedAtAtSync: updatedAt, etag: etag, pages: state[id]?.pages ?? [:])
        }
    }

    // MARK: - Assets

    /// Mirrors one optional asset directory in either direction.
    ///
    /// Assets are immutable blobs referenced by name — neither client rewrites one in place — so
    /// presence is a sufficient test and no ETag bookkeeping is needed. Files are only ever added:
    /// nothing is deleted, because the other client may hold the only copy of an asset that a page
    /// its manifest still references points at.
    ///
    /// Both directories are optional; a notebook that has never had an image simply has no such
    /// folder, so a 404 listing is "nothing to do", not an error. Individual failures land in the
    /// report and are stepped over, so a missing background never fails the notebook.
    private func downloadAssets(
        _ id: String, from remoteDir: String, to localDir: URL, report: inout SyncReport
    ) async {
        guard let listing = try? await dav.list(remoteDir) else { return }
        let files = listing.filter { !$0.isCollection }
        guard !files.isEmpty else { return }
        do {
            try FileManager.default.createDirectory(at: localDir, withIntermediateDirectories: true)
        } catch {
            report.errors.append("\(id): cannot create \(localDir.lastPathComponent) (\(error))")
            return
        }
        for res in files {
            let destination = localDir.appendingPathComponent(res.name)
            guard !FileManager.default.fileExists(atPath: destination.path) else { continue }
            do {
                // Path rebuilt from `remoteDir`, never `res.path`: hrefs are server-absolute and
                // carry the transport's base prefix, while `get` takes base-relative paths.
                let asset = try await dav.get(remoteDir + "/" + res.name)
                try asset.data.write(to: destination)
            } catch {
                report.errors.append("\(id): asset \(res.name) (\(error))")
            }
        }
    }

    private func uploadAssets(
        _ id: String, from localDir: URL, to remoteDir: String, report: inout SyncReport
    ) async {
        let names = localFileNames(in: localDir)
        guard !names.isEmpty else { return }
        let remoteNames = Set(
            ((try? await dav.list(remoteDir)) ?? []).filter { !$0.isCollection }.map(\.name))
        let missing = names.filter { !remoteNames.contains($0) }
        guard !missing.isEmpty else { return }
        do {
            try await dav.makeCollection(remoteDir)
        } catch {
            report.errors.append("\(id): cannot create \(remoteDir) (\(error))")
            return
        }
        for name in missing {
            do {
                let data = try Data(contentsOf: localDir.appendingPathComponent(name))
                try await dav.put(remoteDir + "/" + name, data: data)
            } catch {
                report.errors.append("\(id): asset \(name) (\(error))")
            }
        }
    }

    /// Regular files only — subdirectories and dotfiles are not assets.
    private func localFileNames(in dir: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { name in
            guard !name.hasPrefix(".") else { return false }
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(
                atPath: dir.appendingPathComponent(name).path, isDirectory: &isDirectory)
            return exists && !isDirectory.boolValue
        }
    }

    // MARK: - Folders

    /// Union-by-id merge of `<root>/folders.json` with `/notable/folders.json`; newer
    /// `updatedAt` wins per folder. PUTs only when the merge changed the remote view,
    /// and rewrites the local file only when it differs from the merged result.
    ///
    /// Returns the folder ids the server holds once this step is done — the folder half of
    /// the remote index. Folders the merge failed to push stay out of it, so they keep
    /// reading as local-only in the UI. `sawRemoteFile` reports whether the server already had a
    /// `folders.json` before this run, which is one of the signals that the tree is somebody's
    /// real library rather than an empty directory we just made.
    private func syncFolders(
        _ report: inout SyncReport
    ) async -> (ids: Set<String>, sawRemoteFile: Bool) {
        let localURL = rootURL.appendingPathComponent("folders.json")
        let localFile = (try? Data(contentsOf: localURL))
            .flatMap { try? JSONDecoder().decode(FoldersFile.self, from: $0) }

        var remoteFile: FoldersFile?
        var remoteData: Data?
        do {
            let result = try await dav.get(NotableSyncPaths.foldersFile)
            remoteData = result.data
            remoteFile = try? JSONDecoder().decode(FoldersFile.self, from: result.data)
        } catch WebDAVError.notFound {
            // Absent remote: treated as empty.
        } catch {
            report.errors.append("folders: \(error)")
            return ([], false)
        }
        let sawRemoteFile = remoteData != nil
        var serverFolderIds = Set((remoteFile?.folders ?? []).map(\.id))
        guard localFile != nil || remoteData != nil else { return (serverFolderIds, sawRemoteFile) }

        let merged = FolderMerge.merge(
            local: localFile?.folders ?? [], remote: remoteFile?.folders ?? [])
        let remoteSorted = (remoteFile?.folders ?? []).sorted { $0.id < $1.id }
        let localSorted = (localFile?.folders ?? []).sorted { $0.id < $1.id }

        try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        if merged != remoteSorted || remoteFile == nil {
            let out = FoldersFile(folders: merged, serverTimestamp: NotableDate.format(Date()))
            do {
                let data = try JSONEncoder().encode(out)
                try await dav.put(NotableSyncPaths.foldersFile, data: data)
                try? data.write(to: localURL)
                serverFolderIds = Set(merged.map(\.id))
                report.uploaded.append("folders.json")
            } catch {
                report.errors.append("folders: \(error)")
            }
        } else if merged != localSorted || localFile == nil {
            // Remote view already matches the merge; adopt its exact bytes locally.
            if let remoteData {
                try? remoteData.write(to: localURL)
                report.downloaded.append("folders.json")
            }
        }
        return (serverFolderIds, sawRemoteFile)
    }

    // MARK: - Conflict resolution

    /// Settles one conflicted page by *rebaselining*, not by transferring.
    ///
    /// Choosing a side is expressed as an adjustment to what we believe the last common state was,
    /// so the very next ordinary sync sees an unambiguous one-sided change and moves it with all
    /// the usual guards. Notable resolves the same way, which is why the two agree on the outcome.
    public func resolvePage(
        notebookId: String, pageId: String, resolution: PageResolution
    ) async throws {
        guard resolution != .skip else { return }
        if state.isEmpty { loadState() }
        guard var row = state[notebookId]?.pages[pageId] else { return }

        switch resolution {
        case .keepMine:
            // Adopt the server's current ETag so the page no longer reads as remotely changed,
            // while leaving our own anchor behind so it still reads as locally dirty -> upload.
            let etags = (try? await dav.list(NotableSyncPaths.pagesDir(notebookId)))
                .map { Self.pageEtags(from: $0) } ?? [:]
            row.etag = etags[pageId]
        case .useRemote:
            // Mark our copy as not-dirty and the remote as changed -> download.
            row.syncedLocalUpdatedAt = localPageUpdatedAt(notebookId, pageId)
                ?? row.syncedLocalUpdatedAt
            row.etag = nil
        case .skip:
            return
        }
        state[notebookId]?.pages[pageId] = row
        saveState()
    }

    /// Settles a structurally conflicted notebook.
    ///
    /// Taking the server copy is done here and now — rebaselining into it is not possible, because
    /// any anchor that makes our copy read as "not moved" also leaves the timestamp comparison
    /// free to pick our side again. Keeping ours *is* a rebaseline, so the ordinary upload path
    /// does the work with all its usual guards. Notable splits the two the same way.
    public func resolveNotebook(
        notebookId: String, resolution: NotebookResolution
    ) async throws {
        if state.isEmpty { loadState() }
        guard state[notebookId] != nil else { return }

        switch resolution {
        case .useRemote:
            var report = SyncReport()
            let result = try await dav.get(NotableSyncPaths.manifestFile(notebookId))
            try await downloadContent(
                notebookId, manifestData: result.data, etag: result.etag, report: &report)
        case .keepMine:
            // Adopt the server's current ETags as our base — manifest and every page — while
            // keeping the old local anchor, so our copy still reads as dirty and is uploaded next
            // run, now guarded by ETags that will not 412.
            let manifestEtag = (try? await dav.list(NotableSyncPaths.notebookDir(notebookId)))?
                .first { $0.name == "manifest.json" }?.etag
            let pageEtags = (try? await dav.list(NotableSyncPaths.pagesDir(notebookId)))
                .map { Self.pageEtags(from: $0) } ?? [:]
            state[notebookId]?.etag = manifestEtag
            for (pageId, etag) in pageEtags {
                if state[notebookId]?.pages[pageId] != nil {
                    state[notebookId]?.pages[pageId]?.etag = etag
                } else {
                    state[notebookId]?.pages[pageId] = PageSyncState(
                        syncedLocalUpdatedAt: 0, etag: etag)
                }
            }
        }
        saveState()
    }

    // MARK: - Tombstones

    /// Deletes locally and records the id as pending, then tries to tombstone the server
    /// immediately. Offline is fine: the id stays pending and the tombstone is uploaded
    /// at the start of the next sync.
    public func deleteNotebook(_ id: String) async throws {
        if state.isEmpty { loadState() }
        try? FileManager.default.removeItem(at: localNotebookDir(id))
        state[id] = nil
        PendingDeletions.add(id, root: rootURL)
        saveState()
        if var index = RemoteIndex.load(root: rootURL), index.notebookIds.contains(id) {
            index.notebookIds.remove(id)
            try? index.save(root: rootURL)
        }
        do {
            try await dav.makeCollection(NotableSyncPaths.root)
            try await dav.makeCollection(NotableSyncPaths.tombstonesDir)
            try await dav.put(NotableSyncPaths.tombstone(id), data: Data())
            PendingDeletions.remove(id, root: rootURL)
        } catch {
            // Server unreachable: deletion stays pending.
        }
    }

    private func fetchTombstoneIds(_ report: inout SyncReport) async -> Set<String> {
        do {
            return Set(try await dav.list(NotableSyncPaths.tombstonesDir)
                .filter { !$0.isCollection }.map(\.name))
        } catch WebDAVError.notFound {
            return []
        } catch {
            report.errors.append("server: cannot list tombstones (\(error))")
            return []
        }
    }

    // MARK: - Local filesystem

    private func localNotebookDir(_ id: String) -> URL {
        rootURL.appendingPathComponent("notebooks/\(id)", isDirectory: true)
    }
    private func localManifestURL(_ id: String) -> URL {
        localNotebookDir(id).appendingPathComponent("manifest.json")
    }
    private func localPageURL(_ id: String, _ pageId: String) -> URL {
        localNotebookDir(id).appendingPathComponent("pages/\(pageId).json")
    }
    /// These two mirror the server's `images/` and `backgrounds/` names exactly, which is also
    /// where `BackgroundRenderer` looks when resolving a page's assets by basename.
    private func localImagesDir(_ id: String) -> URL {
        localNotebookDir(id).appendingPathComponent("images", isDirectory: true)
    }
    private func localBackgroundsDir(_ id: String) -> URL {
        localNotebookDir(id).appendingPathComponent("backgrounds", isDirectory: true)
    }
    private func localNotebookExists(_ id: String) -> Bool {
        FileManager.default.fileExists(atPath: localManifestURL(id).path)
    }
    private func listLocalNotebookIds() -> Set<String> {
        let dir = rootURL.appendingPathComponent("notebooks")
        let ids = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return Set(ids.filter { localNotebookExists($0) })
    }
    private func readLocalManifest(_ id: String) -> NotebookManifest? {
        guard let data = try? Data(contentsOf: localManifestURL(id)) else { return nil }
        return try? JSONDecoder().decode(NotebookManifest.self, from: data)
    }

    private func epochMs(_ iso: String) -> Int64? {
        NotableDate.parse(iso).map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) }
    }

    // MARK: - State persistence

    private func loadState() {
        guard let data = try? Data(contentsOf: stateURL),
              let decoded = try? JSONDecoder().decode([String: NotebookSyncState].self, from: data)
        else { return }
        state = decoded
    }

    private func saveState() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try? data.write(to: stateURL)
    }

    // MARK: - Remote index

    /// Records what the server holds so the library UI can mark items on-server vs
    /// local-only without talking to the network. Rewritten wholesale after each completed
    /// sync, so ids that disappeared from the server drop out on their own.
    private func saveRemoteIndex(notebookIds: Set<String>, folderIds: Set<String>) {
        let index = RemoteIndex(
            notebookIds: notebookIds, folderIds: folderIds,
            syncedAt: NotableDate.format(Date()))
        try? index.save(root: rootURL)
    }
}
