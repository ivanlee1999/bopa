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
        return byteCompare(a, b) <= 0 ? a : b
    }

    /// The source string whose instant is later, with the same spelling tiebreak as `earlier`.
    static func later(_ a: String, _ b: String) -> String {
        let (ma, mb) = (millis(a), millis(b))
        if ma != mb { return ma > mb ? a : b }
        return byteCompare(a, b) >= 0 ? a : b
    }

    /// Lexicographic comparison over UTF-8 bytes — the protocol's string order (§4), used
    /// wherever the merge breaks a tie on a string.
    ///
    /// Neither language's default is safe here. Swift's `<` (and `==`) reads strings by Unicode
    /// canonical equivalence, which files supplementary-plane characters differently from their
    /// bytes *and* equates spellings — composed and decomposed "é" — that differ on the wire, so
    /// a tiebreak can be skipped here that Kotlin takes. Kotlin's `compareTo` orders by UTF-16
    /// code unit, which files every supplementary-plane character (a device name with an emoji in
    /// it) below parts of the BMP that UTF-8 files it above. Two merges that order the same pair
    /// differently pick different winners for the same conflict, and the two apps quietly diverge
    /// on identical input. Bytes are the one reading both languages produce identically; pinned by
    /// the `tiebreak-*` vectors.
    static func byteCompare(_ a: String, _ b: String) -> Int {
        if a.utf8.lexicographicallyPrecedes(b.utf8) { return -1 }
        if b.utf8.lexicographicallyPrecedes(a.utf8) { return 1 }
        return 0
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
        // The gate must be byte equality too: Swift `!=` would call two spellings of one device
        // name equal and skip a tiebreak Kotlin takes.
        let d = byteCompare(a.updatedBy, b.updatedBy)
        if d != 0 { return d > 0 }
        return byteCompare(a.scalarKey, b.scalarKey) >= 0
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

    // MARK: - Bookmarks and outline

    /// Union keyed by `pageId`, keeping whichever side wrote last — protocol §3.2.1.
    ///
    /// Last-writer-wins rather than remove-wins, because a bookmark is re-addable under the same
    /// id; see `CouchBookmark`. Equal instants fall back to `removed` losing, so two devices that
    /// star and un-star in the same millisecond both end up keeping the star rather than
    /// disagreeing — and, more importantly, agreeing is what makes this commutative.
    public static func unionBookmarks(
        _ a: [CouchBookmark], _ b: [CouchBookmark]
    ) -> [CouchBookmark] {
        unionById(a, b, id: \.pageId) { x, y in
            let (mx, my) = (millis(x.updatedAt), millis(y.updatedAt))
            if mx != my { return mx > my ? x : y }
            if x.removed != y.removed { return x.removed ? y : x }
            return x.updatedAt >= y.updatedAt ? x : y
        }
        .sorted { $0.pageId < $1.pageId }
    }

    /// Merge two outlines — protocol §3.2.2.
    ///
    /// Order comes from `winner`, with entries only `loser` knows about appended in the loser's own
    /// relative order; content per entry is last-writer-wins. This is deliberately the same rule as
    /// `pageIds` in `merge(_:_:)` below rather than a fractional index or a position field: the
    /// outline is a list the user reorders wholesale, the ordered add-wins union is already proven
    /// and vector-tested here, and it needs no extra state on the entry to stay deterministic.
    ///
    /// Removed entries stay in the array. They are the tombstones, so dropping them here would let
    /// a peer that still holds the entry put it back on the next merge.
    static func mergeOutline(
        winner: [CouchOutlineEntry], loser: [CouchOutlineEntry]
    ) -> [CouchOutlineEntry] {
        var content: [String: CouchOutlineEntry] = [:]
        for entry in winner + loser {
            content[entry.id] = content[entry.id].map { held in
                let (mh, me) = (millis(held.updatedAt), millis(entry.updatedAt))
                if mh != me { return mh > me ? held : entry }
                // Same instant: `removed` loses, then the raw string breaks the tie, so both
                // devices pick the same entry whichever order they merged in.
                if held.removed != entry.removed { return held.removed ? entry : held }
                return held.updatedAt >= entry.updatedAt ? held : entry
            } ?? entry
        }

        var ordered = winner.map(\.id)
        let known = Set(ordered)
        ordered.append(contentsOf: loser.map(\.id).filter { !known.contains($0) })

        var seen = Set<String>()
        return ordered.compactMap { id in
            guard seen.insert(id).inserted else { return nil }
            return content[id]
        }
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
        let strokes = sortedByOrderKey(
            unionById(a.strokes, b.strokes, id: \.id) { x, y in
                preferredStroke(x, y)
            }
            .filter { !removedStrokeIDs.contains($0.id) },
            createdAt: \.createdAt, id: \.id)

        let images = sortedByOrderKey(
            unionById(a.images, b.images, id: \.id) { x, y in
                preferredImage(x, y)
            }
            .filter { !removedImageIDs.contains($0.id) },
            createdAt: \.createdAt, id: \.id)

        let winner = pageWins(a, over: b) ? a : b
        let loser = pageWins(a, over: b) ? b : a
        return CouchPage(
            type: CouchDocType.page,
            schema: Swift.max(a.schema, b.schema),
            notebookId: winner.notebookId,
            title: winner.title,
            background: winner.background,
            backgroundType: winner.backgroundType,
            // A declared sheet is never lost to a peer that has none: geometry describes how the
            // ink already on the page is laid out, so a writer that has not learned the field
            // cannot un-declare it by winning the scalar tiebreak. When both declare, the winner's
            // wins like any other scalar.
            pageWidth: winner.pageWidth ?? loser.pageWidth,
            pageHeight: winner.pageHeight ?? loser.pageHeight,
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
        return byteCompare(strokeTiebreak(x), strokeTiebreak(y)) >= 0 ? x : y
    }

    private static func preferredImage(_ x: CouchImage, _ y: CouchImage) -> CouchImage {
        let (mx, my) = (millis(x.updatedAt), millis(y.updatedAt))
        if mx != my { return mx > my ? x : y }
        return byteCompare(imageTiebreak(x), imageTiebreak(y)) >= 0 ? x : y
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

    /// Sorts page content by `orderKey` with the key built **once per element** instead of once per
    /// comparison. A comparator that calls `orderKey` parses two timestamps on every one of the
    /// O(n log n) comparisons, so a page carrying a couple of thousand strokes parsed tens of
    /// thousands of times per merge. Decorating, sorting on the decoration and undecorating is a
    /// pure performance change: the keys are the same strings the comparator built, and they are
    /// distinct because `unionById` has already made the ids unique, so no tie can expose whether
    /// the sort is stable.
    private static func sortedByOrderKey<T>(
        _ elements: [T], createdAt: (T) -> String, id: (T) -> String
    ) -> [T] {
        elements
            .map { (key: orderKey(createdAt($0), id($0)), element: $0) }
            .sorted { $0.key < $1.key }
            .map(\.element)
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
            ("title", page.title),
            ("background", page.background), ("backgroundType", page.backgroundType),
            ("pageWidth", page.pageWidth.map(String.init)),
            ("pageHeight", page.pageHeight.map(String.init)),
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
            // A bookmark on a deleted page is dropped. Safe to do here because a bookmark is keyed
            // by the very field being tested: the same pageId is filtered on every future merge,
            // so the drop cannot come undone.
            bookmarks: unionBookmarks(a.bookmarks, b.bookmarks)
                .filter { !removed.contains($0.pageId) },
            // The outline is deliberately *not* filtered the same way, though the dangling entries
            // it keeps are just as useless to tap. An entry is keyed by its own id while the test
            // would be on `pageId`, and those can disagree: if the surviving version of entry `e`
            // points at a deleted page, filtering erases `e` from the result entirely — and the
            // next merge against the peer that still holds `e` reads it as an entry this side has
            // never seen and adds it straight back. Not idempotent, and the randomised merge tests
            // catch it. Deleting a page instead marks its entries removed at the point of deletion,
            // which is an ordinary edit the merge already knows how to carry, and readers skip any
            // entry whose page is gone.
            outline: mergeOutline(winner: winner.outline, loser: loser.outline),
            defaultBackground: winner.defaultBackground,
            defaultBackgroundType: winner.defaultBackgroundType,
            defaultPageWidth: winner.defaultPageWidth ?? loser.defaultPageWidth,
            defaultPageHeight: winner.defaultPageHeight ?? loser.defaultPageHeight,
            // The winner's, not a union: unlike a tombstone, the Trash is a state that can be left.
            // Taking the earlier of the two would make a restore impossible to express — the peer
            // still holding the trashed copy would put it straight back on the next merge.
            deletedAt: winner.deletedAt,
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
            ("defaultPageWidth", notebook.defaultPageWidth.map(String.init)),
            ("defaultPageHeight", notebook.defaultPageHeight.map(String.init)),
            ("deletedAt", notebook.deletedAt),
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
            deletedAt: winner.deletedAt,
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
            ("deletedAt", folder.deletedAt),
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
