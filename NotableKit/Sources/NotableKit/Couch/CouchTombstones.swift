import Foundation

/// Producing and pruning the tombstones the merge relies on.
///
/// Neither app records erasures today: bopa's exporter writes out whatever ink survived, and
/// notable deletes the row. Absence is enough when one device owns the file, but a merge cannot
/// tell "s2 was erased here" from "s2 has not arrived here yet" — without tombstones the other
/// device's copy simply comes back. So each save has to say what *stopped* existing, which is a
/// set difference against what the page held at the previous save.
public enum CouchTombstones {

    /// Tombstones to record for a save, given the ids present before and after.
    ///
    /// Only genuinely departed ids are recorded, and an id already tombstoned keeps its original
    /// `deletedAt` — the earliest observation of a deletion is the true one, and re-stamping it on
    /// every save would let a much later timestamp win a delete-vs-edit it should lose.
    public static func derive(
        previousIDs: Set<String>,
        currentIDs: Set<String>,
        existing: [CouchTombstone],
        deletedAt: String
    ) -> [CouchTombstone] {
        let alreadyRecorded = Set(existing.map(\.id))
        let departed = previousIDs.subtracting(currentIDs).subtracting(alreadyRecorded)
        let added = departed.map { CouchTombstone(id: $0, deletedAt: deletedAt) }
        return (existing + added).sorted { $0.id < $1.id }
    }

    /// Drops tombstones whose `deletedAt` is older than `maxAge` — protocol §6.6, "Pruning".
    ///
    /// Age is the whole test. A writer prunes only documents it is rewriting anyway, so the next
    /// push carries the shorter list; a peer that still holds the longer one unions the pruned
    /// tombstones straight back, which is harmless — they are pruned again on the next local
    /// write, and gone for good once every writer is past the horizon. What the horizon actually
    /// bounds is the peer that *stopped syncing*: one that last pulled before the erasure and
    /// returns after the horizon can resurrect the stroke. Thirty days is far beyond any
    /// plausible gap between two devices that sync in seconds when both are open — and only
    /// stroke and image tombstones are ever pruned; page tombstones, bookmarks, and removed
    /// outline entries carry structural identity the merge needs indefinitely.
    public static func prune(
        _ tombstones: [CouchTombstone],
        now: Date,
        maxAge: TimeInterval = 30 * 24 * 60 * 60
    ) -> [CouchTombstone] {
        let cutoff = Int64((now.timeIntervalSince1970 - maxAge) * 1000)
        return tombstones.filter { tombstone in
            let deletedAt = CouchMerge.millis(tombstone.deletedAt)
            // An unparseable timestamp is kept: it cannot be shown to be old enough to drop.
            return deletedAt == Int64.min || deletedAt >= cutoff
        }
    }

    /// Convenience for a page save: applies `derive` against the page's own previous strokes.
    public static func recordErasures(
        in page: inout CouchPage, previousStrokeIDs: Set<String>, deletedAt: String
    ) {
        page.deletedStrokes = derive(
            previousIDs: previousStrokeIDs,
            currentIDs: Set(page.strokes.map(\.id)),
            existing: page.deletedStrokes,
            deletedAt: deletedAt)
    }
}
