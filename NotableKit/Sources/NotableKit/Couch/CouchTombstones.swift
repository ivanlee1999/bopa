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

    /// Drops tombstones older than `maxAge` and no longer referenced by any live id.
    ///
    /// Safe only once every device has synced past them — a tombstone dropped while a peer still
    /// holds the stroke lets that stroke come back. Thirty days is far beyond any plausible gap
    /// between two devices that sync in seconds when both are open.
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
