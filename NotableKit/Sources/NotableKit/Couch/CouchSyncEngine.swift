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
        case .deleted(let d): return d.updatedAt
        }
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
    func apply(_ documentID: String, _ body: CouchDocBody) throws
    /// A document that could not be understood (undecodable, or a newer `schema`). The
    /// implementation keeps the local copy untouched and materializes the remote one alongside it
    /// under a new identity — protocol §6.5. Never overwrite on this path.
    func applyConflictCopy(_ documentID: String, json: Data) throws
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
                if merged != local { try store.apply(documentID, merged) }
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
    /// that have not landed yet.
    private func orderedDirty() -> [String] {
        func rank(_ documentID: String) -> Int {
            switch CouchDocID.split(documentID)?.type {
            case CouchDocType.asset: return 0
            case CouchDocType.folder: return 1
            case CouchDocType.page: return 2
            default: return 3
            }
        }
        return state.dirty.sorted { (rank($0), $0) < (rank($1), $1) }
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

            try store.apply(row.id, merged)
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
        persist()
        return report
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
