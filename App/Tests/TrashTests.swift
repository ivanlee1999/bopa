import NotableKit
import XCTest

@testable import Bopa

/// The Trash: staging, restoring, and the one path that actually deletes.
///
/// The behaviour under test is the two-step rule. Staging destroys nothing — a trashed notebook's
/// files stay, and it goes on syncing, which is what makes restoring mean anything — but it is
/// *published*, because the Trash is a state of the notebook and deleting has to mean the same
/// thing on the BOOX as here. Purging is the step that publishes a deletion, and it must never
/// publish one whose local half did not happen.
@MainActor
final class TrashTests: XCTestCase {
    private var rootURL: URL!
    private var store: NotebookStore!
    /// Every document id the store asked to have tombstoned, in order.
    private var tombstoned: [String] = []
    /// Every document id the store queued for push, in order.
    private var changed: [String] = []

    override func setUp() async throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("bopa-trash-test-\(UUID().uuidString)")
        store = NotebookStore(rootURL: rootURL)
        tombstoned = []
        changed = []
        store.didDeleteDocuments = { [weak self] ids in self?.tombstoned.append(contentsOf: ids) }
        store.didChangeDocuments = { [weak self] ids in self?.changed.append(contentsOf: ids) }
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: rootURL)
    }

    // MARK: Staging

    func testTrashingANotebookHidesItWithoutDeletingIt() throws {
        let notebook = try store.createNotebook(title: "Draft")

        try store.trashNotebook(id: notebook.notebookId)

        XCTAssertTrue(store.notebooks(in: nil).isEmpty, "hidden from the library")
        XCTAssertEqual(store.trashedNotebooks.map(\.notebookId), [notebook.notebookId])
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: rootURL.appendingPathComponent("notebooks/\(notebook.notebookId)").path),
            "the files stay, so sync keeps holding the notebook up")
        XCTAssertEqual(tombstoned, [], "nothing is deleted until it is purged")
        XCTAssertEqual(PendingDeletions.load(root: rootURL), [])
    }

    /// Trashing has to reach the other device, and it travels as an ordinary edit to the notebook
    /// document — so the document has to be queued, and it has to carry a timestamp newer than the
    /// copy the peer still thinks is live, or §5.5 can decide the tie the wrong way.
    func testTrashingANotebookPublishesItWithAFreshTimestamp() throws {
        let notebook = try store.createNotebook(title: "Draft")
        let before = store.manifest(id: notebook.notebookId)!.updatedAt
        changed = []

        try store.trashNotebook(id: notebook.notebookId)

        XCTAssertEqual(changed, [CouchDocID.notebook(notebook.notebookId)])
        let after = store.manifest(id: notebook.notebookId)!
        XCTAssertGreaterThanOrEqual(after.updatedAt, before)
        XCTAssertEqual(after.updatedBy, store.deviceID, "this device made the change")
    }

    func testTrashingAFolderPublishesTheFolder() throws {
        let folder = try store.createFolder(title: "Term 1")
        changed = []

        try store.trashFolder(id: folder.id)

        XCTAssertTrue(changed.contains(CouchDocID.folder(folder.id)))
    }

    /// A restore is a second published edit, not a local un-hiding: the peer is holding a trashed
    /// copy and only a newer write takes it back out of its Trash too.
    func testRestoringPublishesTheNotebookAgain() throws {
        let notebook = try store.createNotebook(title: "Draft")
        try store.trashNotebook(id: notebook.notebookId)
        changed = []

        try store.restoreNotebook(id: notebook.notebookId)

        XCTAssertEqual(changed, [CouchDocID.notebook(notebook.notebookId)])
        XCTAssertTrue(store.trashedNotebooks.isEmpty)
    }

    /// The notebooks inside a trashed folder must not pop up at the root. The root adopts
    /// notebooks whose folder is *gone*, and a trashed folder is not gone.
    func testTrashingAFolderHidesWhatIsInsideIt() throws {
        let folder = try store.createFolder(title: "Term 1")
        let child = try store.createFolder(title: "Week 1", parentFolderId: folder.id)
        let notebook = try store.createNotebook(title: "Lecture", parentFolderId: child.id)

        try store.trashFolder(id: folder.id)

        XCTAssertTrue(store.folders(in: nil).isEmpty)
        XCTAssertTrue(store.notebooks(in: nil).isEmpty, "not adopted to the root")
        XCTAssertEqual(store.trashedFolders.map(\.id), [folder.id])
        XCTAssertTrue(store.trashedNotebooks.isEmpty, "only the folder itself is marked")
        XCTAssertEqual(store.notebooks.count, 1)
        XCTAssertEqual(store.notebooks[0].notebookId, notebook.notebookId)
    }

    func testTrashSurvivesAReload() throws {
        let notebook = try store.createNotebook(title: "Draft")
        try store.trashNotebook(id: notebook.notebookId)

        let reopened = NotebookStore(rootURL: rootURL)

        XCTAssertEqual(reopened.trashedNotebooks.map(\.notebookId), [notebook.notebookId])
        XCTAssertTrue(reopened.notebooks(in: nil).isEmpty)
    }

    // MARK: Restoring

    func testRestoringPutsItBackWhereItWas() throws {
        let folder = try store.createFolder(title: "Work")
        let notebook = try store.createNotebook(title: "Draft", parentFolderId: folder.id)
        try store.trashNotebook(id: notebook.notebookId)

        try store.restoreNotebook(id: notebook.notebookId)

        XCTAssertEqual(store.notebooks(in: folder.id).map(\.notebookId), [notebook.notebookId])
        XCTAssertTrue(store.trash.isEmpty)
    }

    /// Restoring into a folder that is gone would put the notebook somewhere unreachable, which
    /// looks exactly like the restore having quietly failed.
    ///
    /// The folder disappears the way a peer's tombstone makes it disappear — protocol §6.4 deletes
    /// the folder alone and leaves what was filed under it — rather than through a local purge,
    /// which takes the subtree with it and so cannot produce this state.
    func testRestoringIntoAFolderThatIsGoneFallsBackToTheRoot() throws {
        let folder = try store.createFolder(title: "Work")
        let notebook = try store.createNotebook(title: "Draft", parentFolderId: folder.id)
        try store.trashNotebook(id: notebook.notebookId)
        try writeFoldersOnDisk([])
        XCTAssertNil(store.folder(id: folder.id))

        try store.restoreNotebook(id: notebook.notebookId)

        XCTAssertEqual(store.notebooks(in: nil).map(\.notebookId), [notebook.notebookId])
        XCTAssertNil(store.notebooks(in: nil).first?.parentFolderId)
    }

    /// A notebook already in the Trash is still inside its folder, so purging the folder takes it
    /// too — otherwise it would be left filed under a folder that no longer exists, with no
    /// tombstone of its own and nothing but the Trash screen able to reach it.
    func testPurgingAFolderAlsoTakesTrashedNotebooksInsideIt() throws {
        let folder = try store.createFolder(title: "Work")
        let notebook = try store.createNotebook(title: "Draft", parentFolderId: folder.id)
        try store.trashNotebook(id: notebook.notebookId)

        try store.purgeFolder(id: folder.id)

        XCTAssertTrue(store.notebooks.isEmpty)
        XCTAssertTrue(store.trash.isEmpty)
        XCTAssertTrue(tombstoned.contains(CouchDocID.notebook(notebook.notebookId)))
    }

    // MARK: Purging

    func testPurgingANotebookRemovesItAndTombstonesIt() throws {
        let notebook = try store.createNotebook(title: "Draft")
        try store.trashNotebook(id: notebook.notebookId)

        try store.purgeNotebook(id: notebook.notebookId)

        XCTAssertTrue(store.notebooks.isEmpty)
        XCTAssertTrue(store.trash.isEmpty)
        XCTAssertEqual(tombstoned, [CouchDocID.notebook(notebook.notebookId)])
        XCTAssertEqual(PendingDeletions.load(root: rootURL), [notebook.notebookId])
    }

    /// Every descendant needs its own tombstone. Deleting the folder alone is what let a peer send
    /// the notebooks back under a folder that no longer existed.
    func testPurgingAFolderTombstonesEveryDescendant() throws {
        let folder = try store.createFolder(title: "Term 1")
        let child = try store.createFolder(title: "Week 1", parentFolderId: folder.id)
        let notebook = try store.createNotebook(title: "Lecture", parentFolderId: child.id)
        try store.trashFolder(id: folder.id)

        try store.purgeFolder(id: folder.id)

        XCTAssertEqual(
            Set(tombstoned),
            [
                CouchDocID.folder(folder.id),
                CouchDocID.folder(child.id),
                CouchDocID.notebook(notebook.notebookId),
            ])
        XCTAssertTrue(store.folders.isEmpty)
        XCTAssertTrue(store.notebooks.isEmpty)
        XCTAssertTrue(store.trash.isEmpty)
    }

    /// The defect this whole path replaces: the tombstone used to be recorded first and the local
    /// removal's error thrown away, so the notebook could stay on the iPad while its deletion was
    /// already on its way to the server. A removal that fails must leave nothing published.
    func testAFailedRemovalPublishesNothing() throws {
        let notebook = try store.createNotebook(title: "Draft")
        let dir = rootURL.appendingPathComponent("notebooks/\(notebook.notebookId)")

        // Read-only parent: the directory is still there, and removing it fails.
        let notebooksDir = rootURL.appendingPathComponent("notebooks")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500], ofItemAtPath: notebooksDir.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: notebooksDir.path)
        }

        XCTAssertThrowsError(try store.purgeNotebook(id: notebook.notebookId))

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: dir.path), "still here, so still the user's")
        XCTAssertEqual(
            PendingDeletions.load(root: rootURL), [], "the intent was rolled back")
    }

    func testEmptyTrashRemovesEverythingStaged() throws {
        let folder = try store.createFolder(title: "Old")
        _ = try store.createNotebook(title: "Inside", parentFolderId: folder.id)
        let loose = try store.createNotebook(title: "Loose")
        try store.trashFolder(id: folder.id)
        try store.trashNotebook(id: loose.notebookId)

        try store.emptyTrash()

        XCTAssertTrue(store.trash.isEmpty)
        XCTAssertTrue(store.folders.isEmpty)
        XCTAssertTrue(store.notebooks.isEmpty)
    }

    // MARK: Scope

    func testDeletionScopeCountsTheWholeSubtree() throws {
        let folder = try store.createFolder(title: "Term 1")
        let child = try store.createFolder(title: "Week 1", parentFolderId: folder.id)
        let notebook = try store.createNotebook(title: "Lecture", parentFolderId: child.id)
        _ = try store.addPage(to: notebook.notebookId)

        let scope = store.deletionScope(ofFolder: folder.id)

        XCTAssertEqual(scope.childFolderCount, 1)
        XCTAssertEqual(scope.notebookIDs, [notebook.notebookId])
        XCTAssertEqual(scope.pageCount, 2)
        XCTAssertFalse(scope.isEmpty)
    }

    /// `folders.json` is merged data and can come back from a peer with a chain that loops; the
    /// walk has to settle rather than spin.
    func testDeletionScopeSurvivesAFolderCycle() throws {
        let a = try store.createFolder(title: "A")
        let b = try store.createFolder(title: "B", parentFolderId: a.id)
        try writeFoldersOnDisk([
            FolderDTO(
                id: a.id, title: "A", parentFolderId: b.id,
                createdAt: a.createdAt, updatedAt: a.updatedAt),
            FolderDTO(
                id: b.id, title: "B", parentFolderId: a.id,
                createdAt: b.createdAt, updatedAt: b.updatedAt),
        ])

        let scope = store.deletionScope(ofFolder: a.id)

        XCTAssertEqual(Set(scope.folderIDs), [a.id, b.id])
    }

    private func writeFoldersOnDisk(_ folders: [FolderDTO]) throws {
        let file = FoldersFile(folders: folders, serverTimestamp: NotableDate.format(Date()))
        try JSONEncoder().encode(file)
            .write(to: rootURL.appendingPathComponent("folders.json"))
        store.refresh()
    }
}
