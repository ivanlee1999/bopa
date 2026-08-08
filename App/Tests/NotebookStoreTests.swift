import NotableKit
import XCTest

@testable import Bopa

@MainActor
final class NotebookStoreTests: XCTestCase {
    private var rootURL: URL!
    private var store: NotebookStore!

    override func setUp() async throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("bopa-store-test-\(UUID().uuidString)")
        store = NotebookStore(rootURL: rootURL)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: rootURL)
    }

    private func foldersOnDisk() throws -> FoldersFile {
        let data = try Data(contentsOf: rootURL.appendingPathComponent("folders.json"))
        return try JSONDecoder().decode(FoldersFile.self, from: data)
    }

    // MARK: Folders

    func testCreateFolderPersistsToFoldersJSON() throws {
        let folder = try store.createFolder(title: "Work")

        XCTAssertEqual(store.folders.map(\.title), ["Work"])
        let file = try foldersOnDisk()
        XCTAssertEqual(file.version, 1)
        XCTAssertEqual(file.folders.map(\.id), [folder.id])
        XCTAssertNil(file.folders[0].parentFolderId)
    }

    func testCreateNestedFolder() throws {
        let parent = try store.createFolder(title: "Work")
        let child = try store.createFolder(title: "Projects", parentFolderId: parent.id)

        XCTAssertEqual(store.folders(in: nil).map(\.id), [parent.id])
        XCTAssertEqual(store.folders(in: parent.id).map(\.id), [child.id])
        XCTAssertEqual(store.itemCount(in: parent.id), 1)
    }

    func testRenameFolderBumpsUpdatedAt() throws {
        let folder = try store.createFolder(title: "Wrok")

        try store.renameFolder(id: folder.id, title: "Work")

        let renamed = try XCTUnwrap(store.folder(id: folder.id))
        XCTAssertEqual(renamed.title, "Work")
        let before = try XCTUnwrap(NotableDate.parse(folder.updatedAt))
        let after = try XCTUnwrap(NotableDate.parse(renamed.updatedAt))
        XCTAssertGreaterThanOrEqual(after, before)
        XCTAssertEqual(renamed.createdAt, folder.createdAt)
    }

    func testDeleteEmptyFolder() throws {
        let folder = try store.createFolder(title: "Scratch")

        try store.deleteFolder(id: folder.id)

        XCTAssertTrue(store.folders.isEmpty)
        XCTAssertTrue(try foldersOnDisk().folders.isEmpty)
    }

    func testDeleteNonEmptyFolderThrows() throws {
        let folder = try store.createFolder(title: "Busy")
        _ = try store.createNotebook(title: "Inside", parentFolderId: folder.id)

        XCTAssertThrowsError(try store.deleteFolder(id: folder.id))
        XCTAssertEqual(store.folders.count, 1)
    }

    // MARK: Notebooks in folders

    func testCreateNotebookInFolder() throws {
        let folder = try store.createFolder(title: "Work")
        let manifest = try store.createNotebook(title: "Meeting notes", parentFolderId: folder.id)

        XCTAssertEqual(manifest.parentFolderId, folder.id)
        XCTAssertEqual(store.notebooks(in: folder.id).map(\.notebookId), [manifest.notebookId])
        XCTAssertTrue(store.notebooks(in: nil).isEmpty)
    }

    func testMoveNotebookBetweenFolders() throws {
        let folder = try store.createFolder(title: "Work")
        let manifest = try store.createNotebook(title: "Loose")
        XCTAssertEqual(store.notebooks(in: nil).count, 1)

        try store.moveNotebook(id: manifest.notebookId, toFolder: folder.id)
        XCTAssertEqual(store.notebooks(in: folder.id).count, 1)
        XCTAssertTrue(store.notebooks(in: nil).isEmpty)

        try store.moveNotebook(id: manifest.notebookId, toFolder: nil)
        XCTAssertEqual(store.notebooks(in: nil).count, 1)
        let moved = try XCTUnwrap(store.manifest(id: manifest.notebookId))
        XCTAssertNil(moved.parentFolderId)
    }

    func testRenameNotebookUpdatesManifestAndBumpsUpdatedAt() throws {
        let manifest = try store.createNotebook(title: "Old")

        try store.renameNotebook(id: manifest.notebookId, title: "New")

        let renamed = try XCTUnwrap(store.manifest(id: manifest.notebookId))
        XCTAssertEqual(renamed.title, "New")
        let before = try XCTUnwrap(NotableDate.parse(manifest.updatedAt))
        let after = try XCTUnwrap(NotableDate.parse(renamed.updatedAt))
        XCTAssertGreaterThanOrEqual(after, before)

        // Persisted, not just in memory.
        let data = try Data(contentsOf: rootURL
            .appendingPathComponent("notebooks/\(manifest.notebookId)/manifest.json"))
        XCTAssertEqual(try JSONDecoder().decode(NotebookManifest.self, from: data).title, "New")
    }

    func testDeleteNotebookRemovesDirAndRecordsPendingDeletion() throws {
        let manifest = try store.createNotebook(title: "Doomed")
        let dir = rootURL.appendingPathComponent("notebooks/\(manifest.notebookId)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path))

        try store.deleteNotebook(id: manifest.notebookId)

        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
        XCTAssertTrue(store.notebooks.isEmpty)
        XCTAssertEqual(PendingDeletions.load(root: rootURL), [manifest.notebookId])
    }

    func testFoldersReloadFromDiskOnRefresh() throws {
        try store.createFolder(title: "Persisted")

        // A second store over the same root (fresh app launch) sees the folder.
        let second = NotebookStore(rootURL: rootURL)
        XCTAssertEqual(second.folders.map(\.title), ["Persisted"])
    }
}
