import Foundation

/// Conflict-free merge for CouchDB documents. Normative spec: `docs/couch-sync-protocol.md` §4–5.
///
/// Every function here is **commutative** (`merge(a,b) == merge(b,a)`) and **idempotent**
/// (`merge(merge(a,b), a) == merge(a,b)`), and none needs a common ancestor. That is what lets
/// two devices that were both offline reconcile without asking the user anything, and what makes
/// replaying the change feed from an old checkpoint harmless.
///
/// notable's `Merge.kt` is the twin of this file; both are driven by
/// `docs/couch-sync-vectors/vectors.json`, so a change here without the matching change there
/// fails both test suites.
public enum CouchMerge {

    // MARK: - Ordering primitives

    /// Epoch milliseconds, or `Int64.min` when unparseable.
    ///
    /// Timestamps must never be compared as strings: `"…:33.871Z" < "…:33Z"` lexicographically
    /// (because `.` sorts below `Z`) while being *later* in time, so a string compare silently
    /// picks the older document. An unparseable value loses every comparison rather than throwing —
    /// a malformed timestamp is a reason to prefer the other side, not to abandon the merge.
    public static func millis(_ timestamp: String) -> Int64 {
        guard let date = NotableDate.parse(timestamp) else { return Int64.min }
        return Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    /// The source string whose instant is earlier. Equal instants fall back to the smaller string
    /// so that two spellings of the same moment ("…:05Z" and "…:05.000Z") still pick the same one
    /// regardless of argument order.
    static func earlier(_ a: String, _ b: String) -> String {
        let (ma, mb) = (millis(a), millis(b))
        if ma != mb { return ma < mb ? a : b }
        return a <= b ? a : b
    }

    /// The source string whose instant is later, with the same spelling tiebreak as `earlier`.
    static func later(_ a: String, _ b: String) -> String {
        let (ma, mb) = (millis(a), millis(b))
        if ma != mb { return ma > mb ? a : b }
        return a >= b ? a : b
    }

    /// Total, commutative order over a document's scalar envelope. `true` means `a` wins.
    ///
    /// The `scalarKey` step only breaks ties between documents written in the same millisecond by
    /// the same device id — unreachable while the two devices use distinct ids, and present so the
    /// function is total rather than "usually total".
    static func wins(_ a: (updatedAt: String, updatedBy: String, scalarKey: String),
                     over b: (updatedAt: String, updatedBy: String, scalarKey: String)) -> Bool {
        let (ma, mb) = (millis(a.updatedAt), millis(b.updatedAt))
        if ma != mb { return ma > mb }
        if a.updatedBy != b.updatedBy { return a.updatedBy > b.updatedBy }
        return a.scalarKey >= b.scalarKey
    }

    /// Minimal key-sorted JSON of scalar fields, used only as the last-resort tiebreak.
    /// Kept free of floating-point fields so Swift and Kotlin render it identically.
    static func scalarKey(_ pairs: [(String, String?)]) -> String {
        pairs
            .sorted { $0.0 < $1.0 }
            .map { "\"\($0.0)\":\($0.1.map { "\"\($0)\"" } ?? "null")" }
            .joined(separator: ",")
    }

    // MARK: - Set primitives

    /// Union keyed by `id`; whenever two elements share an id, `preferred` decides.
    /// Order of the result is imposed by the caller's sort, never by input order.
    ///
    /// `preferred` is applied to collisions *within* a single input as well as across the two.
    /// Skipping the intra-array case would make the outcome depend on element order, which a
    /// document written by a buggy or older writer can easily vary — and a merge that is only
    /// commutative for well-formed input is not commutative.
    static func unionById<T>(
        _ a: [T], _ b: [T], id: (T) -> String, preferred: (T, T) -> T
    ) -> [T] {
        var merged: [String: T] = [:]
        for element in a + b {
            let key = id(element)
            merged[key] = merged[key].map { preferred($0, element) } ?? element
        }
        return Array(merged.values)
    }

    /// Union of tombstones keeping the **earliest** `deletedAt` per id: a deletion is a fact that
    /// cannot un-happen, so the earliest observation of it is the true one. Sorted by id so the
    /// encoded document is byte-stable across devices.
    public static func unionTombstones(
        _ a: [CouchTombstone], _ b: [CouchTombstone]
    ) -> [CouchTombstone] {
        unionById(a, b, id: \.id) { x, y in
            CouchTombstone(id: x.id, deletedAt: earlier(x.deletedAt, y.deletedAt))
        }
        .sorted { $0.id < $1.id }
    }

    // MARK: - Page

    public static func merge(_ a: CouchPage, _ b: CouchPage) -> CouchPage {
        let deletedStrokes = unionTombstones(a.deletedStrokes, b.deletedStrokes)
        let deletedImages = unionTombstones(a.deletedImages, b.deletedImages)
        let removedStrokeIDs = Set(deletedStrokes.map(\.id))
        let removedImageIDs = Set(deletedImages.map(\.id))

        // Erasure beats drawing: a stroke one side still holds and the other tombstoned is gone on
        // both. Safe because a redrawn stroke always gets a fresh id, so "remove wins" can never
        // suppress later work.
        let strokes = unionById(a.strokes, b.strokes, id: \.id) { x, y in
            preferredStroke(x, y)
        }
        .filter { !removedStrokeIDs.contains($0.id) }
        .sorted { orderKey($0.createdAt, $0.id) < orderKey($1.createdAt, $1.id) }

        let images = unionById(a.images, b.images, id: \.id) { x, y in
            preferredImage(x, y)
        }
        .filter { !removedImageIDs.contains($0.id) }
        .sorted { orderKey($0.createdAt, $0.id) < orderKey($1.createdAt, $1.id) }

        let winner = pageWins(a, over: b) ? a : b
        return CouchPage(
            type: CouchDocType.page,
            schema: Swift.max(a.schema, b.schema),
            notebookId: winner.notebookId,
            background: winner.background,
            backgroundType: winner.backgroundType,
            strokes: strokes,
            deletedStrokes: deletedStrokes,
            images: images,
            deletedImages: deletedImages,
            createdAt: earlier(a.createdAt, b.createdAt),
            updatedAt: later(a.updatedAt, b.updatedAt),
            updatedBy: winner.updatedBy)
    }

    /// Strokes are immutable once drawn, so two copies of one id are normally identical; this only
    /// has to be deterministic, not clever. It does have to be *total*, though — falling back to a
    /// comparison that can itself tie reintroduces argument-order dependence.
    private static func preferredStroke(_ x: CouchStroke, _ y: CouchStroke) -> CouchStroke {
        let (mx, my) = (millis(x.updatedAt), millis(y.updatedAt))
        if mx != my { return mx > my ? x : y }
        return strokeTiebreak(x) >= strokeTiebreak(y) ? x : y
    }

    private static func preferredImage(_ x: CouchImage, _ y: CouchImage) -> CouchImage {
        let (mx, my) = (millis(x.updatedAt), millis(y.updatedAt))
        if mx != my { return mx > my ? x : y }
        return imageTiebreak(x) >= imageTiebreak(y) ? x : y
    }

    /// Total order over every field of a stroke. Floats go in as their IEEE-754 bit patterns:
    /// `Float.bitPattern` in Swift and `Float.floatToIntBits` in Kotlin produce the same integer,
    /// whereas the two languages' default float *printing* does not agree.
    private static func strokeTiebreak(_ s: CouchStroke) -> String {
        [
            s.deviceId, s.createdAt, s.updatedAt, s.pen,
            String(s.color), String(s.maxPressure),
            String(s.size.bitPattern), String(s.top.bitPattern), String(s.bottom.bitPattern),
            String(s.left.bitPattern), String(s.right.bitPattern),
            s.pointsData,
        ].joined(separator: "|")
    }

    private static func imageTiebreak(_ i: CouchImage) -> String {
        [
            i.assetId ?? "", i.createdAt, i.updatedAt,
            String(i.x), String(i.y), String(i.width), String(i.height),
        ].joined(separator: "|")
    }

    /// Sort key for page content: creation instant, then id to break exact ties. Determines the
    /// z-order two independently drawn strokes settle into.
    private static func orderKey(_ createdAt: String, _ id: String) -> String {
        // Fixed-width so string comparison matches numeric comparison of the instant.
        String(format: "%020lld|%@", millis(createdAt), id)
    }

    private static func pageWins(_ a: CouchPage, over b: CouchPage) -> Bool {
        wins((a.updatedAt, a.updatedBy, pageScalarKey(a)),
             over: (b.updatedAt, b.updatedBy, pageScalarKey(b)))
    }

    private static func pageScalarKey(_ page: CouchPage) -> String {
        scalarKey([
            ("type", page.type), ("schema", String(page.schema)),
            ("createdAt", page.createdAt), ("updatedAt", page.updatedAt),
            ("updatedBy", page.updatedBy), ("notebookId", page.notebookId),
            ("background", page.background), ("backgroundType", page.backgroundType),
        ])
    }

    // MARK: - Notebook

    public static func merge(_ a: CouchNotebook, _ b: CouchNotebook) -> CouchNotebook {
        let winner = notebookWins(a, over: b) ? a : b
        let loser = notebookWins(a, over: b) ? b : a
        let deletedPageIds = unionTombstones(a.deletedPageIds, b.deletedPageIds)
        let removed = Set(deletedPageIds.map(\.id))

        // Ordered add-wins union: the winner's ordering is authoritative, pages only the loser
        // knows about are appended keeping the loser's relative order. Deterministic for a fixed
        // pair of inputs, so both devices land on the same list.
        var pageIds = winner.pageIds
        let known = Set(winner.pageIds)
        pageIds.append(contentsOf: loser.pageIds.filter { !known.contains($0) })
        pageIds = pageIds.filter { !removed.contains($0) }

        return CouchNotebook(
            type: CouchDocType.notebook,
            schema: Swift.max(a.schema, b.schema),
            title: winner.title,
            pageIds: pageIds,
            deletedPageIds: deletedPageIds,
            parentFolderId: winner.parentFolderId,
            defaultBackground: winner.defaultBackground,
            defaultBackgroundType: winner.defaultBackgroundType,
            createdAt: earlier(a.createdAt, b.createdAt),
            updatedAt: later(a.updatedAt, b.updatedAt),
            updatedBy: winner.updatedBy)
    }

    private static func notebookWins(_ a: CouchNotebook, over b: CouchNotebook) -> Bool {
        wins((a.updatedAt, a.updatedBy, notebookScalarKey(a)),
             over: (b.updatedAt, b.updatedBy, notebookScalarKey(b)))
    }

    private static func notebookScalarKey(_ notebook: CouchNotebook) -> String {
        scalarKey([
            ("type", notebook.type), ("schema", String(notebook.schema)),
            ("createdAt", notebook.createdAt), ("updatedAt", notebook.updatedAt),
            ("updatedBy", notebook.updatedBy), ("title", notebook.title),
            ("parentFolderId", notebook.parentFolderId),
            ("defaultBackground", notebook.defaultBackground),
            ("defaultBackgroundType", notebook.defaultBackgroundType),
        ])
    }

    // MARK: - Folder

    public static func merge(_ a: CouchFolder, _ b: CouchFolder) -> CouchFolder {
        let winner = folderWins(a, over: b) ? a : b
        return CouchFolder(
            type: CouchDocType.folder,
            schema: Swift.max(a.schema, b.schema),
            title: winner.title,
            parentFolderId: winner.parentFolderId,
            createdAt: earlier(a.createdAt, b.createdAt),
            updatedAt: later(a.updatedAt, b.updatedAt),
            updatedBy: winner.updatedBy)
    }

    private static func folderWins(_ a: CouchFolder, over b: CouchFolder) -> Bool {
        wins((a.updatedAt, a.updatedBy, folderScalarKey(a)),
             over: (b.updatedAt, b.updatedBy, folderScalarKey(b)))
    }

    private static func folderScalarKey(_ folder: CouchFolder) -> String {
        scalarKey([
            ("type", folder.type), ("schema", String(folder.schema)),
            ("createdAt", folder.createdAt), ("updatedAt", folder.updatedAt),
            ("updatedBy", folder.updatedBy), ("title", folder.title),
            ("parentFolderId", folder.parentFolderId),
        ])
    }

    // MARK: - Delete vs edit

    public enum DeletionOutcome: Equatable, Sendable {
        /// The live document was edited after the deletion; it wins and is rewritten.
        case resurrect
        /// The deletion stands; apply it locally.
        case applyDeletion
    }

    /// Protocol §6.4. An edit strictly newer than the deletion resurrects the document; anything
    /// else lets the deletion stand. Applies to notebooks and folders — pages live and die with
    /// their notebook's `pageIds`.
    public static func resolveDeletion(
        liveUpdatedAt: String, tombstoneDeletedAt: String?
    ) -> DeletionOutcome {
        guard let tombstoneDeletedAt else { return .resurrect }
        return millis(liveUpdatedAt) > millis(tombstoneDeletedAt) ? .resurrect : .applyDeletion
    }
}
