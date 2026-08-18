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
///     <root>/notebooks/<notebookId>/images/<name>
///     <root>/.bopa-couch-deletions.json     — local tombstones awaiting push
///     <root>/.bopa-couch-assets.json        — image blobs a local page wants, not yet downloaded
///     <root>/.bopa-couch-pending-marks.json — edits whose dirty mark has not reached the engine
public final class FileCouchStore: CouchLocalStore, @unchecked Sendable {
    public let rootURL: URL
    public let deviceID: String
    /// Called after any change the engine applied, so the UI can reload. Never called for reads.
    public var didApplyChanges: (@Sendable () -> Void)?

    private let lock = NSLock()
    /// pageId → notebookId. A page document names only the page, but its file lives under the
    /// notebook, so the directory has to be searched; the answer is worth keeping.
    private var pageIndex: [String: String] = [:]
    /// "<path>|<mtime>|<size>" → sha256. See `cachedSHA256(of:)`.
    private var hashCache: [String: String] = [:]
    /// How bytes are hashed on a cache miss. Injectable so a test can count how many times sync
    /// actually reads an image off disk — the observable difference between the cached and the
    /// uncached paths.
    var hashFileContents: (URL) -> String? = CouchAssetID.sha256Hex(contentsOf:)
    /// Files `apply` has written that have not been forced to stable storage yet. See
    /// `synchronizeAppliedWrites`.
    private var unsynchronizedPaths: [String] = []

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }()
    private let decoder = JSONDecoder()

    /// The clock the deletion ledger stamps from. A tombstone is the one document whose instant
    /// decides whether other people's work survives (§6.4), so a wrong clock here is the most
    /// expensive wrong clock in the protocol — see `SyncClock`.
    private let clock: SyncClock

    public init(rootURL: URL, deviceID: String, clock: SyncClock = .shared) {
        self.rootURL = rootURL
        self.deviceID = deviceID
        self.clock = clock
    }

    // MARK: Paths

    private var notebooksURL: URL { rootURL.appendingPathComponent("notebooks", isDirectory: true) }
    private var foldersURL: URL { rootURL.appendingPathComponent("folders.json") }
    private var deletionsURL: URL { rootURL.appendingPathComponent(".bopa-couch-deletions.json") }
    private var assetsURL: URL { rootURL.appendingPathComponent(".bopa-couch-assets.json") }
    private var pendingMarksURL: URL {
        rootURL.appendingPathComponent(".bopa-couch-pending-marks.json")
    }

    private func notebookDir(_ id: String) -> URL {
        notebooksURL.appendingPathComponent(id, isDirectory: true)
    }
    /// The `backgrounds/` store — where PDF and picture backgrounds live, shared across notebooks
    /// (unlike a page's images, which live with their notebook).
    private var backgroundsURL: URL { CouchBackgroundFiles.directory(under: rootURL) }
    private func manifestURL(_ id: String) -> URL {
        notebookDir(id).appendingPathComponent("manifest.json")
    }
    private func pageURL(notebookId: String, pageId: String) -> URL {
        notebookDir(notebookId).appendingPathComponent("pages/\(pageId).json")
    }

    // MARK: CouchLocalStore

    /// §6.4's liveness: the newest page clock held here for a notebook — ink no longer moves the
    /// envelope, so "was there work after the deletion" is answered by the pages, where the work
    /// actually lands. Reads each listed page file; deletions are rare enough that this is never
    /// on a hot path.
    public func contentClock(_ documentID: String) -> String? {
        guard let (type, id) = CouchDocID.split(documentID),
              type == CouchDocType.notebook,
              let manifest = readManifest(id)
        else { return nil }
        let clocks = manifest.pageIds.compactMap { readPage(notebookId: id, pageId: $0)?.updatedAt }
        guard var newest = clocks.first else { return nil }
        for clock in clocks.dropFirst() { newest = CouchMerge.later(newest, clock) }
        return newest
    }

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
            return .notebook(CouchMapping.couchNotebook(
                from: manifest, deviceID: deviceID, deletedAt: trash().notebooks
                    .first { $0.id == id }?.deletedAt,
                backgroundsDirectory: backgroundsURL, sha256: cachedSHA256(of:)))

        case CouchDocType.page:
            guard let notebookId = notebookID(forPage: id),
                  let page = readPage(notebookId: notebookId, pageId: id)
            else { return nil }
            return .page(CouchMapping.couchPage(
                from: page, deviceID: deviceID, notebookDir: notebookDir(notebookId),
                backgroundsDirectory: backgroundsURL, sha256: cachedSHA256(of:)))

        case CouchDocType.folder:
            guard let folder = readFolders().first(where: { $0.id == id }) else { return nil }
            return .folder(CouchMapping.couchFolder(
                from: folder, deviceID: deviceID, deletedAt: trash().folders
                    .first { $0.id == id }?.deletedAt))

        case CouchDocType.asset:
            guard let url = assetURL(documentID), let data = try? Data(contentsOf: url) else {
                return nil
            }
            // An asset carries no history of its own — it is bytes under the name of their hash.
            // The timestamps describe this device's copy and never decide anything: nothing merges
            // an asset, and nothing overwrites one.
            let stamp = NotableDate.format(
                (try? FileManager.default.attributesOfItem(atPath: url.path)[.creationDate])
                    as? Date ?? Date())
            return .asset(CouchAsset(data: data, at: stamp, updatedBy: deviceID))

        default:
            return nil
        }
    }

    public func apply(_ documentID: String, _ body: CouchDocBody, basedOn: CouchDocBody?) throws {
        guard let (type, id) = CouchDocID.split(documentID) else { return }

        switch body {
        case .page(let page):
            guard let notebookId = page.notebookId ?? notebookID(forPage: id) else { return }
            let existing = readPage(notebookId: notebookId, pageId: id)
            let dir = notebookDir(notebookId)
            let file = CouchMapping.pageFile(
                from: page, id: id, existing: existing, notebookDir: dir,
                backgroundsDirectory: backgroundsURL, sha256: cachedSHA256(of:),
                keeping: survivingStrokes(in: existing, merged: page, basedOn: basedOn))
            try write(encoder.encode(file), to: pageURL(notebookId: notebookId, pageId: id))
            lock.withLock { pageIndex[id] = notebookId }
            noteWantedAssets(of: file, notebookDir: dir)
            noteWantedBackground(file.background, type: file.backgroundType)
            pruneWantedAssets(droppedBy: file, replacing: existing, notebookId: notebookId)

        case .asset(let asset):
            // Where the bytes go was decided when the page that places them was applied; this only
            // fills in the file. An asset nobody references has nowhere to live and is dropped —
            // the engine only fetches assets it was told were wanted, so this is the race where
            // the page went away in between, not a lost image.
            for url in assetURLs(documentID) { try write(asset.data, to: url) }
            forgetWantedAsset(documentID)

        case .notebook(let notebook):
            let existing = readManifest(id)
            let manifest = CouchMapping.manifest(
                from: notebook, id: id, existing: existing,
                backgroundsDirectory: backgroundsURL, sha256: cachedSHA256(of:))
            try write(encoder.encode(manifest), to: manifestURL(id))
            noteWantedBackground(
                manifest.defaultBackground, type: manifest.defaultBackgroundType)
            // The merge decided where this notebook lives — the library or the Trash — so the
            // Trash file follows it in both directions. Without the `nil` case a notebook restored
            // on the BOOX would stay buried here, and the two Trashes would drift apart.
            try lock.withLock {
                try LocalTrash.setNotebook(id, deletedAt: notebook.deletedAt, root: rootURL)
            }
            // A notebook arriving from the server un-deletes it here — that decision was already
            // made by the merge, which resurrects only when the edit is newer than the deletion.
            clearDeletion(documentID)

        case .folder(let folder):
            var folders = readFolders().filter { $0.id != id }
            folders.append(CouchMapping.folderDTO(from: folder, id: id))
            try writeFolders(folders)
            try lock.withLock {
                try LocalTrash.setFolder(id, deletedAt: folder.deletedAt, root: rootURL)
            }
            clearDeletion(documentID)

        case .deleted:
            // Emptied from the Trash somewhere, so it leaves this device's Trash too — the entry
            // would otherwise name a notebook that no longer exists anywhere.
            lock.withLock {
                try? LocalTrash.remove(notebookIDs: [id], folderIDs: [id], root: rootURL)
            }
            switch type {
            case CouchDocType.notebook:
                try? FileManager.default.removeItem(at: notebookDir(id))
                lock.withLock { pageIndex = pageIndex.filter { $0.value != id } }
                // Its pending image downloads go with it. Left behind, each one would be fetched
                // again on every pull and written back into the directory just deleted.
                forgetWantedAssets(under: "notebooks/\(id)/")
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

    /// The hash of a file's bytes, remembered for as long as the file does not change.
    ///
    /// Hashing an image means reading the whole file, and the same page is loaded repeatedly — once
    /// to decide push order, again to push, and again on every merge that touches it. A photo
    /// placed on a page was being read off disk several times per sync for an answer that had not
    /// changed since the last one.
    ///
    /// Keyed by modification date and size rather than by path alone, so an image the user replaces
    /// is hashed afresh: the id has to keep describing the bytes, or it stops being an address.
    private func cachedSHA256(of url: URL) -> String? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let stamp = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970
        let size = (attributes?[.size] as? NSNumber)?.intValue
        // Nothing to key on means nothing to trust: hash it, and do not remember the answer.
        guard let stamp, let size else { return hashFileContents(url) }

        let key = "\(url.path)|\(stamp)|\(size)"
        if let known = lock.withLock({ hashCache[key] }) { return known }
        guard let hash = hashFileContents(url) else { return nil }
        lock.withLock {
            // A page's images, a few pages deep. Cleared wholesale rather than aged, because the
            // entries are cheap and the cost of a miss is one file read.
            if hashCache.count >= 512 { hashCache.removeAll() }
            hashCache[key] = hash
        }
        return hash
    }

    /// Strokes on disk that this merge never saw, and so cannot have decided against.
    ///
    /// Computing a merge takes a network round trip, and `savePage` goes on writing throughout.
    /// Without this, a stroke drawn during that window reads as "present locally, absent from the
    /// result" and is dropped — no tombstone written, nothing left dirty, so the ink is gone from
    /// the file and was never pushed. `basedOn` nil means there was no merge to speak of (a seed,
    /// or a document this device had never held), and the body is taken as given.
    private func survivingStrokes(
        in existing: PageFile?, merged: CouchPage, basedOn: CouchDocBody?
    ) -> [StrokeDTO] {
        guard let existing, case .page(let snapshot)? = basedOn else { return [] }
        let seen = Set(snapshot.strokes.map(\.id))
        let kept = Set(merged.strokes.map(\.id))
        let tombstoned = Set(merged.deletedStrokes.map(\.id))
        return existing.strokes.filter {
            !seen.contains($0.id) && !kept.contains($0.id) && !tombstoned.contains($0.id)
        }
    }

    /// Protocol §6.5. The local copy is left exactly as it is and the remote one is written
    /// alongside under a fresh identity, so a document this build cannot understand costs the
    /// user a duplicate rather than their work.
    public func applyConflictCopy(_ documentID: String, json: Data) throws {
        // Every shape gets a copy, folders included. §6.5's promise is that nothing is discarded,
        // and a folder quietly dropped here is a folder the user never learns went missing.
        guard CouchDocID.split(documentID) != nil else { return }

        let stamp = ISO8601DateFormatter().string(from: clock.now()).prefix(10)
        // Derived from the document and its bytes rather than minted fresh, so re-reading the same
        // unreadable document produces the same copy instead of another one. The feed is replayed
        // from the start whenever a checkpoint is lost — which this design treats as safe — and
        // fresh ids turned every replay into a fresh set of duplicates in the library. Content is
        // part of the name because a *new* unreadable revision genuinely is a different thing.
        let identity = CouchAssetID.sha256Hex(Data(documentID.utf8) + json)
        let newNotebookId = uuidShaped(identity.prefix(32))
        let newPageId = uuidShaped(identity.suffix(32))
        let now = clock.stamp()

        // Whatever could not be decoded is preserved verbatim next to the notebook, because the
        // point of this path is that we do not understand it well enough to rewrite it.
        let manifest = NotebookManifest(
            notebookId: newNotebookId,
            title: "Unreadable sync copy (conflict \(stamp) \(deviceID))",
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

    /// Lays 32 hex characters out in the 8-4-4-4-12 shape the rest of the store expects of an id.
    private func uuidShaped(_ hex: some StringProtocol) -> String {
        let c = Array(hex)
        guard c.count == 32 else { return UUID().uuidString.lowercased() }
        let groups = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32]
        return groups.map { String(c[$0]) }.joined(separator: "-")
    }

    // MARK: Image blobs

    /// Protocol §3.4. An image is placed by the page document and carried by a separate `asset:`
    /// document, so between a page arriving and its blob being downloaded the reference is real
    /// and the picture is not there yet. This records what is still owed, and where it goes.
    ///
    /// Kept on disk rather than in memory because that window can span a restart: bopa can be
    /// closed between receiving the page and having a connection good enough for the bytes.
    public func missingAssetIDs() throws -> [String] {
        wantedAssets()
            .filter { $0.value.contains { !FileManager.default.fileExists(
                atPath: rootURL.appendingPathComponent($0).path) } }
            .keys.sorted()
    }

    /// The files an asset belongs in. More than one when the same picture is placed in two
    /// notebooks — each keeps its own copy, since a notebook's images live with it.
    private func assetURLs(_ assetID: String) -> [URL] {
        if let wanted = wantedAssets()[assetID], !wanted.isEmpty {
            return wanted.map(rootURL.appendingPathComponent)
        }
        return assetURL(assetID).map { [$0] } ?? []
    }

    /// The file behind an asset this device holds. Nothing indexes these: an image is found through
    /// the page that places it, and the hash is its filename whenever this device wrote it.
    ///
    /// Both the notebooks' `images/` and the shared `backgrounds/` store are searched, because
    /// the id says nothing about which it is: a sha256 is a picture placed on a page or a
    /// document a whole notebook is drawn on, and by the time a peer asks, all that is known is
    /// the hash.
    private func assetURL(_ assetID: String) -> URL? {
        guard let sha = CouchAssetID.sha256Hex(ofAssetID: assetID) else { return nil }
        for notebookId in notebookIDs() {
            let byHash = NotableImageFiles.directory(in: notebookDir(notebookId))
                .appendingPathComponent(sha)
            if FileManager.default.fileExists(atPath: byHash.path) { return byHash }
        }
        for folder in TemplateFolder.allCases {
            for name in CouchBackgroundFiles.fileNames(forSHA256Hex: sha) {
                let byHash = backgroundsURL
                    .appendingPathComponent(folder.rawValue, isDirectory: true)
                    .appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: byHash.path) { return byHash }
            }
        }
        // A file that arrived by another route — the WebDAV backend, an import — kept whatever
        // name it had, so the last resort is to ask the files themselves. Only reached when a
        // document places bytes this device holds under a user-facing name; the hashes are
        // remembered (`cachedSHA256`), so a notebook's own PDF is read once and not once per page
        // that names it.
        for notebookId in notebookIDs() {
            let dir = NotableImageFiles.directory(in: notebookDir(notebookId))
            for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] {
                let candidate = dir.appendingPathComponent(name)
                if CouchAssetID.sha256Hex(contentsOf: candidate) == sha { return candidate }
            }
        }
        for folder in TemplateFolder.allCases {
            let dir = backgroundsURL.appendingPathComponent(folder.rawValue, isDirectory: true)
            for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] {
                let candidate = dir.appendingPathComponent(name)
                if cachedSHA256(of: candidate) == sha { return candidate }
            }
        }
        return nil
    }

    /// The backgrounds twin of `noteWantedAssets`: records the blob a file-backed background
    /// still owes, so a later pull can fetch it. Only a hash-named path can be owed — that name
    /// is `CouchMapping.localBackground`'s own output, written when the reference arrived ahead
    /// of its bytes. A missing file under a user-chosen name is genuinely unknown content, and
    /// there is no id to fetch it by.
    private func noteWantedBackground(_ background: String, type backgroundType: String) {
        guard CouchBackgroundFiles.isFileBacked(backgroundType),
              let ref = TemplateRef.parse(
                  background,
                  impliedFolder: CouchBackgroundFiles.folder(for: backgroundType)),
              let sha = CouchBackgroundFiles.sha256Hex(ofFileName: ref.fileName)
        else { return }
        let url = backgroundsURL.appendingPathComponent(ref.relativePath)
        guard !FileManager.default.fileExists(atPath: url.path),
              let relative = relativeToRoot(url)
        else { return }
        let assetID = CouchDocID.asset(sha)
        var wanted = wantedAssets()
        guard !(wanted[assetID] ?? []).contains(relative) else { return }
        wanted[assetID, default: []].append(relative)
        writeWantedAssets(wanted.mapValues { $0.sorted() })
    }

    /// Records the blobs `file` places that are not on disk yet, so a later pull can fetch them.
    private func noteWantedAssets(of file: PageFile, notebookDir: URL) {
        var wanted = wantedAssets()
        var added = false
        for image in file.images {
            guard let url = NotableImageFiles.url(uri: image.uri, notebookDir: notebookDir),
                  !FileManager.default.fileExists(atPath: url.path),
                  let assetID = NotableImageFiles.assetID(forURI: image.uri, notebookDir: notebookDir),
                  let relative = relativeToRoot(url),
                  !(wanted[assetID] ?? []).contains(relative)
            else { continue }
            wanted[assetID, default: []].append(relative)
            added = true
        }
        guard added else { return }
        writeWantedAssets(wanted.mapValues { $0.sorted() })
    }

    /// Forgets wants this merge just orphaned. `noteWantedAssets` only ever adds, and until now
    /// the only removals were a blob actually arriving (`forgetWantedAsset`) and the whole
    /// notebook being deleted — so an image erased (or never uploaded) before its bytes landed
    /// left a permanent want: one doomed 404 GET per pull, and an "images still downloading" note
    /// that never cleared. Rebuilding this page's contribution on every apply is what lets the
    /// ledger forget.
    ///
    /// Only paths this page used to point at and no longer does can have gone stale here —
    /// anything else is another page's business, reconciled when that page changes. And a dropped
    /// path is only forgotten when no other page of the notebook still places it: the ledger's
    /// paths name the notebook's shared images directory, not the page that asked, and two pages
    /// can place the same bytes.
    private func pruneWantedAssets(
        droppedBy file: PageFile, replacing existing: PageFile?, notebookId: String
    ) {
        let dir = notebookDir(notebookId)
        func referencedPaths(_ page: PageFile?) -> Set<String> {
            Set((page?.images ?? []).compactMap {
                NotableImageFiles.url(uri: $0.uri, notebookDir: dir).flatMap(relativeToRoot)
            })
        }
        let dropped = referencedPaths(existing).subtracting(referencedPaths(file))
        guard !dropped.isEmpty else { return }

        var stale = dropped
        let pagesDir = dir.appendingPathComponent("pages", isDirectory: true)
        for name in (try? FileManager.default.contentsOfDirectory(atPath: pagesDir.path)) ?? [] {
            guard !stale.isEmpty else { break }
            guard name.hasSuffix(".json"), name != "\(file.id).json",
                  let data = try? Data(contentsOf: pagesDir.appendingPathComponent(name)),
                  let page = try? decoder.decode(PageFile.self, from: data)
            else { continue }
            stale.subtract(referencedPaths(page))
        }
        guard !stale.isEmpty else { return }

        let all = wantedAssets()
        let kept = all
            .mapValues { $0.filter { !stale.contains($0) } }
            .filter { !$0.value.isEmpty }
        guard kept != all else { return }
        writeWantedAssets(kept)
    }

    private func forgetWantedAsset(_ assetID: String) {
        var all = wantedAssets()
        guard all.removeValue(forKey: assetID) != nil else { return }
        writeWantedAssets(all)
    }

    private func forgetWantedAssets(under prefix: String) {
        let all = wantedAssets()
        let kept = all
            .mapValues { $0.filter { !$0.hasPrefix(prefix) } }
            .filter { !$0.value.isEmpty }
        guard kept != all else { return }
        writeWantedAssets(kept)
    }

    /// Paths are stored relative to the root: an iOS app's container moves between installs, so an
    /// absolute path written today is a path to nowhere after the next update.
    private func relativeToRoot(_ url: URL) -> String? {
        let root = rootURL.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(root + "/") else { return nil }
        return String(path.dropFirst(root.count + 1))
    }

    /// asset id → the paths, relative to the root, its bytes belong at.
    private func wantedAssets() -> [String: [String]] {
        lock.withLock {
            guard let data = try? Data(contentsOf: assetsURL),
                  let all = try? decoder.decode([String: [String]].self, from: data)
            else { return [:] }
            return all
        }
    }

    private func writeWantedAssets(_ all: [String: [String]]) {
        lock.withLock {
            guard let data = try? encoder.encode(all) else { return }
            try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
            try? data.write(to: assetsURL, options: .atomic)
        }
    }

    // MARK: Pending dirty marks

    /// Records that these documents were just edited and their dirty marks have not yet reached
    /// the engine's persisted outbox. The durable half of `SyncBackendHost.didChangeDocuments`,
    /// whose signal hops through an async Task on its way to `markDirty` — an app killed inside
    /// that hop stranded the edit: written to disk, already known to the server, and marked by
    /// nothing, so nothing would ever push it until the document happened to be touched again.
    ///
    /// Same lifecycle as the deletions file: written synchronously at the mutation, folded into
    /// the outbox when the stack is constructed, cleared once the engine confirms the mark.
    ///
    /// Counted rather than kept as a set, because rapid edits to one document overlap: edit A's
    /// confirm must not erase edit B's still-unconfirmed record, or the crash window reopens
    /// exactly where it was. An id leaves the file when every recorded edit is confirmed.
    public func recordPendingMarks(_ documentIDs: [String]) {
        guard !documentIDs.isEmpty else { return }
        mutatePendingMarks { marks in
            for id in documentIDs { marks[id, default: 0] += 1 }
        }
    }

    /// The engine now holds these ids in its persisted outbox — `markDirty` returned — so this
    /// edit's record has done its job.
    public func confirmPendingMarks(_ documentIDs: [String]) {
        guard !documentIDs.isEmpty else { return }
        mutatePendingMarks { marks in
            for id in documentIDs {
                guard let count = marks[id] else { continue }
                marks[id] = count > 1 ? count - 1 : nil
            }
        }
    }

    /// Edits whose journey to the outbox was cut short — what construction folds back in.
    public func pendingMarkIDs() -> [String] {
        lock.withLock { readPendingMarksLocked().keys.sorted() }
    }

    /// One read-modify-write under one lock hold: record (main actor) and confirm (an arbitrary
    /// Task executor) genuinely race, and a torn update here is a lost crash-safety record.
    private func mutatePendingMarks(_ mutate: (inout [String: Int]) -> Void) {
        lock.withLock {
            var marks = readPendingMarksLocked()
            mutate(&marks)
            if marks.isEmpty {
                try? FileManager.default.removeItem(at: pendingMarksURL)
                return
            }
            guard let data = try? encoder.encode(marks) else { return }
            try? FileManager.default.createDirectory(
                at: rootURL, withIntermediateDirectories: true)
            try? data.write(to: pendingMarksURL, options: .atomic)
        }
    }

    private func readPendingMarksLocked() -> [String: Int] {
        guard let data = try? Data(contentsOf: pendingMarksURL),
              let marks = try? decoder.decode([String: Int].self, from: data)
        else { return [:] }
        return marks
    }

    // MARK: Local deletions

    /// Records a locally-initiated deletion so the engine pushes a tombstone. Survives a restart,
    /// which is what makes deleting a notebook while offline work.
    public func recordDeletion(_ documentID: String, deletedAt: String? = nil) {
        var all = deletions()
        all[documentID] = deletedAt ?? clock.stamp()
        writeDeletions(all)
    }

    public func pendingDeletionIDs() -> [String] {
        deletions().keys.sorted()
    }

    /// Abandons a locally-initiated deletion without publishing it — §6.7's "keep them on the
    /// server". The record is what makes `load` answer `.deleted`, so dropping it is what stops
    /// the tombstone being produced again on the flush after next.
    ///
    /// The notebook's files are already gone from disk; nothing here brings them back. The copy on
    /// the server does, on the next pull, because this device never told it otherwise.
    public func forgetDeletion(_ documentID: String) throws {
        clearDeletion(documentID)
    }

    private func clearDeletion(_ documentID: String) {
        var all = deletions()
        guard all.removeValue(forKey: documentID) != nil else { return }
        writeDeletions(all)
    }

    /// This device's copy of the Trash. Read per call rather than cached: the app writes the same
    /// file when the user throws something away, and a stale copy here would publish a notebook as
    /// live moments after it was binned.
    private func trash() -> LocalTrash.Contents {
        lock.withLock { LocalTrash.load(root: rootURL) }
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
            serverTimestamp: clock.stamp())
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
        // Remembered for `synchronizeAppliedWrites`: `.atomic` is a rename, not a barrier, and
        // the engine must be able to make this write durable before it checkpoints past it.
        lock.withLock { unsynchronizedPaths.append(url.path) }
    }

    /// Test hook: the files written by `apply` that are still awaiting `synchronizeAppliedWrites`.
    var pendingSynchronizationPaths: [String] {
        lock.withLock { unsynchronizedPaths }
    }

    /// Forces every document file written since the last call down to stable storage — the
    /// engine's barrier before it persists sync state.
    ///
    /// Both a document write and the state file are `.atomic` renames, and APFS may commit the
    /// tiny state rename while an earlier page file's *data* has never reached stable storage.
    /// After a power loss the state then carries `lastSeq` past the row and `revs[id]` for it, so
    /// the feed never replays the row and a refetch is suppressed as this device's own echo — the
    /// document is silently gone. Syncing the documents first makes the checkpoint unable to
    /// outrun what it describes.
    ///
    /// `F_FULLFSYNC` rather than `fsync`/`FileHandle.synchronize`: on Apple platforms `fsync`
    /// only pushes to the drive's cache, and `F_FULLFSYNC` is the documented barrier that flushes
    /// through to permanent storage — the same call SQLite relies on — which also carries the
    /// journaled rename metadata issued before it. On a filesystem that does not support it,
    /// plain `fsync` is the best effort left. Failures are swallowed: an unreadable path here is
    /// a file already replaced or removed, not new damage, and the write itself already succeeded.
    public func synchronizeAppliedWrites() {
        let paths = lock.withLock {
            let pending = unsynchronizedPaths
            unsynchronizedPaths.removeAll()
            return pending
        }
        for path in paths {
            guard let handle = FileHandle(forReadingAtPath: path) else { continue }
            if fcntl(handle.fileDescriptor, F_FULLFSYNC) != 0 { try? handle.synchronize() }
            try? handle.close()
        }
    }
}
