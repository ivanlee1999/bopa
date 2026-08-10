import XCTest
@testable import NotableKit

/// Decision-table tests mirroring Notable's NotebookSyncPlanner semantics.
final class SyncPlannerTests: XCTestCase {

    func testRemoteUnchangedLocalUnchangedSkips() {
        XCTAssertEqual(
            SyncPlanner.decide(
                localUpdatedAt: 10_000, syncedLocalUpdatedAt: 10_000,
                storedEtag: "\"e1\"", remoteChanged: false, remote: nil),
            .skip)
    }

    func testRemoteUnchangedLocalWithinToleranceSkips() {
        XCTAssertEqual(
            SyncPlanner.decide(
                localUpdatedAt: 10_900, syncedLocalUpdatedAt: 10_000,
                storedEtag: "\"e1\"", remoteChanged: false, remote: nil),
            .skip)
    }

    func testRemoteUnchangedLocalChangedUploadsWithStoredEtag() {
        XCTAssertEqual(
            SyncPlanner.decide(
                localUpdatedAt: 20_000, syncedLocalUpdatedAt: 10_000,
                storedEtag: "\"e1\"", remoteChanged: false, remote: nil),
            .upload(ifMatch: "\"e1\""))
    }

    func testNeverSyncedUploadsEvenIfRemoteUnchangedFlag() {
        XCTAssertEqual(
            SyncPlanner.decide(
                localUpdatedAt: 10_000, syncedLocalUpdatedAt: nil,
                storedEtag: nil, remoteChanged: false, remote: nil),
            .upload(ifMatch: nil))
    }

    /// Both sides moved since the last common sync. Picking the newer clock here is precisely
    /// what used to destroy the other device's work, so it must reconcile instead — even though
    /// local is comfortably newer.
    func testBothSidesMovedReconcilesInsteadOfPickingAWinner() {
        XCTAssertEqual(
            SyncPlanner.decide(
                localUpdatedAt: 30_000, syncedLocalUpdatedAt: 10_000,
                storedEtag: "\"e1\"", remoteChanged: true,
                remote: RemoteManifestInfo(updatedAt: 20_000, etag: "\"e2\"")),
            .reconcile)
    }

    /// Only the remote moved, so there is nothing to weigh it against — plain download.
    func testOnlyRemoteMovedStillDownloads() {
        XCTAssertEqual(
            SyncPlanner.decide(
                localUpdatedAt: 10_000, syncedLocalUpdatedAt: 10_000,
                storedEtag: "\"e1\"", remoteChanged: true,
                remote: RemoteManifestInfo(updatedAt: 30_000, etag: "\"e2\"")),
            .download)
    }

    func testRemoteChangedRemoteNewerDownloads() {
        XCTAssertEqual(
            SyncPlanner.decide(
                localUpdatedAt: 10_000, syncedLocalUpdatedAt: 10_000,
                storedEtag: "\"e1\"", remoteChanged: true,
                remote: RemoteManifestInfo(updatedAt: 30_000, etag: "\"e2\"")),
            .download)
    }

    /// A sub-second tie is not proof the pages match. Skipping would record "in sync" and make
    /// every future conditional GET 304 over pages that actually differ.
    func testTimestampTieReconciles() {
        XCTAssertEqual(
            SyncPlanner.decide(
                localUpdatedAt: 10_500, syncedLocalUpdatedAt: 10_500,
                storedEtag: "\"e1\"", remoteChanged: true,
                remote: RemoteManifestInfo(updatedAt: 10_000, etag: "\"e2\"")),
            .reconcile)
    }

    /// Never synced but present on both sides: we have no basis for calling either one the
    /// parent, so it goes to reconciliation rather than a coin flip.
    func testNeverSyncedWithRemotePresentReconciles() {
        XCTAssertEqual(
            SyncPlanner.decide(
                localUpdatedAt: 10_500, syncedLocalUpdatedAt: nil,
                storedEtag: nil, remoteChanged: true,
                remote: RemoteManifestInfo(updatedAt: 10_000, etag: "\"e2\"")),
            .reconcile)
    }

    /// An unparsable remote timestamp with no local movement: nothing to compare, so our copy
    /// is the only defensible answer.
    func testRemoteChangedNoTimestampUploads() {
        XCTAssertEqual(
            SyncPlanner.decide(
                localUpdatedAt: 10_000, syncedLocalUpdatedAt: 10_000,
                storedEtag: nil, remoteChanged: true,
                remote: RemoteManifestInfo(updatedAt: nil, etag: "\"e2\"")),
            .upload(ifMatch: "\"e2\""))
    }

    func testUploadOnlySuppressesDownload() {
        XCTAssertEqual(
            SyncPlanner.decide(
                localUpdatedAt: 10_000, syncedLocalUpdatedAt: 10_000,
                storedEtag: "\"e1\"", remoteChanged: true,
                remote: RemoteManifestInfo(updatedAt: 30_000, etag: "\"e2\""),
                uploadOnly: true),
            .skipUploadOnly)
    }

    func testDownloadOnlySuppressesUpload() {
        XCTAssertEqual(
            SyncPlanner.decide(
                localUpdatedAt: 30_000, syncedLocalUpdatedAt: 10_000,
                storedEtag: "\"e1\"", remoteChanged: false, remote: nil,
                downloadOnly: true),
            .skipDownloadOnly)
    }
}
