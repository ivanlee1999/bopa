import NotableKit
import XCTest

@testable import Bopa

/// Storing recognized text beside the ink it came from, and deciding when it has gone stale.
@MainActor
final class PageTextStoreTests: XCTestCase {
    private var rootURL: URL!
    private var store: NotebookStore!

    override func setUp() async throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("bopa-pagetext-test-\(UUID().uuidString)")
        store = NotebookStore(rootURL: rootURL)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: rootURL)
    }

    private func text(
        pageId: String,
        body: String = "milk, eggs",
        recognizedClock: String = "2026-08-18T04:00:00.000Z",
        pendingPush: Bool = true
    ) -> PageTextFile {
        PageTextFile(
            pageId: pageId,
            text: body,
            engine: visionEngine,
            language: "en-GB",
            recognizedClock: recognizedClock,
            updatedAt: "2026-08-18T04:00:05.000Z",
            updatedBy: "ipad",
            pendingPush: pendingPush)
    }

    func testTextRoundTripsThroughDisk() throws {
        let notebook = try store.createNotebook(title: "Notes")
        let pageId = notebook.pageIds[0]

        try store.savePageText(text(pageId: pageId), in: notebook.notebookId)

        let loaded = store.loadPageText(notebookId: notebook.notebookId, pageId: pageId)
        XCTAssertEqual(loaded?.text, "milk, eggs")
        XCTAssertEqual(loaded?.engine, visionEngine)
        XCTAssertEqual(loaded?.language, "en-GB")
    }

    func testTextForAPageTheNotebookNoLongerListsIsNotWritten() throws {
        // Otherwise a page deleted mid-recognition leaves a file nothing ever reads or removes.
        let notebook = try store.createNotebook(title: "Notes")

        try store.savePageText(text(pageId: "a-page-that-was-never-here"), in: notebook.notebookId)

        XCTAssertNil(
            store.loadPageText(
                notebookId: notebook.notebookId, pageId: "a-page-that-was-never-here"))
    }

    func testDeletingAPageTakesItsTextWithIt() throws {
        let notebook = try store.createNotebook(title: "Notes")
        let first = notebook.pageIds[0]
        // A notebook refuses to give up its last page, so there has to be a second one.
        _ = try store.addPage(to: notebook.notebookId)
        try store.savePageText(text(pageId: first), in: notebook.notebookId)

        try store.deletePage(from: notebook.notebookId, pageId: first)

        XCTAssertNil(store.loadPageText(notebookId: notebook.notebookId, pageId: first))
    }

    func testPendingTextIsListedUntilItIsMarkedSent() throws {
        let notebook = try store.createNotebook(title: "Notes")
        let pageId = notebook.pageIds[0]
        try store.savePageText(text(pageId: pageId), in: notebook.notebookId)

        XCTAssertEqual(store.pendingPageText(in: notebook.notebookId).count, 1)

        try store.savePageText(
            text(pageId: pageId, pendingPush: false), in: notebook.notebookId)

        XCTAssertTrue(store.pendingPageText(in: notebook.notebookId).isEmpty)
    }

    func testSavingTextDoesNotAnnounceALocalChange() throws {
        // The local-change notification is what triggers recognition. A recognizer whose own
        // writes wake it up recognizes forever.
        let notebook = try store.createNotebook(title: "Notes")
        var announcements = 0
        let observer = NotificationCenter.default.addObserver(
            forName: NotebookStore.didChangeLocallyNotification, object: nil, queue: .main
        ) { _ in announcements += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }

        try store.savePageText(text(pageId: notebook.pageIds[0]), in: notebook.notebookId)

        XCTAssertEqual(announcements, 0)
    }

    func testSearchFindsHandwritingAndNotJustTitles() throws {
        let notebook = try store.createNotebook(title: "Untitled")
        try store.savePageText(
            text(pageId: notebook.pageIds[0], body: "call the plumber"), in: notebook.notebookId)

        XCTAssertEqual(store.notebooksMatchingText("plumber"), [notebook.notebookId])
        XCTAssertEqual(store.notebooksMatchingText("PLUMBER"), [notebook.notebookId])
        XCTAssertTrue(store.notebooksMatchingText("electrician").isEmpty)
    }

    func testSearchIgnoresABlankQuery() throws {
        let notebook = try store.createNotebook(title: "Notes")
        try store.savePageText(text(pageId: notebook.pageIds[0]), in: notebook.notebookId)

        XCTAssertTrue(store.notebooksMatchingText("   ").isEmpty)
    }
}

/// When text counts as describing the ink that is actually on the page.
final class PageTextStalenessTests: XCTestCase {
    private func text(recognizedClock: String) -> PageTextFile {
        PageTextFile(
            pageId: "p", text: "t", engine: "vision", language: nil,
            recognizedClock: recognizedClock, updatedAt: recognizedClock, updatedBy: "ipad")
    }

    func testTextIsStaleOnceThePageMovesPastIt() {
        let text = text(recognizedClock: "2026-08-18T04:00:00.000Z")

        XCTAssertTrue(text.isStale(pageUpdatedAt: "2026-08-18T05:00:00.000Z"))
        XCTAssertFalse(text.isStale(pageUpdatedAt: "2026-08-18T04:00:00.000Z"))
        XCTAssertFalse(text.isStale(pageUpdatedAt: "2026-08-18T03:00:00.000Z"))
    }

    func testAStampWithoutFractionalSecondsStillCompares() {
        // The BOOX prints fractional seconds only when non-zero, so both spellings arrive. Failing
        // to parse one would leave the page stale forever and recognized on a loop.
        let text = text(recognizedClock: "2026-08-18T04:00:00Z")

        XCTAssertFalse(text.isStale(pageUpdatedAt: "2026-08-18T04:00:00.000Z"))
        XCTAssertTrue(text.isStale(pageUpdatedAt: "2026-08-18T04:00:01Z"))
    }

    func testTextWithNoClockAtAllIsStale() {
        // Safe direction: the page reads as needing recognition rather than as permanently current.
        XCTAssertTrue(text(recognizedClock: "").isStale(pageUpdatedAt: "2026-08-18T04:00:00.000Z"))
    }

    func testTextDecodesWhenOptionalFieldsAreAbsent() throws {
        // The same shape arrives from the BOOX; a decode that threw would leave the page
        // permanently unreadable rather than merely unrecognized.
        let json = Data(#"{"pageId":"p","text":"hello"}"#.utf8)

        let decoded = try JSONDecoder().decode(PageTextFile.self, from: json)

        XCTAssertEqual(decoded.text, "hello")
        XCTAssertNil(decoded.language)
        XCTAssertFalse(decoded.pendingPush)
    }
}

/// The guard around publishing, which is what keeps two recognition engines from overwriting each
/// other's work forever.
final class PageTextPublisherTests: XCTestCase {
    private func document(
        text: String = "milk",
        engine: String = "vision",
        language: String? = "en-GB",
        recognizedClock: String = "2026-08-18T04:00:00.000Z",
        updatedAt: String = "2026-08-18T04:00:05.000Z"
    ) -> PageTextDocument {
        PageTextDocument(
            id: "pagetext:p", pageId: "p", notebookId: "b", pageTitle: nil,
            text: text, engine: engine, language: language,
            recognizedClock: recognizedClock, updatedAt: updatedAt, updatedBy: "ipad")
    }

    func testTextDescribingNewerInkWins() {
        let newer = document(recognizedClock: "2026-08-18T09:00:00.000Z")
        let older = document(recognizedClock: "2026-08-18T04:00:00.000Z")

        XCTAssertTrue(PageTextPublisher.supersedes(newer, older))
        XCTAssertFalse(PageTextPublisher.supersedes(older, newer))
    }

    func testTheOtherEnginesReadingOfTheSameInkIsLeftAlone() {
        // The loop this exists to prevent: same ink, different wording, both devices sure the
        // other's copy is wrong. Only a *later* run of the same ink may replace it.
        let theirs = document(text: "Apple's wording", engine: "vision", updatedAt: "2026-08-18T04:00:09.000Z")
        let ours = document(text: "MyScript's wording", engine: "myscript", updatedAt: "2026-08-18T04:00:05.000Z")

        XCTAssertFalse(PageTextPublisher.supersedes(ours, theirs))
        XCTAssertTrue(PageTextPublisher.supersedes(theirs, ours))
    }

    func testUnchangedTextIsNotRepublished() {
        // A write that changes nothing still wakes every reader of the change feed.
        let stored = document(updatedAt: "2026-08-18T04:00:05.000Z")
        let identical = document(updatedAt: "2026-08-18T09:00:00.000Z")

        XCTAssertFalse(PageTextPublisher.supersedes(identical, stored))
    }

    func testAnUnreadableClockLosesToOneThatCanBeRead() {
        // A corrupt document must not become an immovable winner.
        let corrupt = document(recognizedClock: "not a date", updatedAt: "not a date")
        let good = document()

        XCTAssertTrue(PageTextPublisher.supersedes(good, corrupt))
        XCTAssertFalse(PageTextPublisher.supersedes(corrupt, good))
    }

    func testTheDocumentIdIsDerivedFromThePageId() {
        XCTAssertEqual(PageTextPublisher.documentID(pageId: "abc-123"), "pagetext:abc-123")
    }

    func testTheEncodedBodyOmitsTheRevisionWhenThereIsNone() throws {
        // `"_rev": null` reads as a revision claim to CouchDB, which then 409s every create.
        let encoded = try JSONEncoder().encode(document())

        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("_rev"))
    }
}
