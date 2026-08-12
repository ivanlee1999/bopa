import NotableKit
import XCTest

@testable import Bopa

/// Finding things in the library: search by name, and the order the shelf is arranged in.
@MainActor
final class LibrarySearchTests: XCTestCase {
    private var rootURL: URL!
    private var store: NotebookStore!

    override func setUp() async throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("bopa-search-test-\(UUID().uuidString)")
        store = NotebookStore(rootURL: rootURL)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: rootURL)
    }

    // MARK: Matching

    func testMatchingIsCaseAndDiacriticInsensitiveAndNotAnchored() {
        XCTAssertTrue(LibrarySort.matches(title: "Field Notes", query: "notes"))
        XCTAssertTrue(LibrarySort.matches(title: "Résumé drafts", query: "resume"))
        XCTAssertTrue(LibrarySort.matches(title: "Term 2 Physics", query: "physics"))
        XCTAssertFalse(LibrarySort.matches(title: "Field Notes", query: "chemistry"))
    }

    /// An empty query is not a filter — it is the absence of one.
    func testAnEmptyQueryMatchesEverything() {
        XCTAssertTrue(LibrarySort.matches(title: "Anything", query: ""))
        XCTAssertTrue(LibrarySort.matches(title: "Anything", query: "   "))
    }

    // MARK: Searching the library

    /// The reason to search is not knowing where the thing is, so results come from anywhere.
    func testSearchReachesIntoFolders() throws {
        let folder = try store.createFolder(title: "Term 2")
        let buried = try store.createNotebook(title: "Physics", parentFolderId: folder.id)
        _ = try store.createNotebook(title: "Chemistry")

        let found = store.search("phys")

        XCTAssertEqual(found.notebooks.map(\.notebookId), [buried.notebookId])
    }

    func testSearchFindsFoldersToo() throws {
        let folder = try store.createFolder(title: "Term 2")
        _ = try store.createFolder(title: "Archive")

        XCTAssertEqual(store.search("term").folders.map(\.id), [folder.id])
    }

    func testTrashedItemsAreNotFound() throws {
        let notebook = try store.createNotebook(title: "Physics")
        try store.trashNotebook(id: notebook.notebookId)

        XCTAssertTrue(store.search("phys").notebooks.isEmpty)
    }

    /// A notebook inside a trashed folder is in the Trash too, even though nothing marked it.
    func testItemsInsideATrashedFolderAreNotFound() throws {
        let folder = try store.createFolder(title: "Term 2")
        _ = try store.createNotebook(title: "Physics", parentFolderId: folder.id)
        try store.trashFolder(id: folder.id)

        XCTAssertTrue(store.search("phys").notebooks.isEmpty)
        XCTAssertTrue(store.search("term").folders.isEmpty)
    }

    /// `folders.json` is merged data and can come back with a chain that loops; searching it must
    /// settle rather than spin.
    func testSearchSurvivesAFolderCycle() throws {
        let a = try store.createFolder(title: "A")
        let b = try store.createFolder(title: "B", parentFolderId: a.id)
        let file = FoldersFile(
            folders: [
                FolderDTO(
                    id: a.id, title: "A", parentFolderId: b.id,
                    createdAt: a.createdAt, updatedAt: a.updatedAt),
                FolderDTO(
                    id: b.id, title: "B", parentFolderId: a.id,
                    createdAt: b.createdAt, updatedAt: b.updatedAt),
            ],
            serverTimestamp: NotableDate.format(Date()))
        try JSONEncoder().encode(file)
            .write(to: rootURL.appendingPathComponent("folders.json"))
        store.refresh()

        XCTAssertTrue(store.search("A").folders.isEmpty, "a folder in a loop reaches no root")
    }

    // MARK: Breadcrumbs

    func testBreadcrumbReadsOutermostFirst() throws {
        let outer = try store.createFolder(title: "Term 2")
        let inner = try store.createFolder(title: "Week 1", parentFolderId: outer.id)

        XCTAssertEqual(store.breadcrumb(of: inner.id).map(\.title), ["Term 2", "Week 1"])
        XCTAssertTrue(store.breadcrumb(of: nil).isEmpty)
    }

    // MARK: Sorting

    func testTitleSortIsLocaleAwareAndReversible() {
        let notebooks = [
            manifest(id: "1", title: "zebra"),
            manifest(id: "2", title: "Éclair"),
            manifest(id: "3", title: "apple"),
        ]

        XCTAssertEqual(
            LibrarySort.notebooks(notebooks, by: .title, descending: false).map(\.title),
            ["apple", "Éclair", "zebra"])
        XCTAssertEqual(
            LibrarySort.notebooks(notebooks, by: .title, descending: true).map(\.title),
            ["zebra", "Éclair", "apple"])
    }

    func testDateSortsUseTheirOwnField() {
        let notebooks = [
            manifest(id: "1", title: "old edit new", created: "2020", updated: "2024"),
            manifest(id: "2", title: "new edit old", created: "2023", updated: "2021"),
        ]

        XCTAssertEqual(
            LibrarySort.notebooks(notebooks, by: .updated, descending: true).map(\.notebookId),
            ["1", "2"])
        XCTAssertEqual(
            LibrarySort.notebooks(notebooks, by: .created, descending: true).map(\.notebookId),
            ["2", "1"])
    }

    /// Two notebooks edited in the same second must not swap places between launches.
    func testEqualTimestampsStillOrderStably() {
        let notebooks = [
            manifest(id: "b", title: "Beta", updated: "2024"),
            manifest(id: "a", title: "Alpha", updated: "2024"),
        ]

        XCTAssertEqual(
            LibrarySort.notebooks(notebooks, by: .updated, descending: false).map(\.title),
            ["Alpha", "Beta"])
    }

    private func manifest(
        id: String, title: String, created: String = "2024", updated: String = "2024"
    ) -> NotebookManifest {
        NotebookManifest(
            notebookId: id, title: title, pageIds: [],
            createdAt: created, updatedAt: updated, serverTimestamp: updated)
    }
}
