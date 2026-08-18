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

    func testPurgeEmptyFolder() throws {
        let folder = try store.createFolder(title: "Scratch")

        try store.purgeFolder(id: folder.id)

        XCTAssertTrue(store.folders.isEmpty)
        XCTAssertTrue(try foldersOnDisk().folders.isEmpty)
    }

    /// A populated folder is no longer refused — it is thrown away whole, which is the point of
    /// the Trash. What must not happen is a notebook surviving its folder's purge.
    func testPurgeFolderTakesItsSubtree() throws {
        let folder = try store.createFolder(title: "Busy")
        let child = try store.createFolder(title: "Nested", parentFolderId: folder.id)
        let inside = try store.createNotebook(title: "Inside", parentFolderId: child.id)

        let scope = try store.purgeFolder(id: folder.id)

        XCTAssertEqual(Set(scope.folderIDs), [folder.id, child.id])
        XCTAssertEqual(scope.notebookIDs, [inside.notebookId])
        XCTAssertTrue(store.folders.isEmpty)
        XCTAssertTrue(store.notebooks.isEmpty)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: rootURL.appendingPathComponent("notebooks/\(inside.notebookId)").path))
    }

    // MARK: Folders that stopped reaching the root

    /// Drops folders from `folders.json` behind the store's back, the way applying a peer's
    /// folder tombstone does — protocol §6.4 deletes the folder alone, so this is how a notebook
    /// ends up filed under a folder nobody holds.
    private func dropFoldersOnDisk(ids: Set<String>) throws {
        let kept = try foldersOnDisk().folders.filter { !ids.contains($0.id) }
        let file = FoldersFile(folders: kept, serverTimestamp: NotableDate.format(Date()))
        try JSONEncoder().encode(file)
            .write(to: rootURL.appendingPathComponent("folders.json"))
        store.refresh()
    }

    func testNotebookWhoseFolderWasDeletedFallsBackToRoot() throws {
        let folder = try store.createFolder(title: "Semester")
        let filed = try store.createNotebook(title: "U", parentFolderId: folder.id)

        try dropFoldersOnDisk(ids: [folder.id])

        // The manifest is left alone — the sync layer does not repair the parent (protocol
        // §6.4), so the library is what has to absorb it.
        XCTAssertEqual(store.manifest(id: filed.notebookId)?.parentFolderId, folder.id)
        XCTAssertEqual(store.notebooks(in: nil).map(\.title), ["U"])
        XCTAssertEqual(store.totalNotebookCount, 1)
    }

    func testOrphanedSubfolderSurfacesAtRootStillHoldingItsNotebook() throws {
        let parent = try store.createFolder(title: "Semester")
        let child = try store.createFolder(title: "Week 1", parentFolderId: parent.id)
        _ = try store.createNotebook(title: "Filed", parentFolderId: child.id)

        try dropFoldersOnDisk(ids: [parent.id])

        // The child is adopted by the root; the notebook stays inside it, because its own
        // folder still exists and is now reachable again.
        XCTAssertEqual(store.folders(in: nil).map(\.id), [child.id])
        XCTAssertEqual(store.notebooks(in: child.id).map(\.title), ["Filed"])
        XCTAssertTrue(store.notebooks(in: nil).isEmpty)

        let tree = LibraryNode.tree(from: store)
        XCTAssertEqual(tree.map(\.title), ["Week 1"])
        XCTAssertEqual(tree[0].count, 1)
        XCTAssertEqual(try XCTUnwrap(tree[0].children).map(\.title), ["Filed"])
    }

    func testRootAdoptionDoesNotDisturbFoldersThatStillReachIt() throws {
        let parent = try store.createFolder(title: "Work")
        let child = try store.createFolder(title: "Projects", parentFolderId: parent.id)
        _ = try store.createNotebook(title: "Loose")
        _ = try store.createNotebook(title: "Filed", parentFolderId: child.id)

        XCTAssertEqual(store.folders(in: nil).map(\.id), [parent.id])
        XCTAssertEqual(store.folders(in: parent.id).map(\.id), [child.id])
        XCTAssertEqual(store.notebooks(in: nil).map(\.title), ["Loose"])
        XCTAssertEqual(store.itemCount(in: child.id), 1)
        XCTAssertTrue(store.isFolderEmpty(parent.id) == false)
    }

    /// Deleting the top of a nested subtree must not flatten it. Every folder below the deleted
    /// one still names a parent that exists, so only the top survivor is adopted by the root —
    /// listing the descendants there too would draw each of them twice.
    func testOrphanedSubtreeKeepsItsNestingInsteadOfFlattening() throws {
        let top = try store.createFolder(title: "Semester")
        let middle = try store.createFolder(title: "Week 1", parentFolderId: top.id)
        let leaf = try store.createFolder(title: "Monday", parentFolderId: middle.id)

        try dropFoldersOnDisk(ids: [top.id])

        XCTAssertEqual(store.folders(in: nil).map(\.id), [middle.id])
        XCTAssertEqual(store.folders(in: middle.id).map(\.id), [leaf.id])

        let tree = LibraryNode.tree(from: store)
        XCTAssertEqual(tree.map(\.title), ["Week 1"])
        XCTAssertEqual(try XCTUnwrap(tree[0].children).map(\.title), ["Monday"])
        XCTAssertEqual(drawnFolderIDs(tree).sorted(), [middle.id, leaf.id].sorted())
    }

    /// A `parentFolderId` loop from a hand-edited or half-merged file has no folder the root can
    /// reach it by. One member is adopted so the loop is drawn at all, and the rest nest beneath
    /// it — still exactly once each, rather than taking their notebooks into hiding.
    func testFolderCycleGetsExactlyOneEntryPoint() throws {
        let first = try store.createFolder(title: "A")
        let second = try store.createFolder(title: "B", parentFolderId: first.id)
        var file = try foldersOnDisk()
        file.folders = file.folders.map { folder in
            var folder = folder
            if folder.id == first.id { folder.parentFolderId = second.id }
            return folder
        }
        try JSONEncoder().encode(file)
            .write(to: rootURL.appendingPathComponent("folders.json"))
        store.refresh()

        // Lowest id wins, so the sidebar does not reshuffle between launches.
        XCTAssertEqual(store.folders(in: nil).map(\.id), [min(first.id, second.id)])
        XCTAssertEqual(drawnFolderIDs(LibraryNode.tree(from: store)).sorted(),
                       [first.id, second.id].sorted())
    }

    /// Every folder id the sidebar actually draws, in tree order, so a test can prove nothing is
    /// hidden *and* nothing is duplicated.
    private func drawnFolderIDs(_ nodes: [LibraryNode]) -> [String] {
        nodes.flatMap { node -> [String] in
            let own = node.kind == .folder ? [node.itemId] : []
            return own + drawnFolderIDs(node.children ?? [])
        }
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

    func testPurgeNotebookRemovesDirAndRecordsPendingDeletion() throws {
        let manifest = try store.createNotebook(title: "Doomed")
        let dir = rootURL.appendingPathComponent("notebooks/\(manifest.notebookId)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path))

        try store.purgeNotebook(id: manifest.notebookId)

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

    func testLibraryTreeNestsFoldersAndCarriesCounts() throws {
        let parent = try store.createFolder(title: "Work")
        let child = try store.createFolder(title: "Projects", parentFolderId: parent.id)
        _ = try store.createNotebook(title: "Filed", parentFolderId: child.id)
        try writeRemoteIndex(notebookIds: [], folderIds: [parent.id])
        store.refresh()

        let tree = LibraryNode.tree(from: store)

        XCTAssertEqual(tree.map(\.itemId), [parent.id])
        XCTAssertEqual(tree[0].count, 1)
        XCTAssertEqual(tree[0].provenance, .onServer)
        let children = try XCTUnwrap(tree[0].children)
        XCTAssertEqual(children.map(\.title), ["Projects"])
        XCTAssertEqual(children[0].count, 1)
        XCTAssertEqual(children[0].provenance, .localOnly)
        XCTAssertEqual(child.id, children[0].itemId)
    }

    /// The point of the tree: every note is on it, under the folder holding it, with the loose
    /// ones at the root — subfolders first, then notebooks, at each level.
    func testLibraryTreeCarriesNotebooksUnderTheirFolder() throws {
        let parent = try store.createFolder(title: "Work")
        let child = try store.createFolder(title: "Projects", parentFolderId: parent.id)
        let filed = try store.createNotebook(title: "Filed", parentFolderId: parent.id)
        _ = try store.createNotebook(title: "Deep", parentFolderId: child.id)
        _ = try store.createNotebook(title: "Loose")

        let tree = LibraryNode.tree(from: store)

        XCTAssertEqual(tree.map(\.title), ["Work", "Loose"])
        XCTAssertEqual(tree[1].kind, .notebook)
        XCTAssertNil(tree[1].children, "leaves must have nil children, not []")

        let underWork = try XCTUnwrap(tree[0].children)
        XCTAssertEqual(underWork.map(\.title), ["Projects", "Filed"])
        XCTAssertEqual(underWork[1].kind, .notebook)
        XCTAssertEqual(underWork[1].itemId, filed.notebookId)
        // A notebook row counts pages, not children.
        XCTAssertEqual(underWork[1].count, 1)
        XCTAssertEqual(try XCTUnwrap(underWork[0].children).map(\.title), ["Deep"])
    }

    /// A folder and a notebook may not collide in the outline's identity space, or SwiftUI
    /// would draw one of them in place of the other.
    func testLibraryNodeIdsAreNamespacedByKind() throws {
        let folder = try store.createFolder(title: "Work")
        let notebook = try store.createNotebook(title: "Loose")

        let tree = LibraryNode.tree(from: store)
        let ids = tree.map(\.id)

        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertEqual(ids, ["folder:\(folder.id)", "notebook:\(notebook.notebookId)"])
    }

    /// Rows are expanded unless the user shut them, so a folder that arrives from a sync shows
    /// its notes without being opened first.
    func testFlattenedTreeIsExpandedExceptWhereCollapsed() throws {
        let parent = try store.createFolder(title: "Work")
        _ = try store.createNotebook(title: "Filed", parentFolderId: parent.id)
        _ = try store.createNotebook(title: "Loose")

        let tree = LibraryNode.tree(from: store)

        let open = LibraryNode.flattened(tree, collapsed: [])
        XCTAssertEqual(open.map(\.node.title), ["Work", "Filed", "Loose"])
        XCTAssertEqual(open.map(\.depth), [0, 1, 0])

        let shut = LibraryNode.flattened(tree, collapsed: ["folder:\(parent.id)"])
        XCTAssertEqual(shut.map(\.node.title), ["Work", "Loose"])
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

    // MARK: Refusing saves that could only lose the ink

    /// `savePage` used to return success without writing when the manifest could not be read, so
    /// the editor cleared its dirty flag and the strokes existed nowhere but on screen. The
    /// failure has to throw: the save alert and the retry are what stand between them and nothing.
    func testSavePageThrowsWhenTheManifestIsGone() throws {
        let notebook = try store.createNotebook(title: "Notes")
        let pageId = try XCTUnwrap(notebook.pageIds.first)
        let page = try store.loadPage(notebookId: notebook.notebookId, pageId: pageId)
        try FileManager.default.removeItem(
            at: rootURL.appendingPathComponent("notebooks/\(notebook.notebookId)/manifest.json"))

        XCTAssertThrowsError(try store.savePage(page))
    }

    /// A tombstoned page must not be writable: the file would come back for a page the user
    /// already deleted, invisible to every listing, and the next merge would delete it again.
    func testSavePageRefusesATombstonedPage() throws {
        let notebook = try store.createNotebook(title: "Notes")
        let doomed = try store.addPage(to: notebook.notebookId)
        let held = try store.loadPage(notebookId: notebook.notebookId, pageId: doomed.id)
        try store.deletePage(from: notebook.notebookId, pageId: doomed.id)

        XCTAssertThrowsError(try store.savePage(held))

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: rootURL
                    .appendingPathComponent(
                        "notebooks/\(notebook.notebookId)/pages/\(doomed.id).json").path),
            "the save wrote a page file no listing will ever show")
    }

    /// The same refusal without a tombstone: a page absent from `pageIds` would be written where
    /// only the next upload's orphan cleanup finds it — "written but unreachable" is not a save.
    func testSavePageRefusesAPageTheManifestDoesNotList() throws {
        let notebook = try store.createNotebook(title: "Notes")
        let pageId = try XCTUnwrap(notebook.pageIds.first)
        let page = try store.loadPage(notebookId: notebook.notebookId, pageId: pageId)

        var unlisted = notebook
        unlisted.pageIds = ["some-other-page"]
        try writeManifestDirectly(unlisted)

        XCTAssertThrowsError(try store.savePage(page))
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

    /// A save prunes stroke tombstones past the protocol's 30-day horizon (§6.6, "Pruning") and
    /// keeps everything younger — otherwise a much-erased page's document grows for ever.
    func testSavePrunesTombstonesPastTheHorizonAndKeepsTheRest() throws {
        let notebook = try store.createNotebook(title: "Notes")
        let pageId = try XCTUnwrap(notebook.pageIds.first)
        var seeded = try store.loadPage(notebookId: notebook.notebookId, pageId: pageId)
        seeded.deletedStrokes = [
            CouchTombstone(id: "ancient", deletedAt: "2026-01-01T00:00:00.000Z"),
            CouchTombstone(id: "recent", deletedAt: NotableDate.format(Date())),
            CouchTombstone(id: "unreadable", deletedAt: "not-a-timestamp"),
        ]
        try writePageDirectly(seeded, notebookId: notebook.notebookId)

        let page = try store.loadPage(notebookId: notebook.notebookId, pageId: pageId)
        try store.savePage(page)

        let after = try store.loadPage(notebookId: notebook.notebookId, pageId: pageId)
        XCTAssertEqual(
            after.deletedStrokes.map(\.id).sorted(), ["recent", "unreadable"],
            "past the horizon goes; fresh stays; unparseable cannot be shown old enough to drop")
    }

    /// An image tombstone lands on disk while the page is open — the BOOX erased the image — and
    /// the next autosave must carry it forward and drop the image, not push back a page that
    /// still shows the image and has forgotten it was ever erased.
    func testSaveKeepsAnImageTombstoneThatArrivedWhileThePageWasOpen() throws {
        let notebook = try store.createNotebook(title: "Notes")
        let pageId = try XCTUnwrap(notebook.pageIds.first)
        let held = try store.loadPage(notebookId: notebook.notebookId, pageId: pageId)

        var arrived = held
        arrived.images = []
        arrived.deletedImages = [
            CouchTombstone(id: "img-1", deletedAt: NotableDate.format(Date()))
        ]
        try writePageDirectly(arrived, notebookId: notebook.notebookId)

        var stale = held
        stale.images = [
            ImageDTO(
                id: "img-1", x: 10, y: 10, width: 100, height: 100, uri: nil,
                createdAt: held.createdAt, updatedAt: held.createdAt)
        ]
        try store.savePage(stale)

        let after = try store.loadPage(notebookId: notebook.notebookId, pageId: pageId)
        XCTAssertEqual(after.deletedImages.map(\.id), ["img-1"])
        XCTAssertTrue(after.images.isEmpty, "an erased image must not ride back in on an autosave")
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
