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

    func testRemoteChangedLocalNewerUploadsWithFreshEtag() {
        XCTAssertEqual(
            SyncPlanner.decide(
                localUpdatedAt: 30_000, syncedLocalUpdatedAt: 10_000,
                storedEtag: "\"e1\"", remoteChanged: true,
                remote: RemoteManifestInfo(updatedAt: 20_000, etag: "\"e2\"")),
            .upload(ifMatch: "\"e2\""))
    }

    func testRemoteChangedRemoteNewerDownloads() {
        XCTAssertEqual(
            SyncPlanner.decide(
                localUpdatedAt: 10_000, syncedLocalUpdatedAt: 10_000,
                storedEtag: "\"e1\"", remoteChanged: true,
                remote: RemoteManifestInfo(updatedAt: 30_000, etag: "\"e2\"")),
            .download)
    }

    func testRemoteChangedWithinToleranceSkips() {
        XCTAssertEqual(
            SyncPlanner.decide(
                localUpdatedAt: 10_500, syncedLocalUpdatedAt: nil,
                storedEtag: nil, remoteChanged: true,
                remote: RemoteManifestInfo(updatedAt: 10_000, etag: "\"e2\"")),
            .skip)
    }

    func testRemoteChangedNoTimestampUploads() {
        XCTAssertEqual(
            SyncPlanner.decide(
                localUpdatedAt: 10_000, syncedLocalUpdatedAt: nil,
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
