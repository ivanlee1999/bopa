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
            sourceFingerprint: "sha256:" + String(repeating: "a", count: 64), pipelineVersion: "scribe-v2:" + String(repeating: "b", count: 64)),
            ink: ScribeInkSnapshot(page))
    }

    func testRemoteDisplayNeverMutatesInkTypedSourceOrAutomaticTags() async throws {
        let (store, note, page) = try fixture(), index = HandwritingTranscriptIndex()
        let verified = result(note, page)
        index.serverTextEnabled = { true }; index.serverReader = { _, _ in verified }
        let pageURL = store.notebookDirURL(note.notebookId).appendingPathComponent("pages/\(page.id).json")
        let pageBytes = try Data(contentsOf: pageURL), metadataURL = store.rootURL.appendingPathComponent(".bopa-organization.json")
        let metadataBytes = try Data(contentsOf: metadataURL)
        let unexpected = expectation(description: "remote text cannot create tags"); unexpected.isInverted = true
        let subscription = store.$journalEntries.sink { if $0[note.notebookId]?.topics["servertag"] != nil { unexpected.fulfill() } }
        await index.requestServer(notebookID: note.notebookId, pageID: page.id, store: store).value
        XCTAssertEqual(index.text(notebookID: note.notebookId, pageID: page.id, fingerprint: "", serverInk: ScribeInkSnapshot(page)), "#ServerTag")
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
