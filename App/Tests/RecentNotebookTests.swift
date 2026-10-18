import NotableKit
import XCTest

@testable import Bopa

@MainActor
final class RecentNotebookTests: XCTestCase {
    private var root: URL!
    private var preferences: UserDefaults!
    private var suite: String!
    private var store: NotebookStore!

    override func setUp() async throws {
        suite = "bopa-recents-\(UUID().uuidString)"
        root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        preferences = UserDefaults(suiteName: suite)!
        store = NotebookStore(rootURL: root, preferences: preferences)
    }

    override func tearDown() async throws {
        preferences.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    private func open(_ notebook: NotebookManifest) throws {
        let model = EditorPageModel()
        model.attach(store: store, notebookId: notebook.notebookId)
        XCTAssertTrue(model.open(pageId: try XCTUnwrap(notebook.pageIds.first)))
    }

    func testHistoryTracksSuccessfulOpensAndResumesWithoutSyncingAnEdit() throws {
        let a = try store.createNotebook(title: "A")
        let b = try store.createNotebook(title: "B")
        XCTAssertTrue(store.recentNotebooks.isEmpty, "creation is not a reading event")
        let before = try Data(contentsOf: root.appendingPathComponent("notebooks/\(a.notebookId)/manifest.json"))
        var changed: [String] = []
        store.didChangeDocuments = { changed += $0 }
        try open(a)
        try open(b)
        try open(a)
        XCTAssertEqual(store.recentNotebooks.map(\.notebookId), [a.notebookId, b.notebookId])
        XCTAssertTrue(changed.isEmpty)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("notebooks/\(a.notebookId)/manifest.json")), before)

        let restarted = NotebookStore(rootURL: root, preferences: preferences)
        XCTAssertEqual(restarted.recentNotebooks.map(\.notebookId), [a.notebookId, b.notebookId])
    }

    func testFailedOpenDoesNotEnterTheRecentList() throws {
        let notebook = try store.createNotebook(title: "Broken")
        let pageID = try XCTUnwrap(notebook.pageIds.first)
        try Data("invalid".utf8).write(to: root.appendingPathComponent("notebooks/\(notebook.notebookId)/pages/\(pageID).json"))
        let model = EditorPageModel()
        model.attach(store: store, notebookId: notebook.notebookId)
        XCTAssertFalse(model.open(pageId: pageID))
        XCTAssertNotNil(model.loadError)
        XCTAssertTrue(store.recentNotebooks.isEmpty)
    }

    func testHistoryFollowsRenamesAndHidesTrashedSubtrees() throws {
        let folder = try store.createFolder(title: "Folder")
        let notebook = try store.createNotebook(title: "Before", parentFolderId: folder.id)
        try open(notebook)
        try store.renameNotebook(id: notebook.notebookId, title: "After")
        XCTAssertEqual(store.recentNotebooks.map(\.title), ["After"])
        try store.trashFolder(id: folder.id)
        XCTAssertTrue(store.recentNotebooks.isEmpty)
    }

    func testHistoryIsBoundedAndDoesNotDuplicateAReopenedNotebook() throws {
        var made: [NotebookManifest] = []
        for i in 0..<14 {
            let notebook = try store.createNotebook(title: "Note \(i)")
            made.append(notebook)
            try open(notebook)
        }
        XCTAssertEqual(store.recentNotebooks.map(\.notebookId), made.suffix(12).reversed().map(\.notebookId))
        try open(made[5])
        try open(made[5])
        XCTAssertEqual(store.recentNotebookIDs.count, 12)
        XCTAssertEqual(store.recentNotebookIDs.first, made[5].notebookId)
        XCTAssertEqual(Set(store.recentNotebookIDs).count, 12)
    }
}
