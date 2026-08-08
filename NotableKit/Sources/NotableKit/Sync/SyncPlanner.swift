import Foundation

/// The decision for one notebook. Pure data; the engine turns it into WebDAV calls.
/// Port of Notable's `NotebookSyncPlanner` (sync/NotebookSyncPlanner.kt) — behavior must
/// match exactly for both clients to converge.
public enum NotebookAction: Equatable, Sendable {
    /// Push local up; `ifMatch` guards the manifest PUT against a concurrent remote change.
    case upload(ifMatch: String?)
    case download
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
        case .upload where downloadOnly: return .skipDownloadOnly
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
        if !remoteChanged {
            // Remote == our last committed sync; decide purely on local movement.
            let changedLocally = syncedLocalUpdatedAt == nil
                || localUpdatedAt - syncedLocalUpdatedAt! > toleranceMs
            return changedLocally ? .upload(ifMatch: storedEtag) : .skip
        }
        guard let remote else { return .upload(ifMatch: storedEtag) }
        guard let remoteUpdatedAt = remote.updatedAt else { return .upload(ifMatch: remote.etag) }
        let diff = localUpdatedAt - remoteUpdatedAt
        if diff > toleranceMs { return .upload(ifMatch: remote.etag) }   // local newer
        if diff < -toleranceMs { return .download }                      // remote newer
        return .skip                                                    // equal within tolerance
    }
}
