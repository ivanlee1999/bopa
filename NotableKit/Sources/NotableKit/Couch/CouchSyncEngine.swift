import Foundation
import os

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
    /// Which database the state above describes (protocol §1.2), or nil for state written before
    /// this field existed — or by a device that has not yet met a server carrying the metadata.
    ///
    /// The checkpoint and revision cache are only meaningful against the database they were built
    /// from, and "same address, same name" does not establish that: a database dropped and
    /// recreated answers to both. Nil is treated as "not yet known", never as "any database will
    /// do".
    public var databaseGeneration: String?

    public init(
        lastSeq: String = "0", revs: [String: String] = [:], dirty: Set<String> = [],
        databaseGeneration: String? = nil
    ) {
        self.lastSeq = lastSeq
        self.revs = revs
        self.dirty = dirty
        self.databaseGeneration = databaseGeneration
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lastSeq = try c.decodeIfPresent(String.self, forKey: .lastSeq) ?? "0"
        revs = try c.decodeIfPresent([String: String].self, forKey: .revs) ?? [:]
        dirty = try c.decodeIfPresent(Set<String>.self, forKey: .dirty) ?? []
        databaseGeneration = try c.decodeIfPresent(String.self, forKey: .databaseGeneration)
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

    /// The `asset:` documents this body names — a page's pictures and background, a notebook's
    /// default background. The engine uses this to send an asset's bytes before the document that
    /// places them, and to fetch them when one arrives.
    var referencedAssetIDs: [String] {
        switch self {
        case .page(let page):
            return (page.images.compactMap(\.assetId) + [page.background])
                .filter { CouchAssetID.sha256Hex(ofAssetID: $0) != nil }
        case .notebook(let notebook):
            return [notebook.defaultBackground]
                .filter { CouchAssetID.sha256Hex(ofAssetID: $0) != nil }
        default:
            return []
        }
    }
}

extension CouchMerge {
    /// Merges two versions of the same document, including the delete-vs-edit case.
    ///
    /// Mismatched shapes (a page against a notebook) cannot arise from a well-formed database —
    /// the id prefix fixes the type — so they are reported rather than guessed at.
    ///
    /// `contentClock` is the newest content instant the *store* holds for this document beyond
    /// its envelope — for a notebook, the newest `updatedAt` among its local pages (see
    /// `CouchLocalStore.contentClock`). §6.4's delete-vs-edit question is "was there work after
    /// the deletion", and since an ink save deliberately no longer advances the notebook's
    /// envelope (the envelope is what renames and moves are decided by, and ink used to clobber
    /// them), the envelope alone can no longer answer it: ink drawn after a peer's purge would be
    /// destroyed by a deletion it outlived. The clock restores the signal without touching the
    /// envelope semantics.
    public static func merge(
        _ a: CouchDocBody, _ b: CouchDocBody, contentClock: String? = nil
    ) -> CouchDocBody? {
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
            // An edit made after the deletion resurrects the document; otherwise the delete
            // stands. Liveness is the envelope or the store's content clock, whichever is later —
            // ink no longer moves a notebook's envelope, so the envelope alone would let a
            // deletion destroy pages written after it.
            let liveness = contentClock.map { later(live.updatedAt, $0) } ?? live.updatedAt
            switch resolveDeletion(
                liveUpdatedAt: liveness,
                tombstoneDeletedAt: tomb.deletedAt.isEmpty ? nil : tomb.deletedAt) {
            case .resurrect:
                if case .notebook(var notebook) = live, millis(notebook.updatedAt) < millis(liveness) {
                    // The survival was justified by content the envelope does not show. Stamp the
                    // envelope to that instant — the resurrection edit — so the refusal travels: a
                    // peer that already applied the deletion compares this envelope against its
                    // tombstone and resurrects too, whatever build it runs.
                    notebook.updatedAt = liveness
                    return .notebook(notebook)
                }
                return live
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

    /// The newest content instant this device holds for the document *beyond* its envelope — for
    /// a notebook, the newest `updatedAt` among its local pages; nil for every other type and for
    /// a notebook with no pages here.
    ///
    /// Read only by §6.4's delete-vs-edit comparison (see `CouchMerge.merge(_:_:contentClock:)`).
    /// Deliberately not folded into `load`'s envelope: what `load` returns is what gets pushed,
    /// and inflating a pushed envelope with ink time would hand ink the power to overwrite
    /// renames again — the exact defect removing the ink-save bump fixed.
    func contentClock(_ documentID: String) -> String?
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

    /// Forces everything `apply` has written down to stable storage. The engine calls this before
    /// persisting sync state, so the checkpoint can never outrun the documents it describes: a
    /// state file that survives a power loss while an applied page's bytes did not would skip the
    /// row forever and echo-suppress every refetch of it.
    func synchronizeAppliedWrites()
}

public extension CouchLocalStore {
    /// A store that holds no images has none to fetch. Saves every test double from restating it.
    func missingAssetIDs() throws -> [String] { [] }

    /// A store with no content beyond envelopes — most test doubles — has no liveness to add.
    func contentClock(_ documentID: String) -> String? { nil }

    /// A store that cannot enumerate itself reports nothing, which makes §6.7's guard *more*
    /// cautious rather than less: with no library to compare against, any large batch of deletions
    /// looks like most of it. Erring towards asking is the right direction for a guard, and since
    /// it only holds back the deletions themselves, a false positive costs nothing else.
    func allDocumentIDs() throws -> [String] { [] }

    /// A store that keeps no deletion record of its own has nothing to forget — its tombstones are
    /// whatever `load` reports. Leaving the outbox entry to the engine is then the whole discard.
    func forgetDeletion(_ documentID: String) throws {}

    /// Durability is the file-backed store's problem; a store over memory (or a database that
    /// does its own journaling) has nothing to flush.
    func synchronizeAppliedWrites() {}

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
        /// Whether any failure above could plausibly succeed on a later attempt — offline, a 5xx,
        /// a 429. False when the only failures were ones the server will keep refusing, which is
        /// what tells the controller to stop rescheduling and leave the message standing.
        public var hasRetriableFailure = false
        /// The longest `Retry-After` any server sent during this flush, in seconds. The controller
        /// waits at least this long instead of its own backoff.
        public var retryAfter: TimeInterval?
        /// Set when the mass-deletion guard refused the run (protocol §6.7).
        public var blockedByDeletionGuard = false
        /// *Which* notebook and folder tombstones the guard held back — not the size of the whole
        /// queue, which is what the warning used to report, and not merely how many.
        ///
        /// The ids are the point: the user's answer to the guard is `approveHeldDeletions` or
        /// `discardHeldDeletions`, and both are set-scoped. A count would let the UI describe the
        /// batch but not act on exactly it, which is how an approval meant for one batch ends up
        /// applied to whatever the outbox holds by the time the tap arrives.
        public var heldDeletions: [String] = []
        /// A significant disagreement between this device's clock and the server's, or nil (§7).
        /// Advisory: it never fails or holds back a push, it only explains why a merge might
        /// resolve the wrong way.
        public var clockSkew: ClockSkew?
        /// What the database said about itself this pass (§1.2). Reported even when it is not
        /// enforced, which is what makes the staged rollout observable before it is enabled.
        public var databaseIdentity: DatabaseIdentity?

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
        /// Referenced images the server does not hold yet — a peer wrote the page before its
        /// bytes finished uploading. Retried on every pull, and the commonest reason a page shows
        /// a gap where a picture belongs.
        public var missingAssets: [String] = []
        /// Blobs whose bytes did not hash to the id that named them. Never stored, never
        /// re-uploaded: the id is a promise about the content, and writing these would break it.
        public var corruptAssets: [String] = []
        /// Why each asset above did not arrive, by asset id. Safe to show: no paths, no
        /// credentials.
        public var assetFailures: [String: String] = [:]
        /// Whether anything about the images is worth telling the user. The page and its ink are
        /// applied either way — this never means the sync failed.
        public var hasAssetProblems: Bool {
            !missingAssets.isEmpty || !corruptAssets.isEmpty || !assetFailures.isEmpty
        }
        public var lastSeq: String = "0"
        /// Feed batches dropped because an overlapping pull had already moved the checkpoint past
        /// them. Diagnostic only — never surfaced as a failure. A foreground catch-up racing the
        /// long poll is normal, and the batch is refetched from the winner's checkpoint.
        public var discardedStaleBatches = 0
        /// What the database said about itself this pass (§1.2). Reported even when it is not
        /// enforced, which is what makes the staged rollout observable before it is enabled.
        public var databaseIdentity: DatabaseIdentity?
        /// A significant disagreement between this device's clock and the server's, or nil (§7).
        public var clockSkew: ClockSkew?

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

    /// Whether a database-identity problem stops sync (§1.2 stage 3) or is merely reported.
    ///
    /// Off by default, and that is the whole point of the staged rollout: a client that *required*
    /// the metadata would refuse to sync with a peer of the previous release, which has never
    /// written it. Reading, creating and recording run unconditionally; only blocking waits.
    private let enforceDatabaseIdentity: Bool
    private let now: @Sendable () -> Date
    private let newGeneration: @Sendable () -> String
    /// How the conflict-retry pause is served. Injectable so tests can record the delays instead
    /// of living through them.
    private let sleep: @Sendable (TimeInterval) async -> Void

    /// What the last identity check saw, or nil before the first one. Cached so pull and flush do
    /// not each re-read the document on every pass.
    private var identity: DatabaseIdentity?

    /// Monotonic local-edit generation per document. `dirty` alone cannot distinguish an edit
    /// already represented by an in-flight PUT from another edit to the same document that lands
    /// while that request is away at the server: inserting the id into a Set a second time changes
    /// nothing, and the old request would remove it when it returned. The generation lets a request
    /// clear only the exact edit it read.
    ///
    /// This does not need to be persisted. `dirty` is persisted before the request starts, so a
    /// crash conservatively retries the document; generations only arbitrate two events within one
    /// running process.
    private var dirtyGenerations: [String: UInt64]

    /// Actor methods are re-entrant at network awaits. Chaining concurrent flush callers prevents
    /// two PUT loops from racing their revision updates while still allowing `markDirty` to enter
    /// the actor and advance a generation during a request. Each caller keeps its own turn: a
    /// `pushNow` that arrived during an older request must get a second pass over edits that request
    /// could not have carried.
    private var flushTail: Task<FlushReport, Never>?
    private var flushSequence: UInt64 = 0

    /// Set once the owner has replaced this engine — reconfiguring rebuilds the whole stack — and
    /// never cleared. The state file is keyed on endpoint and database only, so a password or
    /// device-name change hands the *same* path to the replacement engine; a flush still in
    /// flight here would then persist on completion and clobber the successor's checkpoint and
    /// rev map with this engine's stale copy.
    ///
    /// Nonisolated and lock-guarded rather than actor state, so the owner can mark it
    /// synchronously *before* the replacement exists — a mark that had to hop onto this actor
    /// would leave a window in which the dying flush persists between the reconfigure and the
    /// mark landing.
    private let invalidated = OSAllocatedUnfairLock(initialState: false)

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
        enforceDatabaseIdentity: Bool = false,
        now: @escaping @Sendable () -> Date = Date.init,
        newGeneration: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() },
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(for: .seconds(seconds))
        },
        onStateChange: (@Sendable (CouchSyncState) -> Void)? = nil
    ) {
        self.client = client
        self.store = store
        self.deviceID = deviceID
        self.state = state
        self.dirtyGenerations = Dictionary(
            uniqueKeysWithValues: state.dirty.map { ($0, UInt64(0)) })
        self.maxPushAttempts = maxPushAttempts
        self.enforceDatabaseIdentity = enforceDatabaseIdentity
        self.now = now
        self.newGeneration = newGeneration
        self.sleep = sleep
        self.onStateChange = onStateChange
    }

    public var currentState: CouchSyncState { state }
    public var pendingCount: Int { state.dirty.count }

    /// Queues documents for the next flush. Called from every local mutation; safe to call
    /// repeatedly and while offline, which is what makes the outbox the offline story.
    public func markDirty(_ documentIDs: [String]) {
        queueDirty(documentIDs)
        persist()
    }

    /// Adds a new mutation generation without persisting yet. Pull uses the same path when a merge
    /// discovers local content the server lacks; that push-back must not be cleared by an older PUT
    /// any more than a pen edit may be.
    private func queueDirty(_ documentIDs: [String]) {
        for id in documentIDs {
            state.dirty.insert(id)
            dirtyGenerations[id, default: 0] &+= 1
        }
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
        var discarded: [String] = []
        for documentID in documentIDs {
            guard (try? store.load(documentID))?.isDeleted ?? false else { continue }
            state.dirty.remove(documentID)
            approvedDeletions.remove(documentID)
            try? store.forgetDeletion(documentID)
            discarded.append(documentID)
        }

        // Dropping the tombstones is only half of "keep them on the server": it stops the deletion
        // being published, but on its own it does not bring anything back, and the UI promises the
        // notebooks return on the next sync. `_changes` only ever announces documents that have
        // *changed*, and declining to publish a deletion changes nothing on the server — so a
        // notebook nobody happens to be editing would never be mentioned on the feed again. The
        // user would be left with it gone here, present there, and no path between.
        //
        // So the checkpoint is rewound and the recorded revisions forgotten, which together make
        // the next pull replay the feed and land the documents as if they were new. Both are
        // needed: without the rewind the rows are never re-sent, and without forgetting the
        // revisions the replayed rows match what this device last recorded and are dropped as
        // its own echoes (§6.3).
        //
        // The *whole* rev map is forgotten, not merely the discarded ids'. The wipe that emptied
        // this device left the revs of the notebooks' pages intact — pushing a page whose file is
        // gone returns `.nothingToPush` without touching `revs` — so a replay that only forgot
        // the notebooks re-skipped every one of their pages as this device's own echo, and the
        // restored notebooks came back as empty shells. The checkpoint is already rewound to
        // zero, so keeping any of the map buys nothing: every row is coming back anyway, and the
        // full replay is declared idempotent.
        //
        // A full replay is exactly what losing the checkpoint costs, which this design already
        // treats as safe and idempotent. Discarding a mass deletion is rare, deliberate, and
        // already alarming enough to be worth one slow sync. Notable does the same (§6.7).
        if !discarded.isEmpty {
            state.lastSeq = "0"
            state.revs.removeAll()
        }
        persist()
    }

    // MARK: Push

    public func flush() async -> FlushReport {
        let preceding = flushTail
        flushSequence &+= 1
        let sequence = flushSequence
        let task = Task {
            if let preceding { _ = await preceding.value }
            return await self.performFlush()
        }
        flushTail = task
        let report = await task.value
        if flushSequence == sequence { flushTail = nil }
        return report
    }

    private func performFlush() async -> FlushReport {
        var report = FlushReport()

        // Checked before a single document goes out. Uploading a library into a database that is
        // not the one this device has been syncing with is the one mistake here that cannot be
        // undone from the other side.
        //
        // A check that could not complete is *not* evidence about identity — offline is the usual
        // reason — so it is swallowed and the flush proceeds exactly as it did before this existed.
        // The pushes will discover the same network for themselves, and report it per document the
        // way every other caller expects.
        report.databaseIdentity = try? await verifyDatabaseIdentity()
        if enforceDatabaseIdentity, let identity = report.databaseIdentity, !identity.isUsable {
            report.failures[CouchMetaDocID.database] =
                String(describing: CouchError.databaseIdentity(identity))
            // Terminal on purpose: no amount of retrying resolves whose library this is. The outbox
            // keeps everything, and the user's answer is what releases it.
            report.hasRetriableFailure = false
            report.stillDirty = state.dirty.sorted()
            return report
        }

        let plan = orderedDirty()
        var queue = plan.queue

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
        //
        // Folder tombstones are held alongside the notebooks'. The guard *trips* on notebook
        // tombstones — they are what measures "most of this library" — but the wipe that produced
        // them took the folders in the same stroke, and publishing those immediately would delete
        // the peer's folder tree behind the very question the guard is asking.
        if exceedsDeletionGuard(queue) {
            let held = queue.filter { isHeldTombstone($0) && !approved.contains($0) }
            // An approval that covered the whole batch leaves nothing held, so there is nothing to
            // report and nothing to ask about: the flush proceeds as if the guard had not fired.
            if !held.isEmpty {
                report.blockedByDeletionGuard = true
                report.heldDeletions = held
                report.stillDirty = held
                queue.removeAll { held.contains($0) }
            }
        }

        // Notebooks whose page or asset the server refused on the merits *this pass*. Push order
        // exists so a reader never sees a manifest naming documents that have not landed — and a
        // non-retriable failure used to fall straight through this loop into the manifest PUT,
        // publishing a page list that points at a page the server just refused.
        var suppressedNotebooks: Set<String> = []

        for (index, documentID) in queue.enumerated() {
            if suppressedNotebooks.contains(documentID) {
                report.failures[documentID] = "Not sent: the server refused part of this "
                    + "notebook, so its page list was held back."
                report.stillDirty.append(documentID)
                continue
            }
            do {
                switch try await push(documentID) {
                case .pushed: report.pushed.append(documentID)
                case .mergedThenPushed: report.merged.append(documentID)
                case .nothingToPush: break
                }
            } catch let error as CouchError {
                report.failures[documentID] = error.userMessage
                report.stillDirty.append(documentID)
                // Conflict exhaustion is retriable-with-backoff even though a single 409 is not:
                // running out of attempts means another device kept writing while this one
                // merged, and time is exactly what resolves that. Reporting it terminal left the
                // document queued with no timer, while the feed loop re-triggered the same doomed
                // burst on every pull.
                let isConflict: Bool
                if case .conflict = error { isConflict = true } else { isConflict = false }
                if error.isRetriable || isConflict {
                    report.hasRetriableFailure = true
                    if let asked = error.retryAfter {
                        report.retryAfter = max(report.retryAfter ?? 0, asked)
                    }
                } else if error != .unauthorized {
                    // Refused on the merits — a 413, most likely. The notebook this document
                    // belongs to must not publish a manifest naming it this pass.
                    switch CouchDocID.split(documentID)?.type {
                    case CouchDocType.page:
                        if case .page(let page)? = try? store.load(documentID),
                           let notebookId = page.notebookId {
                            suppressedNotebooks.insert(CouchDocID.notebook(notebookId))
                        }
                    case CouchDocType.asset:
                        suppressedNotebooks.formUnion(plan.assetOwners[documentID] ?? [])
                    default:
                        break
                    }
                }
                // Offline or a server fault applies to every remaining document too, and so do
                // rejected credentials — which no amount of retrying will fix. Stopping keeps one
                // dead connection, or one wrong password, from turning into a burst of doomed
                // requests, one per queued document, on every flush. A conflict is per-document
                // and does not stop the queue.
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
                // Not a `CouchError` at all — a store read that failed, most likely. Local faults
                // are usually transient (a file busy, a device briefly out of space), and the
                // document stays in the durable outbox either way.
                report.hasRetriableFailure = true
            }
        }
        // Merge-applies above may have rewritten documents; make them durable before the state
        // that records their revisions is.
        store.synchronizeAppliedWrites()
        persist()
        // A successful request can still leave the same id queued when the editor saved a newer
        // version during that request. Report the actual outbox after all actor re-entrancy, not
        // merely the failures observed by the original queue walk.
        report.stillDirty = state.dirty.sorted()
        // Read after the requests, so a flush that just spoke to the server reports what those
        // responses said rather than what the last sync happened to see.
        report.clockSkew = await client.clockSkew?.significantSkew
        return report
    }

    private enum PushOutcome { case pushed, mergedThenPushed, nothingToPush }

    private func push(_ documentID: String) async throws -> PushOutcome {
        var didMerge = false
        for attempt in 0..<maxPushAttempts {
            // A 409 means another writer got there first, and colliding again in the same
            // millisecond mostly reproduces the race: the retries used to run back-to-back and a
            // contended document burned its whole attempt budget in a blink. A short, growing
            // pause gives the other device's burst time to land.
            if attempt > 0 {
                await sleep(0.25 * Double(attempt))
                if Task.isCancelled { break }
            }
            let dirtyGeneration = dirtyGenerations[documentID, default: 0]
            guard let local = try store.load(documentID) else {
                // Nothing locally: the document was never created, or was cleaned up after being
                // queued. Dropping it from the outbox is right — there is nothing to send.
                state.dirty.remove(documentID)
                return .nothingToPush
            }

            do {
                let rev = try await putBody(documentID, local)
                state.revs[documentID] = rev
                clearDirty(documentID, ifUnchangedSince: dirtyGeneration)
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
                clearDirty(documentID, ifUnchangedSince: dirtyGeneration)
                return .pushed
            } catch CouchError.conflict {
                didMerge = true
                guard let remote = try await fetchBody(documentID) else {
                    // Vanished between the write and the re-read: retry as a create.
                    state.revs[documentID] = nil
                    continue
                }
                state.revs[documentID] = remote.rev
                guard let merged = CouchMerge.merge(
                    local, remote.body, contentClock: store.contentClock(documentID))
                else {
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
                    clearDirty(documentID, ifUnchangedSince: dirtyGeneration)
                    return .nothingToPush
                }
            }
        }
        throw CouchError.conflict(documentID: documentID)
    }

    /// Removes only the mutation whose body the completed request actually carried. If another
    /// save marked this id while the request was suspended, its higher generation remains queued
    /// for the next flush.
    private func clearDirty(_ documentID: String, ifUnchangedSince generation: UInt64) {
        guard dirtyGenerations[documentID, default: 0] == generation else { return }
        state.dirty.remove(documentID)
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
    private struct PushPlan {
        var queue: [String]
        /// asset id → the notebook documents whose contents reference it. What the flush loop
        /// consults when the server refuses an asset outright: the owning manifest must not be
        /// published over a refusal in the same pass.
        var assetOwners: [String: Set<String>]
    }

    /// Assets are not queued by the app: nothing "edits" one, and an image placed twice is the same
    /// document. They are derived here from the documents being sent — a page's pictures and
    /// background, a notebook's default background — and skipped once the server is known to hold
    /// them: immutability means a revision we have seen can never go stale.
    private func orderedDirty() -> PushPlan {
        func rank(_ documentID: String) -> Int {
            switch CouchDocID.split(documentID)?.type {
            case CouchDocType.asset: return 0
            case CouchDocType.folder: return 1
            case CouchDocType.page: return 2
            default: return 3
            }
        }
        var queue = state.dirty
        var owners: [String: Set<String>] = [:]
        for documentID in state.dirty {
            guard let type = CouchDocID.split(documentID)?.type,
                  type == CouchDocType.page || type == CouchDocType.notebook,
                  let body = try? store.load(documentID)
            else { continue }
            let owner: String?
            switch body {
            case .page(let page): owner = page.notebookId.map(CouchDocID.notebook)
            case .notebook: owner = documentID
            default: owner = nil
            }
            for assetID in body.referencedAssetIDs where state.revs[assetID] == nil {
                queue.insert(assetID)
                if let owner { owners[assetID, default: []].insert(owner) }
            }
        }
        return PushPlan(
            queue: queue.sorted { (rank($0), $0) < (rank($1), $1) },
            assetOwners: owners)
    }

    /// Protocol §6.7: a device whose local database was wiped looks exactly like a user who
    /// deleted everything. Ten-plus notebook tombstones that are also most of what this device
    /// knows is treated as the former until a human says otherwise.
    private func isNotebookTombstone(_ documentID: String) -> Bool {
        isTombstone(documentID, ofType: CouchDocType.notebook)
    }

    /// What a tripped guard holds back: the notebook tombstones it measured, and the folder
    /// tombstones the same wipe produced — a purge that takes a library takes its folder tree
    /// with it, and those deletions are part of the same question.
    private func isHeldTombstone(_ documentID: String) -> Bool {
        isTombstone(documentID, ofType: CouchDocType.notebook)
            || isTombstone(documentID, ofType: CouchDocType.folder)
    }

    private func isTombstone(_ documentID: String, ofType type: String) -> Bool {
        CouchDocID.split(documentID)?.type == type
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

    // MARK: Database identity (§1.2)

    /// What the last check made of the database this device is pointed at.
    public enum DatabaseIdentity: Equatable, Sendable {
        /// The database this state was built against, or one that has just adopted this device's
        /// first sight of it.
        case matched(generation: String)
        /// A database with the same address and name, but not the same database. Nothing is applied
        /// or uploaded until a human chooses what should happen to the two libraries.
        case generationChanged(stored: String, found: String)
        /// The server requires a newer client than this one.
        case clientTooOld(minimum: Int)
        /// A rebuild is in progress on another device.
        case locked(reason: String?)
        /// The server holds no metadata: a database created before this document existed, or a
        /// peer that has not shipped it yet. Explicitly *not* a mismatch — see below.
        case unknown

        public var isUsable: Bool {
            switch self {
            case .matched, .unknown: return true
            case .generationChanged, .clientTooOld, .locked: return false
            }
        }
    }

    /// The last identity observation, for a UI that wants to explain a refusal.
    public var databaseIdentity: DatabaseIdentity? { identity }

    /// Reads — and on an empty database, creates — the identity document, and reconciles it with
    /// what this device believes.
    ///
    /// Called before the feed is read and before the outbox is sent. Cheap after the first pass:
    /// the result is cached for the life of the engine, which is the life of one configuration.
    @discardableResult
    func verifyDatabaseIdentity() async throws -> DatabaseIdentity {
        if let identity { return identity }

        let stored = state.databaseGeneration
        let remote: CouchDBClient.Stored<CouchDatabaseMetadata>?
        do {
            remote = try await client.get(CouchMetaDocID.database, as: CouchDatabaseMetadata.self)
        } catch CouchError.notFound {
            remote = nil
        }

        guard let metadata = remote?.body else {
            // No metadata. On a database that already holds documents this means "created before
            // this document existed", and the only safe reading is to leave it alone: treating a
            // missing identity as permission to mint one — and therefore as permission to decide
            // this is a *new* database — is how a client would come to rebuild a library it should
            // have been syncing with.
            //
            // On an empty database there is nothing to be wrong about, so this device names it.
            let identity = try await claimEmptyDatabase() ?? .unknown
            self.identity = identity
            return identity
        }

        if metadata.minimumClientProtocol > couchProtocolVersion {
            identity = .clientTooOld(minimum: metadata.minimumClientProtocol)
            return identity!
        }
        if metadata.locked {
            identity = .locked(reason: metadata.lockReason)
            return identity!
        }

        switch stored {
        case nil:
            // First sight of a database that already has an identity. Adopt it — this device has
            // no prior claim to contradict it with.
            state.databaseGeneration = metadata.generation
            persist()
            identity = .matched(generation: metadata.generation)
        case let stored? where stored == metadata.generation:
            identity = .matched(generation: metadata.generation)
        case let stored?:
            // The name and address are the same; the database is not. The checkpoint describes
            // history this server never had, and the revision cache would suppress genuine changes
            // as though they were this device's own echoes.
            identity = .generationChanged(stored: stored, found: metadata.generation)
        }
        return identity!
    }

    /// Names an empty database, or returns nil when it turns out not to be empty.
    ///
    /// `PUT` with no `_rev` is the whole concurrency story: two devices reaching a fresh database
    /// together both try to create the document, and CouchDB gives exactly one of them the write.
    /// The loser re-reads and adopts the winner's generation rather than retrying, because the
    /// question "which of us names it" has already been answered.
    private func claimEmptyDatabase() async throws -> DatabaseIdentity? {
        guard try await isDatabaseEmpty() else {
            // Pre-existing library, no metadata: record nothing and block nothing.
            return nil
        }

        let metadata = CouchDatabaseMetadata(
            generation: state.databaseGeneration ?? newGeneration(),
            updatedAt: NotableDate.format(now()))
        do {
            _ = try await client.put(CouchMetaDocID.database, rev: nil, body: metadata)
            state.databaseGeneration = metadata.generation
            persist()
            return .matched(generation: metadata.generation)
        } catch CouchError.conflict {
            // Another device got there first in the moment between the read and the write.
            guard let winner = try await client.get(
                CouchMetaDocID.database, as: CouchDatabaseMetadata.self)?.body
            else { return nil }
            state.databaseGeneration = winner.generation
            persist()
            return .matched(generation: winner.generation)
        }
    }

    /// Whether the server holds any document this protocol cares about. Reserved ids do not count:
    /// a database holding nothing but protocol bookkeeping is still an empty library.
    ///
    /// A page of rows rather than one, because a single row could be a reserved id and say nothing
    /// about what follows it. One page is enough: the answer only has to be right about a database
    /// small enough to be plausibly new, and anything with a hundred documents is not.
    private func isDatabaseEmpty() async throws -> Bool {
        let probe = try await client.changes(
            since: "0", longpoll: false, limit: Self.catchUpBatchSize)
        return probe.rows.allSatisfy { CouchMetaDocID.isReserved($0.id) }
    }

    // MARK: Pull

    /// Applies everything the server has seen since the last checkpoint.
    ///
    /// `longpoll` holds the request open until a change arrives — the near-real-time path. A
    /// non-longpoll call returns immediately and is used for catch-up on foreground/reconnect.
    @discardableResult
    public func pull(longpoll: Bool = false, timeoutMs: Int = 55_000) async throws -> PullReport {
        var report = PullReport()
        report.databaseIdentity = try await verifyDatabaseIdentity()
        if enforceDatabaseIdentity, !report.databaseIdentity!.isUsable {
            // Nothing is applied and the checkpoint does not move. A device that cannot tell whose
            // history it is reading must not act on it.
            throw CouchError.databaseIdentity(report.databaseIdentity!)
        }

        // Read the feed in batches rather than in one response. A catch-up from `0` — a fresh
        // install, or any device whose checkpoint was lost — otherwise asks for the entire library
        // at once, every page with its base64 ink inlined, and holds the lot in memory before
        // applying any of it. Checkpointing each batch also means a crash halfway through resumes
        // where it stopped instead of replaying the whole thing.
        //
        // A longpoll is bounded the same way. It used to be sent with no limit at all, on the
        // reasoning that it is one wait for one notification — but the batch that follows a wait is
        // whatever changed *while* it waited, and after a device or proxy has been disconnected for
        // a day that is the same unbounded response the paging above exists to prevent, ink and
        // inline base64 and all.
        //
        // Once a long poll comes back full, the backlog is already on the server and there is
        // nothing left to wait for, so the loop drops to normal requests and drains at full speed
        // until a short batch says the server is caught up. Parking a fresh long poll instead would
        // wait for a *new* change before collecting the ones already queued.
        var longpollThisPass = longpoll
        repeat {
            let asked = state.lastSeq
            let changes = try await client.changes(
                since: asked, longpoll: longpollThisPass, timeoutMs: timeoutMs,
                limit: Self.catchUpBatchSize)
            let applied = try await apply(changes, fetchedFrom: asked, into: &report)
            // A batch another pull already superseded says nothing about how far behind the server
            // is — its row count describes a window that has since moved. Go back for the current
            // checkpoint's view instead of deciding anything from it.
            if !applied {
                // Except on a longpoll: the caller asked to wait for one notification, and the
                // overlapping pull that won has already delivered what this one was waiting for.
                if longpoll { break }
                continue
            }
            // The server is caught up when it returns a short batch; a full one may have more
            // behind it. `lastSeq` moved, so the next request asks for what follows.
            guard changes.rows.count >= Self.catchUpBatchSize else { break }
            longpollThisPass = false
            // A full batch that did not move the checkpoint would ask the same question forever.
            // No CouchDB does that, which is exactly why it is worth refusing to loop on it here
            // rather than finding out on a device.
            guard state.lastSeq != asked else { break }
        } while !Task.isCancelled

        await fetchMissingAssets(into: &report)
        store.synchronizeAppliedWrites()
        persist()
        report.clockSkew = await client.clockSkew?.significantSkew
        return report
    }

    /// Applies one batch of feed rows and advances the checkpoint past it. Returns whether the
    /// batch was applied at all; `false` means it was discarded as stale.
    ///
    /// `fetchedFrom` is the checkpoint this batch was asked for. This actor suspends at the feed
    /// request, and actors are reentrant, so a second `pull` — a foreground catch-up while the
    /// longpoll waits — can run to completion in that gap. Its checkpoint is then newer than the
    /// one this batch describes.
    ///
    /// The whole batch is dropped in that case, not merely its checkpoint. Keeping the rows was
    /// defensible while the argument was about content — merges are idempotent, so re-applying what
    /// the winner already applied lands on the identical document — but `state.revs` is not part of
    /// that argument. It is a cache of "the revision the next push must build on", and writing an
    /// older revision into it moves it *backwards*: the next push then quotes a stale `_rev` and
    /// takes a 409 it did not need, and the echo check stops recognising this device's own writes,
    /// which is a push ping-pong rather than a merge.
    ///
    /// Dropping the batch costs nothing. The next request starts from the winner's checkpoint, so
    /// anything this batch carried that the winner did not is returned again immediately.
    @discardableResult
    private func apply(
        _ changes: CouchDBClient.Changes, fetchedFrom: String, into report: inout PullReport
    ) async throws -> Bool {
        guard state.lastSeq == fetchedFrom else {
            report.discardedStaleBatches += 1
            // The winner's checkpoint, not this batch's: leaving the default "0" in the report
            // would read as a checkpoint reset rather than as a batch that never applied.
            report.lastSeq = state.lastSeq
            return false
        }

        for row in changes.rows {
            // Protocol bookkeeping, not a library item (§1.1). Recorded and stepped past: it is
            // neither merged nor conflict-copied, and a `sync-meta:` id this build does not know is
            // still recognisably ours rather than a document from a future schema.
            //
            // Ahead of the echo check, so it never reaches any of the report's lists. A caller
            // counting what a pull brought down is asking about the library, and bookkeeping
            // turning up as a "skipped echo" is noise in every report that mentions it.
            if CouchMetaDocID.isReserved(row.id) {
                state.revs[row.id] = row.rev
                continue
            }
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
            // A live row without a body cannot be applied and must not be checkpointed past. The
            // parser rejects such a response before it reaches here, so this is defence rather than
            // a path — but it throws instead of skipping, because skipping is exactly the silent
            // loss the strict parser exists to prevent: a pull that fails is retried, a change the
            // checkpoint stepped over is gone.
            let incoming: CouchDocBody
            if let json = row.json {
                guard let decoded = decode(documentID: row.id, json: json, deleted: row.deleted)
                else {
                    // Valid transport, unmergeable content — a future schema, most often. Preserved
                    // beside the local copy and checkpointed: unlike a missing body, nothing is lost
                    // by moving past it.
                    try store.applyConflictCopy(row.id, json: json)
                    report.conflictCopies.append(row.id)
                    state.revs[row.id] = row.rev
                    continue
                }
                incoming = decoded
            } else {
                guard row.deleted, let type = CouchDocID.split(row.id)?.type else {
                    throw CouchError.malformedResponse("_changes row \(row.id) carried no document")
                }
                // A tombstone CouchDB answered without a body, because `include_docs` found the
                // document already deleted. `deletedAt` is left empty for the reason `decode` gives:
                // stamping "now" would outrank every local edit and destroy work done after the
                // deletion.
                incoming = .deleted(CouchDeletedDoc(type: type, updatedBy: deviceID))
            }

            let local = try store.load(row.id)
            let merged: CouchDocBody
            if let local {
                guard let result = CouchMerge.merge(
                    local, incoming, contentClock: store.contentClock(row.id))
                else {
                    // Nothing to preserve when the body never arrived; the tombstone is the fact,
                    // and the revision still has to be recorded so the next push builds on it.
                    if let json = row.json {
                        try store.applyConflictCopy(row.id, json: json)
                        report.conflictCopies.append(row.id)
                    }
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
                queueDirty([row.id])
                report.pushBack.append(row.id)
            }
        }

        // The rows above landed as `.atomic` renames, which order nothing: APFS can commit the
        // tiny state write below while a page's data never reaches stable storage, and a state
        // that survives such a loss skips the row forever (`lastSeq` is past it) and suppresses
        // every refetch (`revs[id]` matches). The barrier makes the checkpoint honest.
        store.synchronizeAppliedWrites()
        // Unconditional now, unlike the guarded assignment this replaces: the batch was checked
        // against `fetchedFrom` before any row was touched, and this actor does not suspend between
        // there and here — `store` and the merge are synchronous — so no overlapping pull can have
        // moved the checkpoint in between.
        state.lastSeq = changes.lastSeq
        report.lastSeq = changes.lastSeq
        // Persisted per batch, not once at the end: an interrupted catch-up keeps what it applied.
        persist()
        return true
    }

    /// Downloads the blobs local pages reference and this device does not hold yet.
    ///
    /// Driven by the store's own list rather than by what this pull happened to apply, so a fetch
    /// that failed — offline halfway through, a peer that had not uploaded the bytes yet — is
    /// simply retried on the next pull instead of needing the page to change again.
    ///
    /// A failure here never fails the pull: the page and its ink are already applied, and an image
    /// that is still on its way is a picture that has not appeared yet, not lost work.
    /// Every branch below used to be a bare `continue`, so five different failures — an unreadable
    /// id, a transport error, a peer that has not uploaded the bytes, a digest mismatch, a store
    /// that would not write — all looked identical from outside: the pull reported success and the
    /// image simply was not there. The status said idle while the page had a hole in it.
    ///
    /// They are still non-fatal, and for the same reason: the page and its ink are already applied,
    /// and an image on its way is a picture that has not appeared yet, not lost work. What changes
    /// is that the pull now says so.
    private func fetchMissingAssets(into report: inout PullReport) async {
        guard let wanted = try? store.missingAssetIDs(), !wanted.isEmpty else { return }
        for assetID in wanted {
            guard let sha = CouchAssetID.sha256Hex(ofAssetID: assetID) else {
                // Not a content-addressed id at all — nothing to fetch and nothing to verify
                // against, so this one will never resolve by retrying.
                report.assetFailures[assetID] = "not a content-addressed asset id"
                continue
            }

            let blob: (data: Data, contentType: String)?
            do {
                blob = try await client.getAttachment(assetID)
            } catch {
                report.assetFailures[assetID] = Self.describe(error)
                continue
            }
            guard let blob else {
                // A 404: the peer that referenced this image has not uploaded the bytes yet. The
                // commonest case by far, and the one that resolves itself.
                report.missingAssets.append(assetID)
                continue
            }

            // The id is a promise about the bytes. Checking it costs one hash and turns a truncated
            // or mis-served download into a retry rather than into a corrupt image that would then
            // be re-uploaded under a name that does not describe it.
            guard CouchAssetID.sha256Hex(blob.data) == sha else {
                // Logged apart from the rest and never stored: writing it would put bytes under an
                // id that does not describe them, and the next push would upload them.
                report.corruptAssets.append(assetID)
                report.assetFailures[assetID] = "downloaded bytes did not match the asset digest"
                continue
            }

            let now = SyncClock.shared.stamp()
            let asset = CouchAsset(
                contentType: blob.contentType, createdAt: now, updatedAt: now,
                updatedBy: deviceID, data: blob.data)
            do {
                try store.apply(assetID, .asset(asset), basedOn: nil)
            } catch {
                // Out of space, a permission problem: local, usually transient, and retried on the
                // next pull because the store still lists the asset as missing.
                report.assetFailures[assetID] = Self.describe(error)
                continue
            }
            report.fetchedAssets.append(assetID)
        }
    }

    /// Short and stable, for a report that reaches a UI. `String(describing:)` on an arbitrary
    /// error renders type metadata that varies with the build.
    private static func describe(_ error: Error) -> String {
        if let couch = error as? CouchError { return String(describing: couch) }
        return (error as NSError).localizedDescription
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

    /// Retires this engine. Requests already in flight may still finish — a PUT that lands is a
    /// real write, and the documents it carried stay dirty in the successor's state, which
    /// re-sends and 409-merges them — but nothing this engine does from here on reaches the
    /// state file.
    public nonisolated func invalidate() {
        invalidated.withLock { $0 = true }
    }

    private func persist() {
        // An invalidated engine's state describes a configuration that no longer exists; writing
        // it would overwrite whatever the replacement engine has persisted since.
        guard !invalidated.withLock({ $0 }) else { return }
        onStateChange?(state)
    }
}
