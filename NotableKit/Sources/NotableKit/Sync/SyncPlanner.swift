import Foundation

/// The decision for one notebook. Pure data; the engine turns it into WebDAV calls.
/// Port of Notable's `NotebookSyncPlanner` (sync/NotebookSyncPlanner.kt) — behavior must
/// match exactly for both clients to converge.
public enum NotebookAction: Equatable, Sendable {
    /// Push local up; `ifMatch` guards the manifest PUT against a concurrent remote change.
    case upload(ifMatch: String?)
    case download
    /// Both sides moved. Look at it page by page: independent pages merge losslessly, and only a
    /// page changed on both sides is a real conflict for the user to settle.
    case reconcile
    case skip
    case skipUploadOnly
    case skipDownloadOnly
}

public struct RemoteManifestInfo: Equatable, Sendable {
    public var updatedAt: Int64?   // epoch ms from manifest.updatedAt, nil if unparsable
    public var etag: String?

    public init(updatedAt: Int64?, etag: String?) {
        self.updatedAt = updatedAt
        self.etag = etag
    }
}

public enum SyncPlanner {
    public static let toleranceMs: Int64 = 1000

    /// Decide for one remote-present notebook. The "remote absent" case is handled by the
    /// engine as a plain upload; "local absent" as a plain download.
    public static func decide(
        localUpdatedAt: Int64,
        syncedLocalUpdatedAt: Int64?,
        storedEtag: String?,
        remoteChanged: Bool,
        remote: RemoteManifestInfo?,
        uploadOnly: Bool = false,
        downloadOnly: Bool = false,
        toleranceMs: Int64 = SyncPlanner.toleranceMs
    ) -> NotebookAction {
        let raw = rawDecide(
            localUpdatedAt: localUpdatedAt,
            syncedLocalUpdatedAt: syncedLocalUpdatedAt,
            storedEtag: storedEtag,
            remoteChanged: remoteChanged,
            remote: remote,
            toleranceMs: toleranceMs)
        switch raw {
        case .download where uploadOnly: return .skipUploadOnly
        case .reconcile where uploadOnly: return .skipUploadOnly
        case .upload where downloadOnly: return .skipDownloadOnly
        case .reconcile where downloadOnly: return .download
        default: return raw
        }
    }

    private static func rawDecide(
        localUpdatedAt: Int64,
        syncedLocalUpdatedAt: Int64?,
        storedEtag: String?,
        remoteChanged: Bool,
        remote: RemoteManifestInfo?,
        toleranceMs: Int64
    ) -> NotebookAction {
        let movedLocally = syncedLocalUpdatedAt == nil
            || localUpdatedAt - syncedLocalUpdatedAt! > toleranceMs

        if !remoteChanged {
            // Remote == our last committed sync; decide purely on local movement.
            return movedLocally ? .upload(ifMatch: storedEtag) : .skip
        }

        // Remote moved. If local moved too, the two have genuinely diverged since the last common
        // point — whichever clock happens to be newer. Comparing timestamps here is what silently
        // destroys the losing side's work, so hand it to per-page reconciliation instead. (Notable
        // reaches this only on a sub-second tie; being stricter is safe, because reconciliation
        // still merges independent pages without asking and only ever *defers* a real clash.)
        if movedLocally { return .reconcile }

        guard let remote else { return .upload(ifMatch: storedEtag) }
        guard let remoteUpdatedAt = remote.updatedAt else { return .upload(ifMatch: remote.etag) }
        let diff = localUpdatedAt - remoteUpdatedAt
        if diff > toleranceMs { return .upload(ifMatch: remote.etag) }   // local newer
        if diff < -toleranceMs { return .download }                      // remote newer
        // Timestamps tie while the manifest moved: a tie is not proof the pages match, and
        // recording "in sync" here would make every future conditional GET 304 over stale pages.
        return .reconcile
    }
}
