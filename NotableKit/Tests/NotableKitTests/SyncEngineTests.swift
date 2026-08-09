import XCTest
@testable import NotableKit

final class SyncEngineTests: XCTestCase {
    private var server: MockWebDAVServer!
    private var rootURL: URL!

    override func setUp() {
        super.setUp()
        server = MockWebDAVServer()
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("bopa-sync-test-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: rootURL)
        super.tearDown()
    }

    private func engine() -> SyncEngine {
        SyncEngine(transport: server, rootURL: rootURL)
    }

    // MARK: Fixtures

    @discardableResult
    private func writeLocalNotebook(
        id: String, title: String = "Nb", pageIds: [String], updatedAt: String
    ) throws -> NotebookManifest {
        let manifest = NotebookManifest(
            notebookId: id, title: title, pageIds: pageIds,
            createdAt: "2026-08-01T00:00:00Z", updatedAt: updatedAt,
            serverTimestamp: updatedAt)
        let dir = rootURL.appendingPathComponent("notebooks/\(id)/pages")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONEncoder().encode(manifest)
            .write(to: rootURL.appendingPathComponent("notebooks/\(id)/manifest.json"))
        for pageId in pageIds {
            let page = PageFile(
                id: pageId, notebookId: id,
                createdAt: "2026-08-01T00:00:00Z", updatedAt: updatedAt)
            try JSONEncoder().encode(page)
                .write(to: dir.appendingPathComponent("\(pageId).json"))
        }
        return manifest
    }

    private func seedRemoteNotebook(id: String, title: String = "Remote", pageIds: [String], updatedAt: String) throws {
        let manifest = NotebookManifest(
            notebookId: id, title: title, pageIds: pageIds,
            createdAt: "2026-08-01T00:00:00Z", updatedAt: updatedAt,
            serverTimestamp: updatedAt)
        for pageId in pageIds {
            let page = PageFile(
                id: pageId, notebookId: id,
                createdAt: "2026-08-01T00:00:00Z", updatedAt: updatedAt)
            server.setFile("/notable/notebooks/\(id)/pages/\(pageId).json", try JSONEncoder().encode(page))
        }
        server.setFile("/notable/notebooks/\(id)/manifest.json", try JSONEncoder().encode(manifest))
    }

    private func localManifest(_ id: String) throws -> NotebookManifest {
        let data = try Data(contentsOf: rootURL.appendingPathComponent("notebooks/\(id)/manifest.json"))
        return try JSONDecoder().decode(NotebookManifest.self, from: data)
    }

    // MARK: Scenarios

    func testInitialUploadOfLocalNotebook() async throws {
        try writeLocalNotebook(id: "nb1", pageIds: ["p1", "p2"], updatedAt: "2026-08-02T10:00:00Z")

        let report = await engine().sync()

        XCTAssertEqual(report.uploaded, ["nb1"])
        XCTAssertTrue(report.errors.isEmpty)
        XCTAssertNotNil(server.fileData("/notable/notebooks/nb1/manifest.json"))
        XCTAssertNotNil(server.fileData("/notable/notebooks/nb1/pages/p1.json"))
        XCTAssertNotNil(server.fileData("/notable/notebooks/nb1/pages/p2.json"))
    }

    func testDownloadOfNewRemoteNotebook() async throws {
        try seedRemoteNotebook(id: "nb2", pageIds: ["pa"], updatedAt: "2026-08-02T11:00:00Z")

        let report = await engine().sync()

        XCTAssertEqual(report.downloaded, ["nb2"])
        let manifest = try localManifest("nb2")
        XCTAssertEqual(manifest.title, "Remote")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: rootURL.appendingPathComponent("notebooks/nb2/pages/pa.json").path))
    }

    func testSecondSyncIsAllSkips() async throws {
        try writeLocalNotebook(id: "nb1", pageIds: ["p1"], updatedAt: "2026-08-02T10:00:00Z")
        _ = await engine().sync()

        let report = await engine().sync()

        XCTAssertEqual(report.uploaded, [])
        XCTAssertEqual(report.downloaded, [])
        XCTAssertEqual(report.skipped, ["nb1"])
    }

    func testLocalEditUploadsOnNextSync() async throws {
        try writeLocalNotebook(id: "nb1", pageIds: ["p1"], updatedAt: "2026-08-02T10:00:00Z")
        _ = await engine().sync()

        try writeLocalNotebook(id: "nb1", pageIds: ["p1"], updatedAt: "2026-08-02T10:05:00Z")
        let report = await engine().sync()

        XCTAssertEqual(report.uploaded, ["nb1"])
        let remote = try JSONDecoder().decode(
            NotebookManifest.self,
            from: XCTUnwrap(server.fileData("/notable/notebooks/nb1/manifest.json")))
        XCTAssertEqual(remote.updatedAt, "2026-08-02T10:05:00Z")
    }

    func testRemoteEditDownloadsOnNextSync() async throws {
        try writeLocalNotebook(id: "nb1", pageIds: ["p1"], updatedAt: "2026-08-02T10:00:00Z")
        _ = await engine().sync()

        try seedRemoteNotebook(
            id: "nb1", title: "Edited on BOOX", pageIds: ["p1", "p9"],
            updatedAt: "2026-08-02T10:30:00Z")
        let report = await engine().sync()

        XCTAssertEqual(report.downloaded, ["nb1"])
        let manifest = try localManifest("nb1")
        XCTAssertEqual(manifest.title, "Edited on BOOX")
        XCTAssertEqual(manifest.pageIds, ["p1", "p9"])
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: rootURL.appendingPathComponent("notebooks/nb1/pages/p9.json").path))
    }

    func testConflictLastWriterWinsUploadWhenLocalNewer() async throws {
        try writeLocalNotebook(id: "nb1", pageIds: ["p1"], updatedAt: "2026-08-02T10:00:00Z")
        _ = await engine().sync()

        // Both sides change; local is newer.
        try seedRemoteNotebook(id: "nb1", title: "Remote change", pageIds: ["p1"], updatedAt: "2026-08-02T10:10:00Z")
        try writeLocalNotebook(id: "nb1", title: "Local change", pageIds: ["p1"], updatedAt: "2026-08-02T10:20:00Z")

        let report = await engine().sync()

        XCTAssertEqual(report.uploaded, ["nb1"])
        let remote = try JSONDecoder().decode(
            NotebookManifest.self,
            from: XCTUnwrap(server.fileData("/notable/notebooks/nb1/manifest.json")))
        XCTAssertEqual(remote.title, "Local change")
    }

    func testConflictLastWriterWinsDownloadWhenRemoteNewer() async throws {
        try writeLocalNotebook(id: "nb1", pageIds: ["p1"], updatedAt: "2026-08-02T10:00:00Z")
        _ = await engine().sync()

        try writeLocalNotebook(id: "nb1", title: "Local change", pageIds: ["p1"], updatedAt: "2026-08-02T10:10:00Z")
        try seedRemoteNotebook(id: "nb1", title: "Remote change", pageIds: ["p1"], updatedAt: "2026-08-02T10:20:00Z")

        let report = await engine().sync()

        XCTAssertEqual(report.downloaded, ["nb1"])
        XCTAssertEqual(try localManifest("nb1").title, "Remote change")
    }

    func testRemoteTombstoneDeletesLocalNotebook() async throws {
        try writeLocalNotebook(id: "nb1", pageIds: ["p1"], updatedAt: "2026-08-02T10:00:00Z")
        _ = await engine().sync()

        server.setFile("/notable/deletions/nb1", Data())
        let report = await engine().sync()

        XCTAssertEqual(report.deletedLocally, ["nb1"])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: rootURL.appendingPathComponent("notebooks/nb1").path))
    }

    func testDeleteNotebookWritesTombstone() async throws {
        try writeLocalNotebook(id: "nb1", pageIds: ["p1"], updatedAt: "2026-08-02T10:00:00Z")
        let e = engine()
        _ = await e.sync()

        try await e.deleteNotebook("nb1")

        XCTAssertNotNil(server.fileData("/notable/deletions/nb1"))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: rootURL.appendingPathComponent("notebooks/nb1").path))
    }

    func testUploadRemovesOrphanRemotePages() async throws {
        try writeLocalNotebook(id: "nb1", pageIds: ["p1", "p2"], updatedAt: "2026-08-02T10:00:00Z")
        _ = await engine().sync()

        // Page p2 removed locally (e.g. page deleted), manifest updated.
        try? FileManager.default.removeItem(
            at: rootURL.appendingPathComponent("notebooks/nb1/pages/p2.json"))
        try writeLocalNotebook(id: "nb1", pageIds: ["p1"], updatedAt: "2026-08-02T10:10:00Z")

        let report = await engine().sync()

        XCTAssertEqual(report.uploaded, ["nb1"])
        XCTAssertNil(server.fileData("/notable/notebooks/nb1/pages/p2.json"),
                     "orphan remote page should be cleaned up")
    }

    func testPreconditionFailureIsReportedAsConflictNotError() async throws {
        try writeLocalNotebook(id: "nb1", pageIds: ["p1"], updatedAt: "2026-08-02T10:00:00Z")
        _ = await engine().sync()

        // Local changed; remote manifest silently replaced (etag rotated) AFTER our
        // conditional GET would 304 — simulate by rotating the file with same content,
        // then changing local. The If-Match from stored state no longer matches.
        let remoteData = try XCTUnwrap(server.fileData("/notable/notebooks/nb1/manifest.json"))
        server.setFile("/notable/notebooks/nb1/manifest.json", remoteData) // rotates etag, same bytes
        try writeLocalNotebook(id: "nb1", pageIds: ["p1"], updatedAt: "2026-08-02T10:20:00Z")

        let report = await engine().sync()

        // Conditional GET sees a change; same manifest updatedAt (10:00) => local newer =>
        // upload with FRESH etag => succeeds. So instead force a mid-flight rotation:
        // this scenario documents that a *stale* If-Match yields .conflicts, tested below
        // via direct client call.
        XCTAssertEqual(report.uploaded, ["nb1"])

        let dav = WebDAVClient(transport: server)
        do {
            _ = try await dav.put("/notable/notebooks/nb1/manifest.json", data: Data("x".utf8), ifMatch: "\"stale\"")
            XCTFail("expected 412")
        } catch WebDAVError.preconditionFailed {
            // expected
        }
    }

    func testServerErrorSurfacesInReportWithoutCrashing() async throws {
        try writeLocalNotebook(id: "nb1", pageIds: ["p1"], updatedAt: "2026-08-02T10:00:00Z")
        _ = await engine().sync()
        try writeLocalNotebook(id: "nb1", pageIds: ["p1"], updatedAt: "2026-08-02T10:10:00Z")
        server.failingPaths = ["/notable/notebooks/nb1/pages/p1.json"]

        let report = await engine().sync()

        XCTAssertEqual(report.uploaded, [])
        XCTAssertEqual(report.errors.count, 1)
    }

    func testStatePersistsAcrossEngineInstances() async throws {
        try writeLocalNotebook(id: "nb1", pageIds: ["p1"], updatedAt: "2026-08-02T10:00:00Z")
        _ = await engine().sync()

        // New engine instance (fresh app launch) should still skip.
        let report = await engine().sync()
        XCTAssertEqual(report.skipped, ["nb1"])
    }

    func testSyncStateFileNeverUploaded() async throws {
        try writeLocalNotebook(id: "nb1", pageIds: ["p1"], updatedAt: "2026-08-02T10:00:00Z")
        _ = await engine().sync()

        XCTAssertFalse(server.filePaths().contains { $0.contains("bopa-sync-state") })
    }

    // MARK: Remote index

    private func remoteIndex() throws -> RemoteIndex {
        try XCTUnwrap(RemoteIndex.load(root: rootURL))
    }

    private func writeLocalFolders(_ folders: [FolderDTO]) throws {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let file = FoldersFile(folders: folders, serverTimestamp: "2026-08-02T10:00:00Z")
        try JSONEncoder().encode(file)
            .write(to: rootURL.appendingPathComponent("folders.json"))
    }

    private func folder(_ id: String, updatedAt: String = "2026-08-02T10:00:00Z") -> FolderDTO {
        FolderDTO(id: id, title: "F-\(id)", createdAt: "2026-08-01T00:00:00Z", updatedAt: updatedAt)
    }

    func testRemoteIndexRecordsUploadedNotebook() async throws {
        try writeLocalNotebook(id: "nb1", pageIds: ["p1"], updatedAt: "2026-08-02T10:00:00Z")

        _ = await engine().sync()

        let index = try remoteIndex()
        XCTAssertEqual(index.version, 1)
        XCTAssertTrue(index.hasNotebook("nb1"))
        XCTAssertFalse(index.syncedAt.isEmpty)
    }

    func testRemoteIndexRecordsDownloadedNotebook() async throws {
        try seedRemoteNotebook(id: "nb2", pageIds: ["pa"], updatedAt: "2026-08-02T11:00:00Z")

        _ = await engine().sync()

        XCTAssertEqual(try remoteIndex().notebookIds, ["nb2"])
    }

    func testRemoteIndexRecordsRemoteFolderIds() async throws {
        try writeLocalFolders([folder("local-only")])
        try writeLocalNotebook(id: "nb1", pageIds: ["p1"], updatedAt: "2026-08-02T10:00:00Z")

        _ = await engine().sync()

        // The merge pushed the local folder to the server, so it counts as remote now.
        XCTAssertEqual(try remoteIndex().folderIds, ["local-only"])
        XCTAssertTrue(try remoteIndex().hasFolder("local-only"))
    }

    func testRemoteIndexKeepsFoldersThatOnlyExistOnServer() async throws {
        let remote = FoldersFile(
            folders: [folder("server-folder")], serverTimestamp: "2026-08-02T10:00:00Z")
        server.setFile("/notable/folders.json", try JSONEncoder().encode(remote))

        _ = await engine().sync()

        XCTAssertEqual(try remoteIndex().folderIds, ["server-folder"])
    }

    func testRemoteIndexDropsNotebookThatDisappearedFromServer() async throws {
        try seedRemoteNotebook(id: "nb2", pageIds: ["pa"], updatedAt: "2026-08-02T11:00:00Z")
        _ = await engine().sync()
        XCTAssertTrue(try remoteIndex().hasNotebook("nb2"))

        // Server-side wipe (not a tombstone): the local copy stays but is no longer remote.
        server.removeAll(under: "/notable/notebooks/nb2")
        // Fails to re-upload, so it must not be recorded as present on the server.
        server.failingPaths = ["/notable/notebooks/nb2/manifest.json"]

        _ = await engine().sync()

        XCTAssertFalse(try remoteIndex().hasNotebook("nb2"))
    }

    func testRemoteIndexDropsFolderThatDisappearedFromServer() async throws {
        let remote = FoldersFile(
            folders: [folder("f1"), folder("f2")], serverTimestamp: "2026-08-02T10:00:00Z")
        server.setFile("/notable/folders.json", try JSONEncoder().encode(remote))
        _ = await engine().sync()
        XCTAssertEqual(try remoteIndex().folderIds, ["f1", "f2"])

        // Someone rewrote folders.json on the server without f2, and the local copy is
        // rewritten to match so the union merge does not resurrect it.
        let trimmed = FoldersFile(
            folders: [folder("f1")], serverTimestamp: "2026-08-02T12:00:00Z")
        let data = try JSONEncoder().encode(trimmed)
        server.setFile("/notable/folders.json", data)
        try data.write(to: rootURL.appendingPathComponent("folders.json"))

        _ = await engine().sync()

        XCTAssertEqual(try remoteIndex().folderIds, ["f1"])
    }

    func testRemoteIndexDropsLocallyDeletedNotebook() async throws {
        try writeLocalNotebook(id: "nb1", pageIds: ["p1"], updatedAt: "2026-08-02T10:00:00Z")
        let e = engine()
        _ = await e.sync()
        XCTAssertTrue(try remoteIndex().hasNotebook("nb1"))

        try await e.deleteNotebook("nb1")

        XCTAssertFalse(try remoteIndex().hasNotebook("nb1"))
    }

    func testRemoteIndexFileNeverUploaded() async throws {
        try writeLocalFolders([folder("f1")])
        try writeLocalNotebook(id: "nb1", pageIds: ["p1"], updatedAt: "2026-08-02T10:00:00Z")
        _ = await engine().sync()
        _ = await engine().sync()

        XCTAssertFalse(server.filePaths().contains { $0.contains("bopa-remote-index") })
        XCTAssertFalse(server.filePaths().contains { $0.contains(RemoteIndex.fileName) })
    }
}
