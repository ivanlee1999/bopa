import Foundation
import NotableKit
import XCTest
@testable import Bopa

@MainActor
final class JournalStoreTests: XCTestCase {
    private var root: URL!
    private var store: NotebookStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = NotebookStore(rootURL: root)
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: root)
    }

    func testSeveralNotesInOneDayKeepTheirOwnInkAndMetadata() throws {
        let first = try store.createJournalEntry(topic: "Product")
        let second = try store.createJournalEntry(topic: "Personal")
        XCTAssertNotEqual(first.notebookId, second.notebookId)
        XCTAssertNotEqual(first.pageIds, second.pageIds)
        XCTAssertEqual(store.journalEntries[first.notebookId]?.date, store.journalEntries[second.notebookId]?.date)
        XCTAssertEqual(store.journalEntries[first.notebookId]?.visibleTopics, ["Product"])
        XCTAssertEqual(store.journalEntries[second.notebookId]?.visibleTopics, ["Personal"])
        XCTAssertNotNil(try store.loadPage(notebookId: first.notebookId, pageId: first.pageIds[0]))
        XCTAssertNotNil(try store.loadPage(notebookId: second.notebookId, pageId: second.pageIds[0]))
    }

    func testTopicsDoNotRewriteInkAndSurviveTrashRestoreAndRestart() throws {
        let note = try store.createJournalEntry(topic: "Product")
        let manifestURL = store.notebookDirURL(note.notebookId).appendingPathComponent("manifest.json")
        let pageURL = store.notebookDirURL(note.notebookId).appendingPathComponent("pages/\(note.pageIds[0]).json")
        let manifest = try Data(contentsOf: manifestURL), ink = try Data(contentsOf: pageURL)
        let captureDate = store.journalEntries[note.notebookId]?.date
        try store.setJournalTopic(notebookID: note.notebookId, name: "Alex", present: true)
        XCTAssertEqual(try Data(contentsOf: manifestURL), manifest)
        XCTAssertEqual(try Data(contentsOf: pageURL), ink)
        try store.trashNotebook(id: note.notebookId)
        XCTAssertEqual(store.journalEntries[note.notebookId]?.visibleTopics, ["Alex", "Product"])
        try store.restoreNotebook(id: note.notebookId)
        store = NotebookStore(rootURL: root)
        XCTAssertEqual(store.journalEntries[note.notebookId]?.date, captureDate)
        XCTAssertEqual(store.journalEntries[note.notebookId]?.visibleTopics, ["Alex", "Product"])
    }

    func testOrganizationArrivingBeforeNotebookIsRetained() throws {
        let remote = JournalOrganization(notebookId: "pending", date: "2026-11-11", createdAt: 1,
            topics: ["product": JournalTopic(name: "Product", present: true, counter: 1, writer: "remote")])
        _ = try XCTUnwrap(store.organization).merge(remote)
        store.refreshJournal()
        XCTAssertEqual(store.journalEntries["pending"], remote)
        let note = try store.createNotebook(title: "Arrived later", notebookId: "pending")
        XCTAssertEqual(store.journalEntries[note.notebookId], remote)
    }

    func testUnreadableOrganizationDoesNotOverwriteSavedInkOrMetadata() throws {
        let note = try store.createNotebook(title: "Keep this")
        let url = root.appendingPathComponent(".bopa-organization.json")
        let broken = Data("unreadable".utf8)
        try broken.write(to: url)
        store = NotebookStore(rootURL: root)
        XCTAssertNotNil(store.journalError)
        XCTAssertNotNil(store.manifest(id: note.notebookId))
        XCTAssertThrowsError(try store.createJournalEntry())
        XCTAssertEqual(try Data(contentsOf: url), broken)
    }
}
