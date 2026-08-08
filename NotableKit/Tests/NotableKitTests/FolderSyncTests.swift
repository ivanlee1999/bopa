import XCTest
@testable import NotableKit

final class FolderSyncTests: XCTestCase {
    private var server: MockWebDAVServer!
    private var rootURL: URL!

    override func setUp() {
        super.setUp()
        server = MockWebDAVServer()
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("bopa-folder-sync-test-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: rootURL)
        super.tearDown()
    }

    private func engine() -> SyncEngine {
        SyncEngine(transport: server, rootURL: rootURL)
    }

    // MARK: Fixtures

    private func folder(
        _ id: String, title: String, parent: String? = nil, updatedAt: String
    ) -> FolderDTO {
        FolderDTO(
            id: id, title: title, parentFolderId: parent,
            createdAt: "2026-08-01T00:00:00Z", updatedAt: updatedAt)
    }

    private func writeLocalFolders(_ folders: [FolderDTO]) throws {
        let file = FoldersFile(folders: folders, serverTimestamp: "2026-08-02T00:00:00Z")
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try JSONEncoder().encode(file).write(to: rootURL.appendingPathComponent("folders.json"))
    }

    private func seedRemoteFolders(_ folders: [FolderDTO]) throws {
        let file = FoldersFile(folders: folders, serverTimestamp: "2026-08-02T00:00:00Z")
        server.setFile("/notable/folders.json", try JSONEncoder().encode(file))
    }

    private func remoteFolders() throws -> [FolderDTO] {
        let data = try XCTUnwrap(server.fileData("/notable/folders.json"))
        return try JSONDecoder().decode(FoldersFile.self, from: data).folders
    }

    private func localFolders() throws -> [FolderDTO] {
        let data = try Data(contentsOf: rootURL.appendingPathComponent("folders.json"))
        return try JSONDecoder().decode(FoldersFile.self, from: data).folders
    }

    // MARK: FolderMerge unit

    func testMergeUnionNewerUpdatedAtWinsPerFolder() {
        let local = [
            folder("a", title: "A local", updatedAt: "2026-08-02T12:00:00Z"),
            folder("c", title: "C only local", updatedAt: "2026-08-02T10:00:00Z"),
        ]
        let remote = [
            folder("a", title: "A remote", updatedAt: "2026-08-02T11:00:00Z"),
            folder("b", title: "B only remote", updatedAt: "2026-08-02T10:00:00Z"),
        ]

        let merged = FolderMerge.merge(local: local, remote: remote)

        XCTAssertEqual(merged.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(merged[0].title, "A local", "local a is newer and must win")
    }

    func testMergeRemoteNewerWins() {
        let local = [folder("a", title: "A local", updatedAt: "2026-08-02T10:00:00Z")]
        let remote = [folder("a", title: "A remote", updatedAt: "2026-08-02T11:00:00Z")]

        XCTAssertEqual(FolderMerge.merge(local: local, remote: remote).map(\.title), ["A remote"])
    }

    // MARK: Engine scenarios

    func testLocalFoldersUploadedWhenRemoteAbsent() async throws {
        try writeLocalFolders([folder("f1", title: "Work", updatedAt: "2026-08-02T10:00:00Z")])

        let report = await engine().sync()

        XCTAssertTrue(report.uploaded.contains("folders.json"))
        XCTAssertEqual(try remoteFolders().map(\.title), ["Work"])
    }

    func testRemoteFoldersDownloadedWhenLocalAbsent() async throws {
        try seedRemoteFolders([folder("f1", title: "BOOX folder", updatedAt: "2026-08-02T10:00:00Z")])

        let report = await engine().sync()

        XCTAssertTrue(report.downloaded.contains("folders.json"))
        XCTAssertEqual(try localFolders().map(\.title), ["BOOX folder"])
    }

    func testMergeBothDirectionsAndPutOnlyWhenRemoteChanges() async throws {
        try writeLocalFolders([
            folder("a", title: "A local newer", updatedAt: "2026-08-02T12:00:00Z"),
            folder("c", title: "C local only", updatedAt: "2026-08-02T10:00:00Z"),
        ])
        try seedRemoteFolders([
            folder("a", title: "A remote older", updatedAt: "2026-08-02T11:00:00Z"),
            folder("b", title: "B remote only", updatedAt: "2026-08-02T10:00:00Z"),
        ])

        let report = await engine().sync()

        XCTAssertTrue(report.uploaded.contains("folders.json"))
        let expectedTitles = ["A local newer", "B remote only", "C local only"]
        XCTAssertEqual(try remoteFolders().sorted { $0.id < $1.id }.map(\.title), expectedTitles)
        XCTAssertEqual(try localFolders().sorted { $0.id < $1.id }.map(\.title), expectedTitles)

        // Second sync: both sides already converged; no folder transfer at all.
        let second = await engine().sync()
        XCTAssertFalse(second.uploaded.contains("folders.json"))
        XCTAssertFalse(second.downloaded.contains("folders.json"))
    }

    func testRemoteOnlyChangeRefreshesLocalWithoutPut() async throws {
        try writeLocalFolders([folder("a", title: "Old title", updatedAt: "2026-08-02T10:00:00Z")])
        try seedRemoteFolders([folder("a", title: "Renamed on BOOX", updatedAt: "2026-08-02T11:00:00Z")])
        let etagBefore = server.fileData("/notable/folders.json")

        let report = await engine().sync()

        XCTAssertTrue(report.downloaded.contains("folders.json"))
        XCTAssertFalse(report.uploaded.contains("folders.json"))
        XCTAssertEqual(try localFolders().map(\.title), ["Renamed on BOOX"])
        XCTAssertEqual(server.fileData("/notable/folders.json"), etagBefore, "remote must be untouched")
    }

    func testNoFoldersAnywhereIsANoOp() async throws {
        let report = await engine().sync()

        XCTAssertNil(server.fileData("/notable/folders.json"))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: rootURL.appendingPathComponent("folders.json").path))
        XCTAssertFalse(report.uploaded.contains("folders.json"))
        XCTAssertFalse(report.downloaded.contains("folders.json"))
    }

    // MARK: Pending deletions

    private func writeLocalNotebook(id: String, updatedAt: String) throws {
        let manifest = NotebookManifest(
            notebookId: id, title: "Nb", pageIds: [],
            createdAt: "2026-08-01T00:00:00Z", updatedAt: updatedAt, serverTimestamp: updatedAt)
        let dir = rootURL.appendingPathComponent("notebooks/\(id)/pages")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONEncoder().encode(manifest)
            .write(to: rootURL.appendingPathComponent("notebooks/\(id)/manifest.json"))
    }

    func testPendingDeletionUploadsTombstoneOnNextSync() async throws {
        try writeLocalNotebook(id: "nb1", updatedAt: "2026-08-02T10:00:00Z")
        _ = await engine().sync()
        XCTAssertNotNil(server.fileData("/notable/notebooks/nb1/manifest.json"))

        // Offline deletion, store-side: remove dir + record pending.
        try? FileManager.default.removeItem(at: rootURL.appendingPathComponent("notebooks/nb1"))
        PendingDeletions.add("nb1", root: rootURL)

        _ = await engine().sync()

        XCTAssertNotNil(server.fileData("/notable/deletions/nb1"), "tombstone must be uploaded")
        XCTAssertEqual(PendingDeletions.load(root: rootURL), [], "pending list must be cleared")
        // The tombstone also wins over the still-present remote copy on this same sync.
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: rootURL.appendingPathComponent("notebooks/nb1").path))
    }

    func testDeleteNotebookOfflineStaysPendingThenFlushes() async throws {
        try writeLocalNotebook(id: "nb1", updatedAt: "2026-08-02T10:00:00Z")
        let e = engine()
        _ = await e.sync()

        server.failingPaths = ["/notable/deletions/nb1"]
        try await e.deleteNotebook("nb1")

        XCTAssertNil(server.fileData("/notable/deletions/nb1"))
        XCTAssertEqual(PendingDeletions.load(root: rootURL), ["nb1"])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: rootURL.appendingPathComponent("notebooks/nb1").path))

        // Server back: the next sync flushes the tombstone and clears the record.
        server.failingPaths = []
        _ = await engine().sync()

        XCTAssertNotNil(server.fileData("/notable/deletions/nb1"))
        XCTAssertEqual(PendingDeletions.load(root: rootURL), [])
    }

    func testPendingDeletionsFileNeverUploaded() async throws {
        try writeLocalNotebook(id: "nb1", updatedAt: "2026-08-02T10:00:00Z")
        PendingDeletions.add("ghost", root: rootURL)
        _ = await engine().sync()

        XCTAssertFalse(server.filePaths().contains { $0.contains("bopa-pending-deletions") })
    }

    func testPendingDeletionsAddRemoveRoundTrip() {
        PendingDeletions.add("b", root: rootURL)
        PendingDeletions.add("a", root: rootURL)
        PendingDeletions.add("a", root: rootURL) // idempotent
        XCTAssertEqual(PendingDeletions.load(root: rootURL), ["a", "b"])

        PendingDeletions.remove("a", root: rootURL)
        XCTAssertEqual(PendingDeletions.load(root: rootURL), ["b"])

        PendingDeletions.remove("b", root: rootURL)
        XCTAssertEqual(PendingDeletions.load(root: rootURL), [])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: PendingDeletions.fileURL(root: rootURL).path))
    }
}
