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
    /// When the deletion happened, or empty when this device cannot know — a tombstone written
    /// without a body (a plain HTTP `DELETE`, or a client that did not keep one) carries no
    /// instant. Empty means *unknown*, not the epoch and emphatically not "now": it loses every
    /// comparison in `resolveDeletion`, so an unknown deletion yields to a live document rather
    /// than destroying it (protocol §6.4).
    public var deletedAt: String
    public var updatedAt: String
    public var updatedBy: String

    public init(
        type: String, schema: Int = couchSchemaVersion,
        deletedAt: String = "", updatedAt: String? = nil, updatedBy: String = ""
    ) {
        self.type = type
        self.schema = schema
        self.deletedAt = deletedAt
        self.updatedAt = updatedAt ?? deletedAt
        self.updatedBy = updatedBy
    }

    /// Decoded leniently, because §3.1 requires a tombstone to retain only `type`, `deletedAt`,
    /// `updatedAt` and `updatedBy` — `schema` is not promised, and a document deleted through a
    /// plain `DELETE` has no body at all. Synthesized `Decodable` would reject both, and the
    /// caller's fallback was to invent `deletedAt = now`, which beats any edit the user has ever
    /// made and so deleted work that outlived the deletion.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? ""
        schema = try c.decodeIfPresent(Int.self, forKey: .schema) ?? couchSchemaVersion
        deletedAt = try c.decodeIfPresent(String.self, forKey: .deletedAt) ?? ""
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt) ?? deletedAt
        updatedBy = try c.decodeIfPresent(String.self, forKey: .updatedBy) ?? ""
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
                // A deletion cannot un-happen, so the earliest observation is the true one — but an
                // unknown instant is not an early one. Taking it would erase a real timestamp the
                // peer recorded, so a known value always survives beside an empty one.
                deletedAt: x.deletedAt.isEmpty ? y.deletedAt
                    : y.deletedAt.isEmpty ? x.deletedAt
                    : earlier(x.deletedAt, y.deletedAt),
                updatedAt: later(x.updatedAt, y.updatedAt),
                updatedBy: wins((x.updatedAt, x.updatedBy, ""), over: (y.updatedAt, y.updatedBy, ""))
                    ? x.updatedBy : y.updatedBy))

        case (.deleted(let tomb), let live), (let live, .deleted(let tomb)):
            // An edit made after the deletion resurrects the document; otherwise the delete stands.
            switch resolveDeletion(
                liveUpdatedAt: live.updatedAt,
                tombstoneDeletedAt: tomb.deletedAt.isEmpty ? nil : tomb.deletedAt) {
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

    /// Every document this device holds, including the tombstones it has yet to push. Used as the
    /// denominator for §6.7's mass-deletion guard: "most of what this device knows" is a question
    /// about the library, and only the store can answer it.
    func allDocumentIDs() throws -> [String]

    /// Forgets a locally recorded deletion, so this device stops producing a tombstone for it.
    ///
    /// The one caller is §6.7's "keep them on the server": the deletion is abandoned here rather
    /// than published, and the peer's copy returns on the next pull. It is not an "undelete" — the
    /// notebook's files are already gone from this device — which is exactly why the resurrection
    /// has to come from the server.
    func forgetDeletion(_ documentID: String) throws

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

    /// A store that cannot enumerate itself reports nothing, which makes §6.7's guard *more*
    /// cautious rather than less: with no library to compare against, any large batch of deletions
    /// looks like most of it. Erring towards asking is the right direction for a guard, and since
    /// it only holds back the deletions themselves, a false positive costs nothing else.
    func allDocumentIDs() throws -> [String] { [] }

    /// A store that keeps no deletion record of its own has nothing to forget — its tombstones are
    /// whatever `load` reports. Leaving the outbox entry to the engine is then the whole discard.
    func forgetDeletion(_ documentID: String) throws {}

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
        /// Set when the mass-deletion guard refused the run (protocol §6.7).
        public var blockedByDeletionGuard = false
        /// *Which* notebook tombstones the guard held back — not the size of the whole queue,
        /// which is what the warning used to report, and not merely how many.
        ///
        /// The ids are the point: the user's answer to the guard is `approveHeldDeletions` or
        /// `discardHeldDeletions`, and both are set-scoped. A count would let the UI describe the
        /// batch but not act on exactly it, which is how an approval meant for one batch ends up
        /// applied to whatever the outbox holds by the time the tap arrives.
        public var heldDeletions: [String] = []

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

    /// Rows per catch-up request. Small enough that a library of any size arrives in pieces this
    /// device can hold and apply, large enough that a routine catch-up is still one round trip.
    static let catchUpBatchSize = 100
    private var state: CouchSyncState
    private let onStateChange: (@Sendable (CouchSyncState) -> Void)?

    /// Deletions the user has explicitly approved, waiting for the flush that will act on them.
    ///
    /// Deliberately not part of `CouchSyncState`, so it is neither persisted nor a setting: it is
    /// one answer to one question. Set-scoped because the question was about a named batch — a
    /// device that was wiped and then genuinely had ten notebooks deleted must ask again — and
    /// one-shot because a flag that survived its flush would be a "stop guarding" switch that a
    /// single tap disarmed forever.
    private var approvedDeletions: Set<String> = []

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

    // MARK: Resolving a held deletion

    /// "Yes, delete these on the server too" — protocol §6.7.
    ///
    /// The next flush sends exactly these ids past the guard, and nothing else: the guard stays
    /// armed for every id not named here, including ones that reach the outbox a moment later. It
    /// is a decision about a batch someone looked at, not a setting.
    public func approveHeldDeletions(_ documentIDs: [String]) {
        approvedDeletions.formUnion(documentIDs)
    }

    /// "No, keep these on the server" — protocol §6.7.
    ///
    /// The tombstone goes away entirely: out of the outbox, and out of the store's record of
    /// local deletions, so it is not reproduced on the next flush. **The document is still on the
    /// server**, so the peer's copy comes back to this device on the next pull. That is the undo,
    /// and it is the whole point of offering this rather than a plain "dismiss": a device whose
    /// database was wiped recovers its library by declining to publish the wipe.
    ///
    /// Ids that are not tombstones here are ignored rather than acted on. The list comes back from
    /// a report through a UI and an actor hop, and "forget the local deletion of X" applied to a
    /// live document would silently drop a real edit out of the outbox.
    public func discardHeldDeletions(_ documentIDs: [String]) {
        for documentID in documentIDs {
            guard (try? store.load(documentID))?.isDeleted ?? false else { continue }
            state.dirty.remove(documentID)
            approvedDeletions.remove(documentID)
            try? store.forgetDeletion(documentID)
        }
        persist()
    }

    // MARK: Push

    public func flush() async -> FlushReport {
        var report = FlushReport()
        var queue = orderedDirty()

        // The approval is consumed here, before anything is sent, whether or not the guard turns
        // out to trip. It is an answer to the question this flush is about to ask, and a flush that
        // dies offline halfway through has not delivered the deletions — so the next one asks
        // again. Asking twice about a destructive irreversible act is the safe direction to err in;
        // carrying the answer forward until it happens to be used is not.
        let approved = approvedDeletions
        approvedDeletions = []

        // Only the deletions are held back. Blocking the whole queue meant a guard meant to
        // question a suspicious *deletion* also stopped ordinary edits syncing — a permanent stall
        // rather than a prompt. Drawings keep flowing; the tombstones wait for an answer.
        if exceedsDeletionGuard(queue) {
            let held = queue.filter { isNotebookTombstone($0) && !approved.contains($0) }
            // An approval that covered the whole batch leaves nothing held, so there is nothing to
            // report and nothing to ask about: the flush proceeds as if the guard had not fired.
            if !held.isEmpty {
                report.blockedByDeletionGuard = true
                report.heldDeletions = held
                report.stillDirty = held
                queue.removeAll { held.contains($0) }
            }
        }

        for (index, documentID) in queue.enumerated() {
            do {
                switch try await push(documentID) {
                case .pushed: report.pushed.append(documentID)
                case .mergedThenPushed: report.merged.append(documentID)
                case .nothingToPush: break
                }
            } catch let error as CouchError {
                report.failures[documentID] = String(describing: error)
                report.stillDirty.append(documentID)
                // Offline or a server fault applies to every remaining document too, and so do
                // rejected credentials — which no amount of retrying will fix. Stopping keeps one
                // dead connection, or one wrong password, from turning into a burst of doomed
                // requests, one per queued document, on every flush.
                if error.isRetriable || error == .unauthorized {
                    // Everything after this point was never tried, and is still in the outbox.
                    // Reporting only the one document that failed lost no work — the queue is
                    // durable either way — but `stillDirty` is what the controller counts for the
                    // pending badge and what the peer's reconnect logic reads as "there is more to
                    // send", so leaving the remainder out understated both. Assets are filtered
                    // back out because nothing queues one: they are derived from the pages being
                    // sent, so counting them would report work the outbox does not hold.
                    report.stillDirty += queue[(index + 1)...].filter { state.dirty.contains($0) }
                    break
                }
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
                // The server already holds this, so there is nothing left to send. Returning here
                // is not just an optimization: when the merge resolves to the peer's tombstone,
                // CouchDB answers 409 to a PUT that re-deletes an already deleted document *even
                // with its current revision* — so writing it back would spin until the retries ran
                // out and leave the id stuck in the outbox forever.
                //
                // The deleted case needs its own test rather than plain equality: two devices that
                // deleted the same document independently merge to a tombstone whose `updatedAt`
                // and `updatedBy` differ from the stored one — equal deletions, unequal documents.
                // There is nothing to send either way; the deletion is already recorded.
                if merged == remote.body || (merged.isDeleted && remote.body.isDeleted) {
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

    /// Protocol §6.7: a device whose local database was wiped looks exactly like a user who
    /// deleted everything. Ten-plus notebook tombstones that are also most of what this device
    /// knows is treated as the former until a human says otherwise.
    private func isNotebookTombstone(_ documentID: String) -> Bool {
        CouchDocID.split(documentID)?.type == CouchDocType.notebook
            && ((try? store.load(documentID))?.isDeleted ?? false)
    }

    private func exceedsDeletionGuard(_ queue: [String]) -> Bool {
        let tombstones = queue.filter { isNotebookTombstone($0) }
        guard tombstones.count >= 10 else { return false }
        // What this device actually holds, not every id it has ever synced. `revs` is never pruned,
        // so a library that has seen a hundred notebooks come and go kept all hundred in the
        // denominator — and the guard quietly stopped being able to trip at all, which is the one
        // thing it must not do. Deleted notebooks are still counted as known: they are exactly what
        // is being asked about.
        let known = Set(((try? store.allDocumentIDs()) ?? []) + tombstones).filter {
            CouchDocID.split($0)?.type == CouchDocType.notebook
        }
        return tombstones.count * 2 > known.count
    }

    // MARK: Pull

    /// Applies everything the server has seen since the last checkpoint.
    ///
    /// `longpoll` holds the request open until a change arrives — the near-real-time path. A
    /// non-longpoll call returns immediately and is used for catch-up on foreground/reconnect.
    @discardableResult
    public func pull(longpoll: Bool = false, timeoutMs: Int = 55_000) async throws -> PullReport {
        var report = PullReport()

        // Read the feed in batches rather than in one response. A catch-up from `0` — a fresh
        // install, or any device whose checkpoint was lost — otherwise asks for the entire library
        // at once, every page with its base64 ink inlined, and holds the lot in memory before
        // applying any of it. Checkpointing each batch also means a crash halfway through resumes
        // where it stopped instead of replaying the whole thing.
        //
        // A longpoll is never paged: it is one wait for one notification, and the batch that
        // follows is whatever changed while it waited.
        repeat {
            let asked = state.lastSeq
            let changes = try await client.changes(
                since: asked, longpoll: longpoll, timeoutMs: timeoutMs,
                limit: longpoll ? nil : Self.catchUpBatchSize)
            try await apply(changes, fetchedFrom: asked, into: &report)
            // The server is caught up when it returns a short batch; a full one may have more
            // behind it. `lastSeq` moved, so the next request asks for what follows.
            guard !longpoll, changes.rows.count >= Self.catchUpBatchSize else { break }
            // A full batch that did not move the checkpoint would ask the same question forever.
            // No CouchDB does that, which is exactly why it is worth refusing to loop on it here
            // rather than finding out on a device.
            guard state.lastSeq != asked else { break }
        } while !Task.isCancelled

        report.fetchedAssets = await fetchMissingAssets()
        persist()
        return report
    }

    /// Applies one batch of feed rows and advances the checkpoint past it.
    ///
    /// `fetchedFrom` is the checkpoint this batch was asked for. This actor suspends at the feed
    /// request, and actors are reentrant, so a second `pull` — a foreground catch-up while the
    /// longpoll waits — can run to completion in that gap. Its checkpoint is then newer than the
    /// one this batch describes, and assigning ours over it would send the feed backwards and
    /// replay everything in between on every pull from then on.
    private func apply(
        _ changes: CouchDBClient.Changes, fetchedFrom: String, into report: inout PullReport
    ) async throws {
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

        // The rows themselves are applied either way: applying is idempotent, so a batch another
        // pull already covered merges to the identical document or is skipped as our own echo.
        // Only the checkpoint has to refuse to move backwards.
        if state.lastSeq == fetchedFrom { state.lastSeq = changes.lastSeq }
        report.lastSeq = changes.lastSeq
        // Persisted per batch, not once at the end: an interrupted catch-up keeps what it applied.
        persist()
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
            //
            // `deletedAt` is left *empty* rather than stamped with the current time. Stamping "now"
            // reads as a deletion newer than any edit this device has ever made, so §6.4's
            // resurrect branch became unreachable from here and a stripped tombstone destroyed work
            // done after the deletion. Empty means unknown and loses the comparison instead.
            let decoded = try? decoder.decode(CouchDeletedDoc.self, from: json)
            return .deleted(decoded ?? CouchDeletedDoc(type: type, updatedBy: deviceID))
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
