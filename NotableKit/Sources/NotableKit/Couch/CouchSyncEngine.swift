import Foundation

// MARK: - Local state

/// What this device believes about the server. Losing it is safe: every document re-pushes
/// (409 → merge → usually identical) and the feed replays from `0`, which is slow but correct
/// because every merge is idempotent. That is the difference from the WebDAV engine, where a
/// lost state file produced a wall of unresolvable conflicts.
public struct CouchSyncState: Codable, Equatable, Sendable {
    /// Change-feed checkpoint. `"0"` means "replay everything".
    public var lastSeq: String
    /// Last revision this device wrote or applied, per document id. Doubles as echo suppression.
    public var revs: [String: String]
    /// The outbox: documents changed locally and not yet accepted by the server.
    public var dirty: Set<String>

    public init(lastSeq: String = "0", revs: [String: String] = [:], dirty: Set<String> = []) {
        self.lastSeq = lastSeq
        self.revs = revs
        self.dirty = dirty
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lastSeq = try c.decodeIfPresent(String.self, forKey: .lastSeq) ?? "0"
        revs = try c.decodeIfPresent([String: String].self, forKey: .revs) ?? [:]
        dirty = try c.decodeIfPresent(Set<String>.self, forKey: .dirty) ?? []
    }
}

// MARK: - Document bodies

/// A locally deleted notebook or folder. Written to CouchDB as a `_deleted` document that keeps
/// its body, so the peer can apply delete-vs-edit rather than just seeing a document vanish.
public struct CouchDeletedDoc: Codable, Equatable, Sendable {
    public var type: String
    public var schema: Int
    public var deletedAt: String
    public var updatedAt: String
    public var updatedBy: String

    public init(
        type: String, schema: Int = couchSchemaVersion,
        deletedAt: String, updatedAt: String? = nil, updatedBy: String
    ) {
        self.type = type
        self.schema = schema
        self.deletedAt = deletedAt
        self.updatedAt = updatedAt ?? deletedAt
        self.updatedBy = updatedBy
    }
}

/// One document's content, in whichever shape its id prefix implies.
public enum CouchDocBody: Equatable, Sendable {
    case page(CouchPage)
    case notebook(CouchNotebook)
    case folder(CouchFolder)
    case asset(CouchAsset)
    case deleted(CouchDeletedDoc)

    public var isDeleted: Bool {
        if case .deleted = self { return true }
        return false
    }

    /// `updatedAt` regardless of shape — the input to delete-vs-edit.
    var updatedAt: String {
        switch self {
        case .page(let p): return p.updatedAt
        case .notebook(let n): return n.updatedAt
        case .folder(let f): return f.updatedAt
        case .asset(let a): return a.updatedAt
        case .deleted(let d): return d.updatedAt
        }
    }

    /// The `asset:` documents this body names. Only a page names any; the engine uses this to send
    /// an image's bytes before the page that places it, and to fetch them when one arrives.
    var referencedAssetIDs: [String] {
        guard case .page(let page) = self else { return [] }
        return page.images.compactMap(\.assetId).filter { CouchAssetID.sha256Hex(ofAssetID: $0) != nil }
    }
}

extension CouchMerge {
    /// Merges two versions of the same document, including the delete-vs-edit case.
    ///
    /// Mismatched shapes (a page against a notebook) cannot arise from a well-formed database —
    /// the id prefix fixes the type — so they are reported rather than guessed at.
    public static func merge(_ a: CouchDocBody, _ b: CouchDocBody) -> CouchDocBody? {
        switch (a, b) {
        case (.page(let x), .page(let y)): return .page(merge(x, y))
        case (.notebook(let x), .notebook(let y)): return .notebook(merge(x, y))
        case (.folder(let x), .folder(let y)): return .folder(merge(x, y))

        // Protocol §5.4: an asset's id is the hash of its bytes, so two copies of one id are the
        // same bytes. There is nothing to reconcile.
        case (.asset(let x), .asset): return .asset(x)

        case (.deleted(let x), .deleted(let y)):
            return .deleted(CouchDeletedDoc(
                type: x.type, schema: Swift.max(x.schema, y.schema),
                deletedAt: earlier(x.deletedAt, y.deletedAt),
                updatedAt: later(x.updatedAt, y.updatedAt),
                updatedBy: wins((x.updatedAt, x.updatedBy, ""), over: (y.updatedAt, y.updatedBy, ""))
                    ? x.updatedBy : y.updatedBy))

        case (.deleted(let tomb), let live), (let live, .deleted(let tomb)):
            // An edit made after the deletion resurrects the document; otherwise the delete stands.
            switch resolveDeletion(liveUpdatedAt: live.updatedAt, tombstoneDeletedAt: tomb.deletedAt) {
            case .resurrect: return live
            case .applyDeletion: return .deleted(tomb)
            }

        default:
            return nil
        }
    }
}

// MARK: - Local store

/// How the engine reaches this device's own copy. bopa implements it over the notebook
/// directory; notable implements the same protocol over Room.
public protocol CouchLocalStore: Sendable {
    /// Current local content, or nil when this device has never held the document.
    func load(_ documentID: String) throws -> CouchDocBody?
    /// Replaces local content with the merged result.
    ///
    /// `basedOn` is the local copy the merge actually consumed — nil when this device held none.
    /// It is not the same thing as what is on disk now: computing a merge takes a network round
    /// trip, and the editor goes on saving strokes throughout. Only content the merge *saw* and
    /// chose to drop may be removed here; anything that arrived since is work this merge knows
    /// nothing about, and dropping it would destroy ink that was never given the chance to sync.
    func apply(_ documentID: String, _ body: CouchDocBody, basedOn: CouchDocBody?) throws
    /// A document that could not be understood (undecodable, or a newer `schema`). The
    /// implementation keeps the local copy untouched and materializes the remote one alongside it
    /// under a new identity — protocol §6.5. Never overwrite on this path.
    func applyConflictCopy(_ documentID: String, json: Data) throws

    /// `asset:<sha256>` ids a local page places but whose bytes this device does not hold — an
    /// image the peer drew in, whose blob has still to be fetched.
    ///
    /// The store answers rather than the engine because only the store knows where the bytes will
    /// go, and the answer has to survive a restart: a page can arrive in one session and its image
    /// only be fetchable in the next.
    func missingAssetIDs() throws -> [String]
}

public extension CouchLocalStore {
    /// A store that holds no images has none to fetch. Saves every test double from restating it.
    func missingAssetIDs() throws -> [String] { [] }

    /// Writes content that is not the result of a merge — seeding a store, or landing bytes whose
    /// document nothing local can contradict. There is no snapshot to preserve content against, so
    /// the body is written as given.
    func apply(_ documentID: String, _ body: CouchDocBody) throws {
        try apply(documentID, body, basedOn: nil)
    }
}

// MARK: - Engine

public actor CouchSyncEngine {
    public struct FlushReport: Equatable, Sendable {
        public var pushed: [String] = []
        public var merged: [String] = []
        public var stillDirty: [String] = []
        public var failures: [String: String] = [:]
        /// Set when the mass-deletion guard refused the run (protocol §6.6).
        public var blockedByDeletionGuard = false

        public init() {}
    }

    public struct PullReport: Equatable, Sendable {
        public var applied: [String] = []
        /// Documents where the local copy held content the server lacked; queued to push back.
        public var pushBack: [String] = []
        public var skippedEchoes: [String] = []
        public var conflictCopies: [String] = []
        /// Image blobs downloaded for pages that reference them (protocol §3.4).
        public var fetchedAssets: [String] = []
        public var lastSeq: String = "0"

        public init() {}
    }

    private let client: CouchDBClient
    private let store: CouchLocalStore
    private let deviceID: String
    private let maxPushAttempts: Int
    private var state: CouchSyncState
    private let onStateChange: (@Sendable (CouchSyncState) -> Void)?

    public init(
        client: CouchDBClient,
        store: CouchLocalStore,
        deviceID: String,
        state: CouchSyncState = CouchSyncState(),
        maxPushAttempts: Int = 5,
        onStateChange: (@Sendable (CouchSyncState) -> Void)? = nil
    ) {
        self.client = client
        self.store = store
        self.deviceID = deviceID
        self.state = state
        self.maxPushAttempts = maxPushAttempts
        self.onStateChange = onStateChange
    }

    public var currentState: CouchSyncState { state }
    public var pendingCount: Int { state.dirty.count }

    /// Queues documents for the next flush. Called from every local mutation; safe to call
    /// repeatedly and while offline, which is what makes the outbox the offline story.
    public func markDirty(_ documentIDs: [String]) {
        for id in documentIDs { state.dirty.insert(id) }
        persist()
    }

    // MARK: Push

    public func flush() async -> FlushReport {
        var report = FlushReport()
        let queue = orderedDirty()

        if exceedsDeletionGuard(queue) {
            report.blockedByDeletionGuard = true
            report.stillDirty = queue
            return report
        }

        for documentID in queue {
            do {
                switch try await push(documentID) {
                case .pushed: report.pushed.append(documentID)
                case .mergedThenPushed: report.merged.append(documentID)
                case .nothingToPush: break
                }
            } catch let error as CouchError {
                report.failures[documentID] = String(describing: error)
                report.stillDirty.append(documentID)
                // Offline or a server fault applies to every remaining document too; stopping
                // keeps one dead connection from turning into a burst of doomed requests.
                if error.isRetriable { break }
            } catch {
                report.failures[documentID] = String(describing: error)
                report.stillDirty.append(documentID)
            }
        }
        persist()
        return report
    }

    private enum PushOutcome { case pushed, mergedThenPushed, nothingToPush }

    private func push(_ documentID: String) async throws -> PushOutcome {
        var didMerge = false
        for _ in 0..<maxPushAttempts {
            guard let local = try store.load(documentID) else {
                // Nothing locally: the document was never created, or was cleaned up after being
                // queued. Dropping it from the outbox is right — there is nothing to send.
                state.dirty.remove(documentID)
                return .nothingToPush
            }

            do {
                let rev = try await putBody(documentID, local)
                state.revs[documentID] = rev
                state.dirty.remove(documentID)
                return didMerge ? .mergedThenPushed : .pushed
            } catch CouchError.conflict where CouchDocID.split(documentID)?.type == CouchDocType.asset {
                // Protocol §3.4: an asset id is the hash of its bytes, so a document already at
                // that id *is* this upload. Merging or retrying would only re-send bytes the
                // server demonstrably has.
                //
                // Its revision is read anyway, because a known revision is how the next flush
                // tells "already uploaded" from "never sent" — without it every flush would
                // re-offer the whole image just to be told again that it is there.
                state.revs[documentID] = try? await client.getRaw(documentID)?.rev
                state.dirty.remove(documentID)
                return .pushed
            } catch CouchError.conflict {
                didMerge = true
                guard let remote = try await fetchBody(documentID) else {
                    // Vanished between the write and the re-read: retry as a create.
                    state.revs[documentID] = nil
                    continue
                }
                state.revs[documentID] = remote.rev
                guard let merged = CouchMerge.merge(local, remote.body) else {
                    // Shapes disagree — do not overwrite either side.
                    if let raw = try await client.getRaw(documentID) {
                        try store.applyConflictCopy(documentID, json: raw.json)
                    }
                    state.dirty.remove(documentID)
                    return .nothingToPush
                }
                if merged != local { try store.apply(documentID, merged, basedOn: local) }
                if merged == remote.body {
                    // The server already holds exactly this, so there is nothing left to send.
                    // Returning here is not just an optimization: when the merge resolves to the
                    // peer's tombstone, CouchDB answers 409 to a PUT that re-deletes an already
                    // deleted document *even with its current revision* — so writing it back would
                    // spin until the retries ran out and leave the id stuck in the outbox forever.
                    state.dirty.remove(documentID)
                    return .nothingToPush
                }
            }
        }
        throw CouchError.conflict(documentID: documentID)
    }

    private func putBody(_ documentID: String, _ body: CouchDocBody) async throws -> String {
        let rev = state.revs[documentID]
        switch body {
        case .page(let page): return try await client.put(documentID, rev: rev, body: page)
        case .notebook(let notebook): return try await client.put(documentID, rev: rev, body: notebook)
        case .folder(let folder): return try await client.put(documentID, rev: rev, body: folder)
        case .asset(let asset): return try await client.put(documentID, rev: rev, body: asset)
        case .deleted(let tombstone):
            return try await client.put(documentID, rev: rev, body: tombstone, deleted: true)
        }
    }

    private func fetchBody(_ documentID: String) async throws -> (rev: String, body: CouchDocBody)? {
        guard let raw = try await client.getRaw(documentID) else { return nil }
        guard let body = decode(documentID: documentID, json: raw.json, deleted: raw.deleted) else {
            return nil
        }
        return (raw.rev, body)
    }

    /// Push order: assets, then folders and pages, then notebooks. A notebook names its folder and
    /// its pages, so sending it last means a reader never sees a manifest pointing at documents
    /// that have not landed yet — and an image's bytes go before the page that places it, so the
    /// peer never has a reference it cannot resolve.
    ///
    /// Assets are not queued by the app: nothing "edits" one, and an image placed twice is the same
    /// document. They are derived here from the pages being sent, and skipped once the server is
    /// known to hold them — immutability means a revision we have seen can never go stale.
    private func orderedDirty() -> [String] {
        func rank(_ documentID: String) -> Int {
            switch CouchDocID.split(documentID)?.type {
            case CouchDocType.asset: return 0
            case CouchDocType.folder: return 1
            case CouchDocType.page: return 2
            default: return 3
            }
        }
        var queue = state.dirty
        for documentID in state.dirty
        where CouchDocID.split(documentID)?.type == CouchDocType.page {
            guard let body = try? store.load(documentID) else { continue }
            for assetID in body.referencedAssetIDs where state.revs[assetID] == nil {
                queue.insert(assetID)
            }
        }
        return queue.sorted { (rank($0), $0) < (rank($1), $1) }
    }

    /// Protocol §6.6: a device whose local database was wiped looks exactly like a user who
    /// deleted everything. Ten-plus notebook tombstones that are also most of what this device
    /// knows is treated as the former until a human says otherwise.
    private func exceedsDeletionGuard(_ queue: [String]) -> Bool {
        let tombstones = queue.filter {
            CouchDocID.split($0)?.type == CouchDocType.notebook
                && ((try? store.load($0))?.isDeleted ?? false)
        }
        guard tombstones.count >= 10 else { return false }
        let knownNotebooks = state.revs.keys.filter {
            CouchDocID.split($0)?.type == CouchDocType.notebook
        }
        return tombstones.count * 2 > knownNotebooks.count
    }

    // MARK: Pull

    /// Applies everything the server has seen since the last checkpoint.
    ///
    /// `longpoll` holds the request open until a change arrives — the near-real-time path. A
    /// non-longpoll call returns immediately and is used for catch-up on foreground/reconnect.
    @discardableResult
    public func pull(longpoll: Bool = false, timeoutMs: Int = 55_000) async throws -> PullReport {
        var report = PullReport()
        let changes = try await client.changes(
            since: state.lastSeq, longpoll: longpoll, timeoutMs: timeoutMs)

        for row in changes.rows {
            // Our own write coming back. Applying it would be harmless (merges are idempotent) but
            // it would also mark the document dirty and start a push ping-pong.
            if let known = state.revs[row.id], known == row.rev {
                report.skippedEchoes.append(row.id)
                continue
            }
            // An asset announces itself here without its bytes — the feed carries the document,
            // and CouchDB renders an attachment as a stub. Downloading every image the moment it
            // appears would also mean downloading images for notebooks this device may never open,
            // so the bytes are fetched below, for the pages that turn out to place them.
            if CouchDocID.split(row.id)?.type == CouchDocType.asset {
                state.revs[row.id] = row.rev
                continue
            }
            guard let json = row.json,
                  let incoming = decode(documentID: row.id, json: json, deleted: row.deleted)
            else {
                if let json = row.json {
                    try store.applyConflictCopy(row.id, json: json)
                    report.conflictCopies.append(row.id)
                }
                state.revs[row.id] = row.rev
                continue
            }

            let local = try store.load(row.id)
            let merged: CouchDocBody
            if let local {
                guard let result = CouchMerge.merge(local, incoming) else {
                    try store.applyConflictCopy(row.id, json: json)
                    report.conflictCopies.append(row.id)
                    state.revs[row.id] = row.rev
                    continue
                }
                merged = result
            } else {
                merged = incoming
            }

            try store.apply(row.id, merged, basedOn: local)
            report.applied.append(row.id)
            // Record the server's revision either way: it is the base the next push must use.
            state.revs[row.id] = row.rev
            if merged != incoming {
                // The local copy carried content the server has not seen — push it back.
                state.dirty.insert(row.id)
                report.pushBack.append(row.id)
            }
        }

        state.lastSeq = changes.lastSeq
        report.lastSeq = changes.lastSeq
        report.fetchedAssets = await fetchMissingAssets()
        persist()
        return report
    }

    /// Downloads the blobs local pages reference and this device does not hold yet.
    ///
    /// Driven by the store's own list rather than by what this pull happened to apply, so a fetch
    /// that failed — offline halfway through, a peer that had not uploaded the bytes yet — is
    /// simply retried on the next pull instead of needing the page to change again.
    ///
    /// A failure here never fails the pull: the page and its ink are already applied, and an image
    /// that is still on its way is a picture that has not appeared yet, not lost work.
    private func fetchMissingAssets() async -> [String] {
        guard let wanted = try? store.missingAssetIDs(), !wanted.isEmpty else { return [] }
        var fetched: [String] = []
        for assetID in wanted {
            guard let sha = CouchAssetID.sha256Hex(ofAssetID: assetID) else { continue }
            guard let blob = try? await client.getAttachment(assetID) else { continue }
            // The id is a promise about the bytes. Checking it costs one hash and turns a
            // truncated or mis-served download into a retry rather than into a corrupt image that
            // would then be re-uploaded under a name that does not describe it.
            guard CouchAssetID.sha256Hex(blob.data) == sha else { continue }
            let now = NotableDate.format(Date())
            let asset = CouchAsset(
                contentType: blob.contentType, createdAt: now, updatedAt: now,
                updatedBy: deviceID, data: blob.data)
            guard (try? store.apply(assetID, .asset(asset), basedOn: nil)) != nil else { continue }
            fetched.append(assetID)
        }
        return fetched
    }

    // MARK: Plumbing

    private func decode(documentID: String, json: Data, deleted: Bool) -> CouchDocBody? {
        let decoder = JSONDecoder()
        guard let type = CouchDocID.split(documentID)?.type else { return nil }

        if deleted {
            // A tombstone whose body was stripped (or written by a client that did not keep one)
            // still has to be applied; synthesize the minimum the merge needs.
            let decoded = try? decoder.decode(CouchDeletedDoc.self, from: json)
            return .deleted(decoded ?? CouchDeletedDoc(
                type: type, deletedAt: NotableDate.format(Date()), updatedBy: deviceID))
        }

        // A document from a future schema is not something this build can merge safely.
        if let envelope = try? decoder.decode(SchemaEnvelope.self, from: json),
           envelope.schema > couchSchemaVersion {
            return nil
        }

        switch type {
        case CouchDocType.page:
            return (try? decoder.decode(CouchPage.self, from: json)).map(CouchDocBody.page)
        case CouchDocType.notebook:
            return (try? decoder.decode(CouchNotebook.self, from: json)).map(CouchDocBody.notebook)
        case CouchDocType.folder:
            return (try? decoder.decode(CouchFolder.self, from: json)).map(CouchDocBody.folder)
        default:
            return nil
        }
    }

    private struct SchemaEnvelope: Decodable {
        var schema: Int
    }

    private func persist() {
        onStateChange?(state)
    }
}
