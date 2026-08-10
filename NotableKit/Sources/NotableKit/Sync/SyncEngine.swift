import Foundation

/// Per-notebook facts committed at the end of each successful transfer, used by the planner
/// next time. Persisted locally (never uploaded).
public struct NotebookSyncState: Codable, Equatable, Sendable {
    public var localUpdatedAtAtSync: Int64   // epoch ms
    public var etag: String?

    public init(localUpdatedAtAtSync: Int64, etag: String?) {
        self.localUpdatedAtAtSync = localUpdatedAtAtSync
        self.etag = etag
    }
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
    public var deletedLocally: [String] = []
    public var conflicts: [String] = []     // 412s: concurrent writer won, re-plan next sync
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

    public func sync() async -> SyncReport {
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
                    try await download(id, report: &report)
                    report.downloaded.append(id)
                case (true, true):
                    try await reconcile(id, report: &report)
                case (false, false):
                    break
                }
            } catch WebDAVError.preconditionFailed {
                report.conflicts.append(id)
            } catch {
                report.errors.append("\(id): \(error)")
            }
        }

        saveState()
        saveRemoteIndex(notebookIds: serverNotebookIds, folderIds: remoteFolderIds)
        return report
    }

    // MARK: - Reconciliation

    private func reconcile(_ id: String, report: inout SyncReport) async throws {
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
            remote: remoteInfo)

        switch action {
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
                etag: remoteInfo?.etag ?? stored?.etag)
            report.skipped.append(id)
        case .skipUploadOnly, .skipDownloadOnly:
            // A transfer was deliberately suppressed by a one-directional mode. Recording
            // "in sync" here would strand the pending change: once the mode is lifted,
            // the planner would see no local movement (or an unchanged remote) and never
            // transfer it. Leave the state untouched.
            report.skipped.append(id)
        }
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
        for pageId in manifest.pageIds {
            let url = localPageURL(id, pageId)
            guard let data = try? Data(contentsOf: url) else { continue }
            try await dav.put(NotableSyncPaths.pageFile(id, pageId), data: data)
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
            state[id] = NotebookSyncState(localUpdatedAtAtSync: localUpdatedAt, etag: newEtag)
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

        for pageId in manifest.pageIds {
            let page = try await dav.get(NotableSyncPaths.pageFile(id, pageId))
            try page.data.write(to: localPageURL(id, pageId))
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
        try manifestData.write(to: localManifestURL(id))

        if let updatedAt = epochMs(manifest.updatedAt) {
            state[id] = NotebookSyncState(localUpdatedAtAtSync: updatedAt, etag: etag)
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
