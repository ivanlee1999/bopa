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
    public var uploaded: [String] = []
    public var downloaded: [String] = []
    public var skipped: [String] = []
    public var deletedLocally: [String] = []
    public var conflicts: [String] = []     // 412s: concurrent writer won, re-plan next sync
    public var errors: [String] = []        // "notebookId: message"

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

    private var state: [String: NotebookSyncState] = [:]

    public init(transport: HTTPTransport, rootURL: URL) {
        self.dav = WebDAVClient(transport: transport)
        self.rootURL = rootURL
        self.stateURL = rootURL.appendingPathComponent(".bopa-sync-state.json")
    }

    // MARK: - Entry point

    public func sync() async -> SyncReport {
        var report = SyncReport()
        loadState()

        do {
            try await dav.makeCollection(NotableSyncPaths.root)
            try await dav.makeCollection(NotableSyncPaths.notebooksDir)
            try await dav.makeCollection(NotableSyncPaths.tombstonesDir)
        } catch {
            report.errors.append("server: cannot prepare directories (\(error))")
            return report
        }

        // 1. Tombstones: a deletion wins over existence.
        let tombstones = await fetchTombstoneIds(&report)
        for id in tombstones {
            if localNotebookExists(id) {
                try? FileManager.default.removeItem(at: localNotebookDir(id))
                state[id] = nil
                report.deletedLocally.append(id)
            }
        }

        // 2. Inventory.
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

        // 3. Reconcile the union.
        for id in localIds.union(remoteIds).sorted() {
            do {
                switch (localIds.contains(id), remoteIds.contains(id)) {
                case (true, false):
                    try await upload(id, ifMatch: nil)
                    report.uploaded.append(id)
                case (false, true):
                    try await download(id)
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
            try await upload(id, ifMatch: nil)
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
            try await upload(id, ifMatch: ifMatch)
            report.uploaded.append(id)
        case .download:
            guard let data = remoteManifestData else {
                report.errors.append("\(id): download planned but no manifest data")
                return
            }
            try await downloadContent(id, manifestData: data, etag: remoteInfo?.etag)
            report.downloaded.append(id)
        case .skip, .skipUploadOnly, .skipDownloadOnly:
            // Refresh the state row so future no-op syncs stay cheap.
            if state[id] == nil {
                state[id] = NotebookSyncState(localUpdatedAtAtSync: localUpdatedAt, etag: remoteInfo?.etag)
            }
            report.skipped.append(id)
        }
    }

    // MARK: - Upload

    private func upload(_ id: String, ifMatch: String?) async throws {
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

        // Orphan cleanup, mirroring Notable v0.2.6.
        if let remotePages = try? await dav.list(NotableSyncPaths.pagesDir(id)) {
            let valid = Set(manifest.pageIds.map { "\($0).json" })
            for res in remotePages where !res.isCollection && !valid.contains(res.name) {
                try? await dav.delete(res.path.hasPrefix("/notable/")
                    ? res.path
                    : NotableSyncPaths.pagesDir(id) + "/" + res.name)
            }
        }

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

    private func download(_ id: String) async throws {
        let result = try await dav.get(NotableSyncPaths.manifestFile(id))
        try await downloadContent(id, manifestData: result.data, etag: result.etag)
    }

    private func downloadContent(_ id: String, manifestData: Data, etag: String?) async throws {
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

        // Manifest last: local dir is never a manifest pointing at missing pages.
        try manifestData.write(to: localManifestURL(id))

        if let updatedAt = epochMs(manifest.updatedAt) {
            state[id] = NotebookSyncState(localUpdatedAtAtSync: updatedAt, etag: etag)
        }
    }

    // MARK: - Tombstones

    public func deleteNotebook(_ id: String) async throws {
        try? FileManager.default.removeItem(at: localNotebookDir(id))
        state[id] = nil
        try await dav.makeCollection(NotableSyncPaths.root)
        try await dav.makeCollection(NotableSyncPaths.tombstonesDir)
        try await dav.put(NotableSyncPaths.tombstone(id), data: Data())
        saveState()
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
}
