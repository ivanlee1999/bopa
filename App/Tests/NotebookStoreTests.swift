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

    // MARK: Paper templates

    func testCreateNotebookStampsTemplateOnManifestAndFirstPage() throws {
        let manifest = try store.createNotebook(title: "Ruled", template: .lined)

        XCTAssertEqual(manifest.defaultBackground, "lined")
        XCTAssertEqual(manifest.defaultBackgroundType, "native")
        let page = try store.loadPage(
            notebookId: manifest.notebookId, pageId: try XCTUnwrap(manifest.pageIds.first))
        XCTAssertEqual(page.background, "lined")
        XCTAssertEqual(page.backgroundType, "native")
    }

    func testAddedPageInheritsNotebookTemplateOverFallback() throws {
        let manifest = try store.createNotebook(title: "Dots", template: .dotted)

        let page = try store.addPage(to: manifest.notebookId, fallbackTemplate: .squared)

        XCTAssertEqual(page.background, "dotted")
        XCTAssertEqual(page.backgroundType, "native")
    }

    /// A notebook whose default is a PDF cannot bind a new page to a PDF page here, so the
    /// caller's fallback (the app-level default paper) applies instead.
    func testAddedPageUsesFallbackWhenNotebookDefaultIsNotNative() throws {
        var manifest = try store.createNotebook(title: "Scanned")
        manifest.defaultBackground = "/sdcard/book.pdf"
        manifest.defaultBackgroundType = "autoPdf"
        try JSONEncoder().encode(manifest).write(
            to: rootURL.appendingPathComponent(
                "notebooks/\(manifest.notebookId)/manifest.json"))
        store.refresh()

        let page = try store.addPage(to: manifest.notebookId, fallbackTemplate: .squared)

        XCTAssertEqual(page.background, "squared")
        XCTAssertEqual(page.backgroundType, "native")
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

    // MARK: Sync provenance

    private func writeRemoteIndex(notebookIds: Set<String>, folderIds: Set<String>) throws {
        try RemoteIndex(
            notebookIds: notebookIds, folderIds: folderIds,
            syncedAt: NotableDate.format(Date()))
            .save(root: rootURL)
    }

    func testProvenanceIsUnknownBeforeFirstSync() throws {
        let folder = try store.createFolder(title: "Work")
        let notebook = try store.createNotebook(title: "Fresh")

        XCTAssertFalse(store.hasSyncedAtLeastOnce)
        XCTAssertEqual(store.provenance(ofNotebook: notebook.notebookId), .unknown)
        XCTAssertEqual(store.provenance(ofFolder: folder.id), .unknown)
    }

    func testProvenanceSplitsServerAndLocalOnlyItems() throws {
        let synced = try store.createNotebook(title: "Synced")
        let fresh = try store.createNotebook(title: "Fresh")
        let syncedFolder = try store.createFolder(title: "Synced folder")
        let freshFolder = try store.createFolder(title: "Fresh folder")

        try writeRemoteIndex(
            notebookIds: [synced.notebookId], folderIds: [syncedFolder.id])
        store.refresh()

        XCTAssertTrue(store.hasSyncedAtLeastOnce)
        XCTAssertEqual(store.provenance(ofNotebook: synced.notebookId), .onServer)
        XCTAssertEqual(store.provenance(ofNotebook: fresh.notebookId), .localOnly)
        XCTAssertEqual(store.provenance(ofFolder: syncedFolder.id), .onServer)
        XCTAssertEqual(store.provenance(ofFolder: freshFolder.id), .localOnly)
    }

    func testRefreshPicksUpRemoteIndexChanges() throws {
        let notebook = try store.createNotebook(title: "Synced")
        try writeRemoteIndex(notebookIds: [notebook.notebookId], folderIds: [])
        store.refresh()
        XCTAssertEqual(store.provenance(ofNotebook: notebook.notebookId), .onServer)

        // A later sync found it gone from the server.
        try writeRemoteIndex(notebookIds: [], folderIds: [])
        store.refresh()

        XCTAssertEqual(store.provenance(ofNotebook: notebook.notebookId), .localOnly)
        XCTAssertEqual(store.remoteIndex?.notebookIds, [])
    }

    func testTotalNotebookCountCountsEveryFolder() throws {
        let folder = try store.createFolder(title: "Work")
        _ = try store.createNotebook(title: "Loose")
        _ = try store.createNotebook(title: "Filed", parentFolderId: folder.id)

        XCTAssertEqual(store.totalNotebookCount, 2)
        XCTAssertEqual(store.notebooks(in: nil).count, 1)
    }

    // MARK: Sidebar tree

    func testFolderNodeTreeNestsAndCarriesCounts() throws {
        let parent = try store.createFolder(title: "Work")
        let child = try store.createFolder(title: "Projects", parentFolderId: parent.id)
        _ = try store.createNotebook(title: "Filed", parentFolderId: child.id)
        try writeRemoteIndex(notebookIds: [], folderIds: [parent.id])
        store.refresh()

        let tree = FolderNode.tree(from: store)

        XCTAssertEqual(tree.map(\.id), [parent.id])
        XCTAssertEqual(tree[0].itemCount, 1)
        XCTAssertEqual(tree[0].provenance, .onServer)
        let children = try XCTUnwrap(tree[0].children)
        XCTAssertEqual(children.map(\.title), ["Projects"])
        XCTAssertEqual(children[0].itemCount, 1)
        XCTAssertEqual(children[0].provenance, .localOnly)
        XCTAssertNil(children[0].children, "leaves must have nil children, not []")
        XCTAssertEqual(child.id, children[0].id)
    }

    func testFoldersReloadFromDiskOnRefresh() throws {
        try store.createFolder(title: "Persisted")

        // A second store over the same root (fresh app launch) sees the folder.
        let second = NotebookStore(rootURL: rootURL)
        XCTAssertEqual(second.folders.map(\.title), ["Persisted"])
    }

    // MARK: Saving against a manifest that moved underneath

    /// The data-loss path this guards: `store.notebooks` is only as fresh as the last `refresh()`,
    /// and sync writes manifests from another thread throughout a run. Saving a page used to write
    /// the cached manifest back, resurrecting a stale `pageIds` — and the next upload's orphan
    /// cleanup then deletes from the server every page that array omits.
    func testSavePageDoesNotResurrectAStalePageList() throws {
        let notebook = try store.createNotebook(title: "Notes")
        let pageId = try XCTUnwrap(notebook.pageIds.first)
        let page = try store.loadPage(notebookId: notebook.notebookId, pageId: pageId)

        // A sync lands a manifest with an extra page while the editor holds the old one.
        var downloaded = notebook
        downloaded.pageIds = notebook.pageIds + ["page-from-boox"]
        downloaded.updatedAt = "2026-08-09T10:00:00Z"
        try writeManifestDirectly(downloaded)

        try store.savePage(page)

        let onDisk = try manifestOnDisk(notebook.notebookId)
        XCTAssertEqual(
            onDisk.pageIds, downloaded.pageIds,
            "saving a page dropped a page the sync engine had just added")
    }

    /// bopa cannot name a page — the BOOX can. So an editor that has been holding a page since
    /// before the rename carries a stale `title`, and writing it back would undo the rename. The
    /// name is data this app only ever passes through; an autosave must not be able to destroy it.
    func testSavePageKeepsATitleThatArrivedWhileThePageWasOpen() throws {
        let notebook = try store.createNotebook(title: "Notes")
        let pageId = try XCTUnwrap(notebook.pageIds.first)
        let page = try store.loadPage(notebookId: notebook.notebookId, pageId: pageId)
        XCTAssertNil(page.title, "precondition: a new page starts unnamed")

        // A sync lands the BOOX's rename while the editor still holds the unnamed copy.
        var renamed = page
        renamed.title = "Shopping list"
        try writePageDirectly(renamed, notebookId: notebook.notebookId)

        try store.savePage(page)

        let onDisk = try store.loadPage(notebookId: notebook.notebookId, pageId: pageId)
        XCTAssertEqual(
            onDisk.title, "Shopping list",
            "an autosave erased a page name the sync engine had just written")
    }

    func testAddPageBuildsOnTheManifestFromDisk() throws {
        let notebook = try store.createNotebook(title: "Notes")
        var downloaded = notebook
        downloaded.pageIds = notebook.pageIds + ["page-from-boox"]
        try writeManifestDirectly(downloaded)

        let added = try store.addPage(to: notebook.notebookId)

        let onDisk = try manifestOnDisk(notebook.notebookId)
        XCTAssertEqual(onDisk.pageIds, downloaded.pageIds + [added.id])
    }

    /// Writes straight to disk, bypassing the store — standing in for the sync engine.
    private func writeManifestDirectly(_ manifest: NotebookManifest) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        try encoder.encode(manifest).write(
            to: rootURL.appendingPathComponent("notebooks/\(manifest.notebookId)/manifest.json"),
            options: .atomic)
    }

    /// Writes straight to disk, bypassing the store — standing in for the sync engine.
    private func writePageDirectly(_ page: PageFile, notebookId: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        try encoder.encode(page).write(
            to: rootURL.appendingPathComponent("notebooks/\(notebookId)/pages/\(page.id).json"),
            options: .atomic)
    }

    private func manifestOnDisk(_ id: String) throws -> NotebookManifest {
        let data = try Data(
            contentsOf: rootURL.appendingPathComponent("notebooks/\(id)/manifest.json"))
        return try JSONDecoder().decode(NotebookManifest.self, from: data)
    }
}
