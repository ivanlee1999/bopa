import Combine
import NotableKit
import XCTest
@testable import Bopa

@MainActor
final class ScribePreviewTests: XCTestCase {
    private func fixture() throws -> (NotebookStore, NotebookManifest, PageFile) {
        let name = "scribe-test-\(UUID().uuidString)", root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { try? FileManager.default.removeItem(at: root); UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        let store = NotebookStore(rootURL: root, preferences: defaults), note = try store.createJournalEntry(topic: "Keep")
        var page = try store.loadPage(notebookId: note.notebookId, pageId: note.pageIds[0])
        let points = [NotableStrokePoint(x: 10, y: 10, pressure: 1), NotableStrokePoint(x: 50, y: 30, pressure: 1)]
        page.strokes = [StrokeDTO(id: "ink", size: 3, pen: .ballpen, color: -16777216, top: 10, bottom: 30, left: 10, right: 50,
            pointsData: try SBStrokeCodec.encode(points).base64EncodedString(), createdAt: page.createdAt, updatedAt: page.updatedAt)]
        page = try store.savePage(page)
        return (store, note, page)
    }
    private func result(_ note: NotebookManifest, _ page: PageFile, text: String = "#ServerTag") -> VerifiedScribeText {
        VerifiedScribeText(result: ScribePageText(pageId: page.id, notebookId: note.notebookId, text: text, sourceRev: "1-source",
            sourceFingerprint: "sha256:" + String(repeating: "a", count: 64), pipelineVersion: "scribe-v2:" + String(repeating: "b", count: 64), format: "markdown"),
            ink: ScribeInkSnapshot(page))
    }

    func testRemoteDisplayNeverMutatesInkTypedSourceOrAutomaticTags() async throws {
        let (store, note, page) = try fixture(), index = HandwritingTranscriptIndex()
        var verified = result(note, page)
        verified.result.format = "markdown"
        index.serverTextEnabled = { true }; index.serverReader = { _, _ in verified }
        let pageURL = store.notebookDirURL(note.notebookId).appendingPathComponent("pages/\(page.id).json")
        let pageBytes = try Data(contentsOf: pageURL), metadataURL = store.rootURL.appendingPathComponent(".bopa-organization.json")
        let metadataBytes = try Data(contentsOf: metadataURL)
        let unexpected = expectation(description: "remote text cannot create tags"); unexpected.isInverted = true
        let subscription = store.$journalEntries.sink { if $0[note.notebookId]?.topics["servertag"] != nil { unexpected.fulfill() } }
        await index.requestServer(notebookID: note.notebookId, pageID: page.id, store: store).value
        XCTAssertEqual(index.text(notebookID: note.notebookId, pageID: page.id, fingerprint: "", serverInk: ScribeInkSnapshot(page)), "#ServerTag")
        XCTAssertEqual(index.content(notebookID: note.notebookId, pageID: page.id, fingerprint: "", serverInk: ScribeInkSnapshot(page))?.format, "markdown")
        let observed = await XCTWaiter.fulfillment(of: [unexpected], timeout: 0.6)
        XCTAssertEqual(observed, .completed); subscription.cancel()
        XCTAssertEqual(try Data(contentsOf: pageURL), pageBytes)
        XCTAssertEqual(try Data(contentsOf: metadataURL), metadataBytes)
    }

    func testLocalFallbackOptOutAndEditingFences() async throws {
        let (store, note, page) = try fixture(), index = HandwritingTranscriptIndex(recognize: { _ in "Local fallback" })
        await index.request(notebookID: note.notebookId, pageID: page.id, store: store, delay: .zero).value
        var enabled = true
        index.serverTextEnabled = { enabled }; index.serverReader = { _, _ in nil }
        let fingerprint = HandwritingTranscript.fingerprint(page.strokes), ink = ScribeInkSnapshot(page)
        await index.requestServer(notebookID: note.notebookId, pageID: page.id, store: store).value
        XCTAssertEqual(index.text(notebookID: note.notebookId, pageID: page.id, fingerprint: fingerprint, serverInk: ink), "Local fallback")
        XCTAssertNil(index.content(notebookID: note.notebookId, pageID: page.id, fingerprint: fingerprint, serverInk: ink)?.format)
        let verified = result(note, page, text: "Enhanced")
        index.serverReader = { _, _ in verified }
        await index.requestServer(notebookID: note.notebookId, pageID: page.id, store: store).value
        XCTAssertEqual(index.text(notebookID: note.notebookId, pageID: page.id, fingerprint: fingerprint, serverInk: ink), "Enhanced")
        enabled = false
        XCTAssertEqual(index.text(notebookID: note.notebookId, pageID: page.id, fingerprint: fingerprint, serverInk: ink), "Local fallback")
        index.invalidateServerText(); XCTAssertTrue(index.serverRecords.isEmpty)
        enabled = true
        await index.requestServer(notebookID: note.notebookId, pageID: page.id, store: store).value
        let owner = UUID(); index.setEditing(true, owner: owner, notebookID: note.notebookId)
        await index.requestServer(notebookID: note.notebookId, pageID: page.id, store: store).value
        XCTAssertTrue(index.serverRecords.isEmpty)
        index.setEditing(false, owner: owner, notebookID: note.notebookId)
        await index.requestServer(notebookID: note.notebookId, pageID: page.id, store: store).value
        var resized = page; resized.pageWidth = (page.pageWidth ?? 1080) + 1
        XCTAssertEqual(index.text(notebookID: note.notebookId, pageID: page.id, fingerprint: fingerprint, serverInk: ScribeInkSnapshot(resized)), "Local fallback")
        index.setDrawing(true, owner: owner, notebookID: note.notebookId, pageID: page.id, store: store)
        XCTAssertTrue(index.serverRecords.isEmpty)
    }

    func testLocalChangeDuringFetchAndLateSettingsResponseCannotPublish() async throws {
        let (store, note, original) = try fixture(), index = HandwritingTranscriptIndex()
        index.serverTextEnabled = { true }
        let started = expectation(description: "request started"), gate = ScribePreviewGate()
        index.serverReader = { _, _ in started.fulfill(); return await gate.wait() }
        let job = index.requestServer(notebookID: note.notebookId, pageID: original.id, store: store)
        let observed = await XCTWaiter.fulfillment(of: [started], timeout: 3); XCTAssertEqual(observed, .completed)
        var changed = original, added = original.strokes[0]
        added.id = "new-ink"; changed.strokes.append(added); changed = try store.savePage(changed)
        await gate.resume(result(note, original)); await job.value
        XCTAssertTrue(index.serverRecords.isEmpty)

        let oldStarted = expectation(description: "old endpoint request"), oldGate = ScribePreviewGate()
        index.serverReader = { _, _ in oldStarted.fulfill(); return await oldGate.wait() }
        let oldJob = index.requestServer(notebookID: note.notebookId, pageID: changed.id, store: store)
        let oldObserved = await XCTWaiter.fulfillment(of: [oldStarted], timeout: 3); XCTAssertEqual(oldObserved, .completed)
        index.invalidateServerText()
        let fresh = result(note, changed, text: "New endpoint")
        index.serverReader = { _, _ in fresh }
        await index.requestServer(notebookID: note.notebookId, pageID: changed.id, store: store).value
        await oldGate.resume(result(note, changed, text: "Old endpoint")); await oldJob.value
        XCTAssertEqual(index.serverRecords[HandwritingTranscriptIndex.key(note.notebookId, changed.id)]?.result.text, "New endpoint")
    }

    func testHostRejectsDirtyPagesAndRetiredSettingsWithoutNetwork() async throws {
        let (store, note, page) = try fixture()
        let settings = CouchSettings(serverURL: "https://example.invalid", database: "notes", username: "fixture", password: "fixture", deviceID: "test")
        let state = CouchSyncState(revs: [CouchDocID.page(page.id): "1-source", CouchDocID.notebook(note.notebookId): "1-note"])
        try JSONEncoder().encode(state).write(to: store.rootURL.appendingPathComponent(CouchSyncStack.stateFileName(for: settings)), options: .atomic)
        let host = SyncBackendHost(loadSettings: { settings }, loadBackend: { .couchdb })
        host.serverTextEnabled = { true }
        let verified = result(note, page), calls = ScribeReadCount()
        host.readTranscript = { _, _, _, _, _ in await calls.increment(); return verified }
        host.attach(store: store, coordinator: SyncCoordinator())
        let first = await host.serverTranscript(notebookID: note.notebookId, pageID: page.id)
        XCTAssertNotNil(first)
        let started = expectation(description: "host read started"), gate = ScribePreviewGate()
        host.readTranscript = { _, _, _, _, _ in started.fulfill(); return await gate.wait() }
        let retired = Task { await host.serverTranscript(notebookID: note.notebookId, pageID: page.id) }
        let observed = await XCTWaiter.fulfillment(of: [started], timeout: 3); XCTAssertEqual(observed, .completed)
        host.configure(); await gate.resume(verified)
        let late = await retired.value; XCTAssertNil(late)
        host.readTranscript = { _, _, _, _, _ in await calls.increment(); return verified }
        var edited = page; edited.strokes.removeAll(); _ = try store.savePage(edited)
        let dirty = await host.serverTranscript(notebookID: note.notebookId, pageID: page.id)
        XCTAssertNil(dirty)
        let count = await calls.value; XCTAssertEqual(count, 1)
    }

    func testRetiringPollCannotCancelTheSuccessorOwnerOfACoalescedRead() async throws {
        let (store, note, page) = try fixture(), index = HandwritingTranscriptIndex()
        index.serverTextEnabled = { true }
        let started = expectation(description: "shared read started"), gate = ScribePreviewGate()
        index.serverReader = { _, _ in started.fulfill(); return await gate.wait() }
        let oldOwner = UUID(), newOwner = UUID()
        _ = index.requestServer(notebookID: note.notebookId, pageID: page.id, store: store, owner: oldOwner)
        let observed = await XCTWaiter.fulfillment(of: [started], timeout: 3); XCTAssertEqual(observed, .completed)
        let successor = index.requestServer(notebookID: note.notebookId, pageID: page.id, store: store, owner: newOwner)
        index.cancelServerRequest(notebookID: note.notebookId, pageID: page.id, owner: oldOwner)
        await gate.resume(result(note, page, text: "Current owner")); await successor.value
        XCTAssertEqual(index.serverRecords[HandwritingTranscriptIndex.key(note.notebookId, page.id)]?.result.text, "Current owner")
    }

    func testMarkdownFormatCannotSurviveAnEraseOrLeakIntoLocalOCRFallback() async throws {
        let (store, note, page) = try fixture(), index = HandwritingTranscriptIndex(recognize: { _ in "# Local literal" })
        await index.request(notebookID: note.notebookId, pageID: page.id, store: store, delay: .zero).value
        var verified = result(note, page, text: "# Enhanced heading")
        verified.result.format = "markdown"
        index.serverTextEnabled = { true }; index.serverReader = { _, _ in verified }
        await index.requestServer(notebookID: note.notebookId, pageID: page.id, store: store).value
        XCTAssertTrue(index.content(notebookID: note.notebookId, pageID: page.id, fingerprint: "", serverInk: ScribeInkSnapshot(page))?.isMarkdown == true)
        var erased = page; erased.strokes = []; erased = try store.savePage(erased, baselineStrokeIDs: Set(page.strokes.map(\.id)))
        await index.requestServer(notebookID: note.notebookId, pageID: page.id, store: store).value
        XCTAssertNil(index.content(notebookID: note.notebookId, pageID: page.id, fingerprint: "", serverInk: ScribeInkSnapshot(erased)))
        let fallback = index.content(notebookID: note.notebookId, pageID: page.id,
            fingerprint: HandwritingTranscript.fingerprint(page.strokes), serverInk: ScribeInkSnapshot(erased))
        XCTAssertEqual(fallback?.text, "# Local literal"); XCTAssertFalse(fallback?.isMarkdown ?? true)
    }
    func testAutomaticTitleFollowsCurrentServerContentWithoutChangingSourceOrTags() async throws {
        let (store, note, original) = try fixture(), index = HandwritingTranscriptIndex()
        XCTAssertEqual(note.title, "", "New unnamed captures must remain eligible for content titles")
        index.serverTextEnabled = { true }
        var verified = result(note, original, text: "# **Meal plan**\n- [ ] tea")
        index.serverReader = { _, _ in verified }
        let pageURL = store.notebookDirURL(note.notebookId).appendingPathComponent("pages/\(original.id).json")
        let noteURL = store.notebookDirURL(note.notebookId).appendingPathComponent("manifest.json")
        let pageBytes = try Data(contentsOf: pageURL), noteBytes = try Data(contentsOf: noteURL)
        let organization = store.journalEntries
        await index.prepareTitles(notebooks: [note], store: store)
        XCTAssertEqual(index.notebookTitle(note, store: store), "Meal plan")
        XCTAssertEqual(index.pageTitle(notebookID: note.notebookId, pageID: original.id, store: store), "Meal plan")
        XCTAssertEqual(try Data(contentsOf: pageURL), pageBytes)
        XCTAssertEqual(try Data(contentsOf: noteURL), noteBytes)
        XCTAssertEqual(store.journalEntries, organization)

        var edited = original, stroke = original.strokes[0]
        stroke.id = "new-title-ink"; edited.strokes.append(stroke); edited = try store.savePage(edited)
        XCTAssertEqual(index.notebookTitle(note, store: store), "Untitled", "A page edit immediately invalidates the old display title")
        await index.prepareTitles(notebooks: [note], store: store)
        XCTAssertEqual(index.notebookTitle(note, store: store), "Untitled", "Old server ink cannot title the edited note")
        verified = result(note, edited, text: "# Revised plan")
        await index.prepareTitles(notebooks: [note], store: store)
        XCTAssertEqual(index.notebookTitle(note, store: store), "Revised plan")
        var erased = edited; erased.strokes = []
        _ = try store.savePage(erased, baselineStrokeIDs: Set(edited.strokes.map(\.id)))
        await index.prepareTitles(notebooks: [note], store: store)
        XCTAssertEqual(index.notebookTitle(note, store: store), "Untitled")
        XCTAssertEqual(store.journalEntries, organization)
    }

    func testRecognizedAutomaticTitleSurvivesOfflineRestartAndRejectsEditsOrAnotherSource() async throws {
        let (store, note, page) = try fixture()
        var settings = CouchSettings(serverURL: "https://example.invalid", database: "notes", username: "fixture", password: "fixture", deviceID: "test")
        var state = CouchSyncState(revs: [CouchDocID.page(page.id): "1-source", CouchDocID.notebook(note.notebookId): "1-note"], databaseGeneration: "fixture-generation")
        try JSONEncoder().encode(state).write(to: store.rootURL.appendingPathComponent(CouchSyncStack.stateFileName(for: settings)), options: .atomic)
        var host: SyncBackendHost? = SyncBackendHost(loadSettings: { settings }, loadBackend: { .couchdb })
        host?.serverTextEnabled = { true }
        let verified = result(note, page, text: "# **Offline meeting**")
        host?.readTranscript = { _, _, _, _, _ in verified }
        host?.attach(store: store, coordinator: SyncCoordinator())
        let fetched = await host?.serverTranscript(notebookID: note.notebookId, pageID: page.id)
        XCTAssertNotNil(fetched); host = nil

        let reopened = NotebookStore(rootURL: store.rootURL)
        let restarted = SyncBackendHost(loadSettings: { settings }, loadBackend: { .couchdb })
        restarted.serverTextEnabled = { true }
        restarted.readTranscript = { _, _, _, _, _ in throw URLError(.notConnectedToInternet) }
        restarted.attach(store: reopened, coordinator: SyncCoordinator())
        let index = HandwritingTranscriptIndex(); index.serverTextEnabled = { true }
        index.serverReader = { await restarted.serverTranscript(notebookID: $0, pageID: $1) }
        index.cachedServerTitle = { await restarted.cachedTranscriptTitle(notebookID: $0, pageID: $1) }
        await index.prepareTitles(notebooks: reopened.notebooks, store: reopened)
        XCTAssertEqual(index.notebookTitle(note, store: reopened), "Offline meeting")
        await index.requestServer(notebookID: note.notebookId, pageID: page.id, store: reopened).value
        XCTAssertEqual(index.notebookTitle(note, store: reopened), "Offline meeting", "A failed preview fetch must not discard a still-current offline name")
        XCTAssertTrue(index.serverRecords.isEmpty, "Only a short derived name persists, not a replacement transcript")
        XCTAssertEqual(reopened.manifest(id: note.notebookId)?.title, "")
        state.databaseGeneration = "replacement-generation"
        try JSONEncoder().encode(state).write(to: reopened.rootURL.appendingPathComponent(CouchSyncStack.stateFileName(for: settings)), options: .atomic)
        restarted.configure(); index.invalidateServerText()
        await index.prepareTitles(notebooks: reopened.notebooks, store: reopened)
        XCTAssertEqual(index.notebookTitle(note, store: reopened), "Untitled", "Reusing IDs and revisions in a recreated database must not reuse its old name")
        state.databaseGeneration = "fixture-generation"
        try JSONEncoder().encode(state).write(to: reopened.rootURL.appendingPathComponent(CouchSyncStack.stateFileName(for: settings)), options: .atomic)
        settings.textDatabase = "another_text_source"; restarted.configure(); index.invalidateServerText()
        await index.prepareTitles(notebooks: reopened.notebooks, store: reopened)
        XCTAssertEqual(index.notebookTitle(note, store: reopened), "Untitled")
        settings.textDatabase = "notes_text"; restarted.configure()
        var edited = try reopened.loadPage(notebookId: note.notebookId, pageId: page.id)
        _ = try reopened.savePage(edited)
        let dirty = await restarted.cachedTranscriptTitle(notebookID: note.notebookId, pageID: page.id)
        XCTAssertNil(dirty, "Pending local source writes reject cached names even when ink is identical")
        edited.strokes = []; _ = try reopened.savePage(edited)
        index.invalidateServerText()
        await index.prepareTitles(notebooks: reopened.notebooks, store: reopened)
        XCTAssertEqual(index.notebookTitle(note, store: reopened), "Untitled")
        let cached = await restarted.cachedTranscriptTitle(notebookID: note.notebookId, pageID: page.id)
        XCTAssertNil(cached)
    }

    func testTypedAutomaticTitleWorksOfflineInPageOrderAndManualRenamePinsIt() async throws {
        let (store, note, original) = try fixture(), index = HandwritingTranscriptIndex()
        index.serverTextEnabled = { false }
        let second = try store.addPage(to: note.notebookId)
        var first = original
        first.blocks = try FlowText.replacing(base: [], in: [], with: "# First thought", stamp: first.updatedAt, deviceID: "test")
        _ = try store.savePage(first)
        var later = second
        later.blocks = try FlowText.replacing(base: [], in: [], with: "# Later thought", stamp: later.updatedAt, deviceID: "test")
        _ = try store.savePage(later)
        var manifest = try XCTUnwrap(store.manifest(id: note.notebookId))
        manifest.openPageId = second.id
        await index.prepareTitles(notebooks: [manifest], store: store)
        XCTAssertEqual(index.notebookTitle(manifest, store: store), "First thought", "Open page must not decide the notebook title")
        XCTAssertEqual(store.search("first thought", title: { index.notebookTitle($0, store: store) }).notebooks.map(\.notebookId), [note.notebookId])
        first = try store.loadPage(notebookId: note.notebookId, pageId: first.id)
        let baseline = Set(first.blocks.map(\.id)); first.blocks = []
        first = try store.savePage(first, baselineBlockIDs: baseline)
        await index.prepareTitles(notebooks: [manifest], store: store)
        XCTAssertEqual(index.notebookTitle(manifest, store: store), "Later thought", "Erasing the first page falls through to the next meaningful page")
        try store.renamePage(in: note.notebookId, pageId: first.id, title: "Page chosen")
        await index.prepareTitles(notebooks: [manifest], store: store)
        XCTAssertEqual(index.notebookTitle(manifest, store: store), "Page chosen")
        try store.renameNotebook(id: note.notebookId, title: "My chosen title")
        first = try store.loadPage(notebookId: note.notebookId, pageId: first.id)
        first.blocks = try FlowText.replacing(base: first.blocks.filter { $0.kind == "md" }, in: first.blocks, with: "# Changed content", stamp: first.updatedAt, deviceID: "test")
        _ = try store.savePage(first)
        await index.prepareTitles(notebooks: store.notebooks, store: store)
        XCTAssertEqual(index.notebookTitle(manifest, store: store), "My chosen title", "Even an older UI snapshot must respect the current manual name")
        XCTAssertEqual(store.manifest(id: note.notebookId)?.title, "My chosen title")
        let legacy = try store.createNotebook(title: "Untitled")
        let dated = try store.createNotebook(title: "16 Nov 2026 10:30")
        XCTAssertEqual(index.notebookTitle(legacy, store: store), "Untitled")
        XCTAssertEqual(index.notebookTitle(dated, store: store), "16 Nov 2026 10:30")
        XCTAssertEqual(LibrarySort.notebooks([legacy, manifest], by: .title, descending: false,
            titles: [legacy.notebookId: "Zebra", manifest.notebookId: "Apple"]).map(\.notebookId), [manifest.notebookId, legacy.notebookId])
    }

}

private actor ScribePreviewGate {
    var continuation: CheckedContinuation<VerifiedScribeText?, Never>?
    var released = false
    var buffered: VerifiedScribeText?
    func wait() async -> VerifiedScribeText? {
        if released { return buffered }
        return await withCheckedContinuation { continuation = $0 }
    }
    func resume(_ value: VerifiedScribeText?) {
        released = true; buffered = value
        continuation?.resume(returning: value); continuation = nil
    }
}
private actor ScribeReadCount {
    var value = 0
    func increment() { value += 1 }
}
