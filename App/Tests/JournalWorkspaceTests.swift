import NotableKit
import Combine
import PencilKit
import UIKit
import XCTest
@testable import Bopa

@MainActor
final class JournalWorkspaceTests: XCTestCase {
    func testMonthCalendarIncludesLeapDayAndEveryDateAcrossDST() throws {
        for (month, count) in [("2024-02-12", 29), ("2026-03-12", 31), ("2026-11-12", 30)] {
            let dates = JournalDate.monthDays(try XCTUnwrap(JournalDate.date(month))).compactMap { $0 }
            let keys = dates.map(JournalDate.key)
            XCTAssertEqual(keys.count, count)
            XCTAssertEqual(Set(keys).count, count)
            XCTAssertEqual(keys.first, String(month.prefix(7)) + "-01")
            XCTAssertEqual(keys.last, String(month.prefix(7)) + String(format: "-%02d", count))
        }
    }

    func testFavoritesKeepExactCombinationAndOrderAcrossRelaunch() throws {
        let name = "favorite-test-\(UUID().uuidString)", defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let selection = ToolSelection(defaults: defaults)
        selection.select(.fountain); selection.select(inkIndex: 8); selection.select(width: .broad)
        selection.pinCurrent()
        let favorite = try XCTUnwrap(selection.favorites.last)
        let count = selection.favorites.count
        selection.pinCurrent(); XCTAssertEqual(selection.favorites.count, count)
        selection.select(.marker); selection.select(inkIndex: 1); selection.select(width: .fine)
        let revision = selection.revision
        selection.apply(favorite)
        XCTAssertEqual(selection.revision, revision + 1)
        XCTAssertEqual(selection.kind, .fountain); XCTAssertEqual(selection.ink.id, 8); XCTAssertEqual(selection.width, .broad)
        XCTAssertEqual((try XCTUnwrap(selection.pkTool as? PKInkingTool)).width, 12, accuracy: 0.001)
        selection.moveFavorites(from: IndexSet(integer: count - 1), to: 0)
        let reopened = ToolSelection(defaults: defaults)
        XCTAssertEqual(reopened.favorites.first, favorite)
        reopened.apply(favorite)
        let actualTool = try XCTUnwrap(reopened.pkTool)
        reopened.select(width: .fine); reopened.adopt(actualTool)
        XCTAssertEqual(reopened.width, .broad)
        XCTAssertEqual(reopened.selectedFavoriteID, favorite.id)
        reopened.deleteFavorites(at: IndexSet(integer: 0))
        XCTAssertEqual(reopened.kind, .fountain); XCTAssertEqual(reopened.ink.id, 8); XCTAssertEqual(reopened.width, .broad)
        XCTAssertEqual(Modernist.inks.map(\.id), Array(0..<12), "reordering favorites never renumbers the existing palette")
    }

    func testRenamePreservesJournalMetadataInkAndTypedSource() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rename-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NotebookStore(rootURL: root), note = try store.createJournalEntry(topic: "Research")
        var page = try store.loadPage(notebookId: note.notebookId, pageId: note.pageIds[0])
        page.strokes = [try stroke()]
        page.blocks = [CouchBlock(id: "text", kind: "md", text: "Canonical source 👋", createdAt: page.createdAt, updatedAt: page.updatedAt, deviceId: "test")]
        page = try store.savePage(page)
        let journal = store.journalEntries[note.notebookId]
        try store.renameNotebook(id: note.notebookId, title: "A new title")
        try store.renamePage(in: note.notebookId, pageId: page.id, title: "First thought")
        let after = try store.loadPage(notebookId: note.notebookId, pageId: page.id)
        XCTAssertEqual(after.strokes, page.strokes); XCTAssertEqual(after.blocks, page.blocks)
        XCTAssertEqual(store.journalEntries[note.notebookId], journal)
        XCTAssertEqual(store.manifest(id: note.notebookId)?.pageIds, note.pageIds)
        XCTAssertEqual(after.title, "First thought")
        try store.renamePage(in: note.notebookId, pageId: page.id, title: nil)
        _ = try store.savePage(after)
        XCTAssertNil(try store.loadPage(notebookId: note.notebookId, pageId: page.id).title,
                     "a stale editor autosave must preserve an explicitly cleared title")
    }

    func testRenameUsesFreshManifestAndRejectsRemovedOrTrashedContext() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rename-context-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NotebookStore(rootURL: root), note = try store.createNotebook(title: "Original")
        let manifestURL = store.notebookDirURL(note.notebookId).appendingPathComponent("manifest.json")
        var incoming = note; incoming.pageIds.append("remote-page")
        try JSONEncoder().encode(incoming).write(to: manifestURL, options: .atomic)
        try store.renameNotebook(id: note.notebookId, title: "New title")
        XCTAssertEqual(store.manifest(id: note.notebookId)?.pageIds, incoming.pageIds)
        let pageID = note.pageIds[0]
        let pageURL = store.notebookDirURL(note.notebookId).appendingPathComponent("pages/\(pageID).json")
        let before = try Data(contentsOf: pageURL)
        incoming = try XCTUnwrap(store.manifest(id: note.notebookId)); incoming.pageIds.removeAll { $0 == pageID }
        incoming.deletedPageIds.append(CouchTombstone(id: pageID, deletedAt: SyncClock.shared.stamp()))
        try JSONEncoder().encode(incoming).write(to: manifestURL, options: .atomic)
        XCTAssertThrowsError(try store.renamePage(in: note.notebookId, pageId: pageID, title: "Must not write"))
        XCTAssertEqual(try Data(contentsOf: pageURL), before)
        try store.trashNotebook(id: note.notebookId)
        XCTAssertThrowsError(try store.renameNotebook(id: note.notebookId, title: "Must not revive"))
    }

    func testTextPreviewKeepsImagesAndPositionedTextAlongsideTranscript() throws {
        var page = PageFile(id: "page", notebookId: "note", createdAt: "2026-11-12T12:00:00Z", updatedAt: "2026-11-12T12:00:00Z")
        XCTAssertFalse(FlowCanvasPreview.hasNonInkContent(page))
        page.blocks = [CouchBlock(id: "annotation", kind: "md", text: "Keep this", x: 10, y: 20, width: 200, height: 40, createdAt: page.createdAt, updatedAt: page.updatedAt, deviceId: "test")]
        XCTAssertTrue(FlowCanvasPreview.hasNonInkContent(page))
        page.blocks = []; page.images = [ImageDTO(id: "photo", x: 0, y: 0, width: 100, height: 100, uri: "photo.jpg", createdAt: page.createdAt, updatedAt: page.updatedAt)]
        XCTAssertTrue(FlowCanvasPreview.hasNonInkContent(page))
    }

    func testAutomaticRecognitionWaitsUntilAllLiveDrawingEnds() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("recognition-contact-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NotebookStore(rootURL: root), note = try store.createNotebook(title: "Ink")
        let pageID = note.pageIds[0]
        var page = try store.loadPage(notebookId: note.notebookId, pageId: pageID)
        page.strokes = [try stroke()]; _ = try store.savePage(page)
        let index = HandwritingTranscriptIndex { _ in "After contact" }, owner = UUID()
        // Contact on a different page still protects the native drawing thread from raster work.
        index.setDrawing(true, owner: owner, notebookID: "other-note", pageID: "other-page")
        await index.request(notebookID: note.notebookId, pageID: pageID, store: store, delay: .zero).value
        XCTAssertTrue(index.records.isEmpty)
        let finished = expectation(description: "deferred recognition resumed")
        let observation = index.$records.sink { records in
            if records[HandwritingTranscriptIndex.key(note.notebookId, pageID)] != nil { finished.fulfill() }
        }
        index.setDrawing(false, owner: owner, notebookID: "other-note", pageID: nil)
        let completion = await XCTWaiter.fulfillment(of: [finished], timeout: 3)
        XCTAssertEqual(completion, .completed)
        withExtendedLifetime(observation) {}
        XCTAssertEqual(index.text(notebookID: note.notebookId, pageID: pageID, fingerprint: HandwritingTranscript.fingerprint(page.strokes)), "After contact")
    }

    func testRecognitionRejectsChangedInkAndNeverWritesCanonicalPage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("transcript-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NotebookStore(rootURL: root), note = try store.createNotebook(title: "Ink")
        let pageID = note.pageIds[0]
        var page = try store.loadPage(notebookId: note.notebookId, pageId: pageID)
        page.strokes = [try stroke()]; _ = try store.savePage(page)
        let started = expectation(description: "local recognizer started")
        let stream = AsyncStream<String>.makeStream()
        let index = HandwritingTranscriptIndex { _ in
            started.fulfill()
            for await value in stream.stream { return value }
            return ""
        }
        let job = index.request(notebookID: note.notebookId, pageID: pageID, store: store, delay: .zero)
        let result = await XCTWaiter.fulfillment(of: [started], timeout: 3)
        XCTAssertEqual(result, .completed)
        page.strokes.append(try stroke(id: "new")); _ = try store.savePage(page)
        stream.continuation.yield("Outdated transcript"); stream.continuation.finish()
        await job.value
        XCTAssertNil(index.text(notebookID: note.notebookId, pageID: pageID, fingerprint: HandwritingTranscript.fingerprint(page.strokes)))

        let fresh = HandwritingTranscriptIndex { _ in "Current transcript" }
        let url = store.notebookDirURL(note.notebookId).appendingPathComponent("pages/\(pageID).json")
        let before = try Data(contentsOf: url)
        await fresh.request(notebookID: note.notebookId, pageID: pageID, store: store, delay: .zero).value
        XCTAssertEqual(fresh.text(notebookID: note.notebookId, pageID: pageID, fingerprint: HandwritingTranscript.fingerprint(page.strokes)), "Current transcript")
        XCTAssertEqual(try Data(contentsOf: url), before)
        let reopened = HandwritingTranscriptIndex { _ in "Should use the cache" }
        await reopened.request(notebookID: note.notebookId, pageID: pageID, store: store, delay: .zero).value
        XCTAssertEqual(reopened.records, fresh.records)
    }

    func testVisionPerformsLocalImageRecognition() async throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 420, height: 100)).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 420, height: 100))
            ("LOCAL NOTES" as NSString).draw(at: CGPoint(x: 24, y: 25), withAttributes: [.font: UIFont.systemFont(ofSize: 36), .foregroundColor: UIColor.black])
        }
        let text = try await HandwritingTextReader.shared.recognize(try XCTUnwrap(image.pngData()))
        XCTAssertTrue(text.uppercased().contains("LOCAL NOTES"), text)
    }

    func testTagManagerUpdatesTrashAndPreservesNotesAndPendingMetadata() throws {
        let store = try tagStore(), one = try store.createJournalEntry(topic: "Old")
        let two = try store.createNotebook(title: "Trash note")
        try store.setJournalTopic(notebookID: two.notebookId, name: "Old", present: true)
        try store.setJournalTopic(notebookID: two.notebookId, name: "TARGET", present: true)
        try store.setJournalTopic(notebookID: one.notebookId, name: "Keep", present: true)
        try store.organization?.setTopic(notebookID: "pending", name: "Old", present: true, createdAt: 0)
        try store.trashNotebook(id: two.notebookId)
        let before = store.journalEntries
        let pageURL = store.notebookDirURL(one.notebookId).appendingPathComponent("pages/\(one.pageIds[0]).json")
        let pageBytes = try Data(contentsOf: pageURL)
        try store.renameJournalTopic(key: "old", to: "Target")
        XCTAssertEqual(store.journalEntries[two.notebookId]?.topics["target"], before[two.notebookId]?.topics["target"])
        XCTAssertEqual(store.journalEntries[one.notebookId]?.topics["target"]?.name, "TARGET")
        XCTAssertEqual(store.journalEntries[one.notebookId]?.topics["keep"], before[one.notebookId]?.topics["keep"])
        XCTAssertEqual(store.journalEntries[one.notebookId]?.date, before[one.notebookId]?.date)
        XCTAssertEqual(store.journalEntries[one.notebookId]?.createdAt, before[one.notebookId]?.createdAt)
        try store.removeJournalTopic(key: "target")
        XCTAssertFalse(try XCTUnwrap(store.journalEntries[two.notebookId]?.topics["target"]).present)
        XCTAssertTrue(try XCTUnwrap(store.organization?.entries()["pending"]?.topics["old"]).present)
        XCTAssertEqual(try Data(contentsOf: pageURL), pageBytes)
        XCTAssertNotNil(store.manifest(id: one.notebookId)); XCTAssertNotNil(store.manifest(id: two.notebookId))
        try store.restoreNotebook(id: two.notebookId)
        XCTAssertFalse(try XCTUnwrap(store.journalEntries[two.notebookId]?.topics["target"]).present)
    }

    func testNoteTagAndJournalTrashActionsRejectFreshMissingOrTrashedAncestors() throws {
        let store = try tagStore(), folder = try store.createFolder(title: "Folder")
        let note = try store.createNotebook(title: "Note")
        try store.moveNotebook(id: note.notebookId, toFolder: folder.id)
        let journalBefore = try Data(contentsOf: store.rootURL.appendingPathComponent(".bopa-organization.json"))
        try LocalTrash.addFolder(folder.id, at: Date(), root: store.rootURL)
        XCTAssertThrowsError(try store.setJournalTopic(notebookID: note.notebookId, name: "Wrong", present: true))
        XCTAssertThrowsError(try store.trashJournalNotebook(id: note.notebookId))
        XCTAssertFalse(LocalTrash.load(root: store.rootURL).notebookIDs.contains(note.notebookId))
        XCTAssertEqual(try Data(contentsOf: store.rootURL.appendingPathComponent(".bopa-organization.json")), journalBefore)
        try FileManager.default.removeItem(at: store.notebookDirURL(note.notebookId).appendingPathComponent("manifest.json"))
        XCTAssertThrowsError(try store.setJournalTopic(notebookID: note.notebookId, name: "Wrong", present: true))
    }

    func testLocalTypedSaveAutomaticallyAddsTagsWithoutChangingSourceOrRevivingRemoval() async throws {
        let store = try tagStore(), catalog = try store.createNotebook(title: "Catalog")
        try store.setJournalTopic(notebookID: catalog.notebookId, name: "Project", present: true)
        let note = try store.createJournalEntry(), baseline = store.journalEntries[note.notebookId]
        let applied = expectation(description: "durable save assigns tags")
        let subscription = store.$journalEntries.sink { entries in
            if entries[note.notebookId]?.topics["focus"]?.present == true && entries[note.notebookId]?.topics["project"]?.present == true { applied.fulfill() }
        }
        var page = try store.loadPage(notebookId: note.notebookId, pageId: note.pageIds[0])
        page.blocks = [CouchBlock(id: "body", kind: "md", text: "Project notes #Focus", createdAt: page.createdAt, updatedAt: page.updatedAt, deviceId: "local")]
        page.strokes = [try stroke()]
        page = try store.savePage(page)
        let pageURL = store.notebookDirURL(note.notebookId).appendingPathComponent("pages/\(page.id).json")
        let savedBytes = try Data(contentsOf: pageURL)
        let result = await XCTWaiter.fulfillment(of: [applied], timeout: 3)
        XCTAssertEqual(result, .completed); subscription.cancel()
        XCTAssertEqual(try Data(contentsOf: pageURL), savedBytes)
        XCTAssertEqual(store.journalEntries[note.notebookId]?.date, baseline?.date)
        XCTAssertEqual(store.journalEntries[note.notebookId]?.createdAt, baseline?.createdAt)
        try store.setJournalTopic(notebookID: note.notebookId, name: "Focus", present: false)
        let removed = store.journalEntries[note.notebookId]?.topics["focus"]
        page.blocks[0].text = "Project notes #Focus again"
        _ = try store.savePage(page)
        await store.applyAutomaticTopics(notebookID: note.notebookId, pageID: page.id, delay: .zero).value
        XCTAssertEqual(store.journalEntries[note.notebookId]?.topics["focus"], removed)
    }

    func testDelayedAutomaticTagsRejectRemoteTextAndTitleBeforeDebounce() async throws {
        let store = try tagStore(), note = try store.createJournalEntry()
        var page = try store.loadPage(notebookId: note.notebookId, pageId: note.pageIds[0])
        page.blocks = [CouchBlock(id: "body", kind: "md", text: "#Local", createdAt: page.createdAt, updatedAt: page.updatedAt, deviceId: "local")]
        page = try store.savePage(page)
        let pending = store.applyAutomaticTopics(notebookID: note.notebookId, pageID: page.id, delay: .milliseconds(20))
        page.blocks[0].text = "#Remote"
        try JSONEncoder().encode(page).write(to: store.notebookDirURL(note.notebookId).appendingPathComponent("pages/\(page.id).json"), options: .atomic)
        await pending.value
        XCTAssertTrue(store.journalEntries[note.notebookId]?.topics.isEmpty == true)
        try store.renameNotebook(id: note.notebookId, title: "#LocalTitle")
        let titleTask = store.applyAutomaticTopics(notebookID: note.notebookId, delay: .milliseconds(20))
        var incoming = try XCTUnwrap(store.manifest(id: note.notebookId)); incoming.title = "#RemoteTitle"
        try JSONEncoder().encode(incoming).write(to: store.notebookDirURL(note.notebookId).appendingPathComponent("manifest.json"), options: .atomic)
        await titleTask.value
        XCTAssertTrue(store.journalEntries[note.notebookId]?.topics.isEmpty == true)
    }

    func testOnlyFreshRecognitionOfLocallySavedInkCanAssignTopics() async throws {
        let store = try tagStore(), note = try store.createJournalEntry(), pageID = note.pageIds[0]
        var page = try store.loadPage(notebookId: note.notebookId, pageId: pageID)
        page.strokes = [try stroke()]; page = try store.savePage(page)
        let fingerprint = HandwritingTranscript.fingerprint(page.strokes)
        let updated = expectation(description: "fresh local recognition tags ink")
        let subscription = store.$journalEntries.sink { entries in
            if entries[note.notebookId]?.topics["inktag"]?.present == true { updated.fulfill() }
        }
        let index = HandwritingTranscriptIndex(recognize: { _ in "#InkTag" })
        await index.request(notebookID: note.notebookId, pageID: pageID, store: store, delay: .zero).value
        let result = await XCTWaiter.fulfillment(of: [updated], timeout: 3)
        XCTAssertEqual(result, .completed); subscription.cancel()
        let pageURL = store.notebookDirURL(note.notebookId).appendingPathComponent("pages/\(pageID).json")
        let saved = try Data(contentsOf: pageURL)
        let reopened = NotebookStore(rootURL: store.rootURL, preferences: try XCTUnwrap(UserDefaults(suiteName: store.rootURL.lastPathComponent)))
        let previewOnly = HandwritingTranscriptIndex(recognize: { _ in "#Wrong" })
        await previewOnly.request(notebookID: note.notebookId, pageID: pageID, store: reopened, delay: .zero).value
        XCTAssertNil(reopened.journalEntries[note.notebookId]?.topics["wrong"])
        try FileManager.default.removeItem(at: store.rootURL.appendingPathComponent(".bopa-recognition/\(note.notebookId)/\(pageID).json"))
        let uncachedPreview = HandwritingTranscriptIndex(recognize: { _ in "#WrongPreview" })
        await uncachedPreview.request(notebookID: note.notebookId, pageID: pageID, store: reopened, delay: .zero).value
        XCTAssertNil(reopened.journalEntries[note.notebookId]?.topics["wrongpreview"])
        page.strokes.append(try stroke(id: "new")); page = try store.savePage(page)
        await store.applyAutomaticTopics(notebookID: note.notebookId, pageID: pageID, recognizedText: "#Stale", inkFingerprint: fingerprint, delay: .zero).value
        XCTAssertNil(store.journalEntries[note.notebookId]?.topics["stale"])
        try store.trashNotebook(id: note.notebookId)
        await store.applyAutomaticTopics(notebookID: note.notebookId, pageID: pageID, recognizedText: "#Trash", inkFingerprint: HandwritingTranscript.fingerprint(page.strokes), delay: .zero).value
        XCTAssertNil(store.journalEntries[note.notebookId]?.topics["trash"])
        XCTAssertEqual(try JSONDecoder().decode(PageFile.self, from: saved).strokes.count, 1)
        XCTAssertEqual(try store.loadPage(notebookId: note.notebookId, pageId: pageID).strokes, page.strokes)
    }

    func testAutomaticAssignmentDefersDuringPenContactAndCanBeDisabled() async throws {
        let store = try tagStore(), note = try store.createNotebook(title: "Plain"), owner = UUID()
        store.setAutomaticTagDrawing(true, owner: owner)
        try store.renameNotebook(id: note.notebookId, title: "#AfterPen")
        XCTAssertNil(store.journalEntries[note.notebookId])
        let updated = expectation(description: "assign after pen up")
        let subscription = store.$journalEntries.sink { entries in
            if entries[note.notebookId]?.topics["afterpen"]?.present == true { updated.fulfill() }
        }
        store.setAutomaticTagDrawing(false, owner: owner)
        let result = await XCTWaiter.fulfillment(of: [updated], timeout: 3)
        XCTAssertEqual(result, .completed); subscription.cancel()
        let disabled = try tagStore(automatic: false), plain = try disabled.createNotebook(title: "Plain")
        try disabled.renameNotebook(id: plain.notebookId, title: "#NotAssigned")
        await disabled.applyAutomaticTopics(notebookID: plain.notebookId, delay: .zero).value
        XCTAssertNil(disabled.journalEntries[plain.notebookId])
    }

    func testLocalInkAndFreshOCRDoNotClassifyUntouchedRemoteTypedBlocks() async throws {
        let store = try tagStore(), note = try store.createJournalEntry(), pageID = note.pageIds[0]
        var page = try store.loadPage(notebookId: note.notebookId, pageId: pageID)
        page.blocks = [CouchBlock(id: "remote", kind: "md", text: "#Remote", createdAt: page.createdAt, updatedAt: page.updatedAt, deviceId: "peer")]
        try JSONEncoder().encode(page).write(to: store.notebookDirURL(note.notebookId).appendingPathComponent("pages/\(pageID).json"), options: .atomic)
        let noRemoteTag = expectation(description: "ink save does not classify remote typing"); noRemoteTag.isInverted = true
        let subscription = store.$journalEntries.sink { entries in
            if entries[note.notebookId]?.topics["remote"] != nil { noRemoteTag.fulfill() }
        }
        page.strokes = [try stroke()]; _ = try store.savePage(page)
        let result = await XCTWaiter.fulfillment(of: [noRemoteTag], timeout: 0.7)
        XCTAssertEqual(result, .completed); subscription.cancel()
        await store.applyAutomaticTopics(notebookID: note.notebookId, pageID: pageID,
            recognizedText: "#LocalInk", inkFingerprint: HandwritingTranscript.fingerprint(page.strokes), delay: .zero).value
        XCTAssertTrue(store.journalEntries[note.notebookId]?.topics["localink"]?.present == true)
        XCTAssertNil(store.journalEntries[note.notebookId]?.topics["remote"])
    }

    func testCachedTranscriptNeedsANewLocalInkEditAndNeverRetroactivelyTagsWhenEnabled() async throws {
        let store = try tagStore(automatic: false), note = try store.createJournalEntry(), pageID = note.pageIds[0]
        var page = try store.loadPage(notebookId: note.notebookId, pageId: pageID)
        page.strokes = [try stroke()]; page = try store.savePage(page)
        let index = HandwritingTranscriptIndex(recognize: { _ in "#CachedUndo" })
        await index.request(notebookID: note.notebookId, pageID: pageID, store: store, delay: .zero).value
        store.setAutomaticTagsEnabled(true)
        await index.request(notebookID: note.notebookId, pageID: pageID, store: store, delay: .zero).value
        XCTAssertNil(store.journalEntries[note.notebookId]?.topics["cachedundo"])
        page.strokes.append(try stroke(id: "temporary")); page = try store.savePage(page)
        page.strokes.removeLast(); page = try store.savePage(page)
        let applied = expectation(description: "local undo can reuse its exact cached transcript")
        let subscription = store.$journalEntries.sink { entries in
            if entries[note.notebookId]?.topics["cachedundo"]?.present == true { applied.fulfill() }
        }
        let cached = HandwritingTranscriptIndex(recognize: { _ in XCTFail("Expected existing transcript cache"); return "#Unexpected" })
        await cached.request(notebookID: note.notebookId, pageID: pageID, store: store, delay: .zero).value
        let result = await XCTWaiter.fulfillment(of: [applied], timeout: 3)
        XCTAssertEqual(result, .completed); subscription.cancel()
        XCTAssertEqual(try store.loadPage(notebookId: note.notebookId, pageId: pageID).strokes, page.strokes)
    }

    func testGlobalTagRemovalCancelsDeferredAssignmentsAndInkButAllowsFutureEdits() async throws {
        let store = try tagStore(), catalog = try store.createNotebook(title: "Catalog")
        try store.setJournalTopic(notebookID: catalog.notebookId, name: "Work", present: true)
        let note = try store.createJournalEntry(), owner = UUID(), pageID = note.pageIds[0]
        store.setAutomaticTagDrawing(true, owner: owner)
        var page = try store.loadPage(notebookId: note.notebookId, pageId: pageID)
        page.blocks = [CouchBlock(id: "body", kind: "md", text: "#Work", createdAt: page.createdAt, updatedAt: page.updatedAt, deviceId: "local")]
        page.strokes = [try stroke()]; page = try store.savePage(page)
        try store.removeJournalTopic(key: "work")
        let noOldWork = expectation(description: "global removal cancels the old edit"); noOldWork.isInverted = true
        let subscription = store.$journalEntries.sink { entries in
            if entries[note.notebookId]?.topics["work"] != nil { noOldWork.fulfill() }
        }
        store.setAutomaticTagDrawing(false, owner: owner)
        await store.applyAutomaticTopics(notebookID: note.notebookId, pageID: pageID, recognizedText: "#Work",
            inkFingerprint: HandwritingTranscript.fingerprint(page.strokes), delay: .zero).value
        let result = await XCTWaiter.fulfillment(of: [noOldWork], timeout: 0.7)
        XCTAssertEqual(result, .completed); subscription.cancel()
        page.blocks[0].text = "#Work again"
        _ = try store.savePage(page)
        await store.applyAutomaticTopics(notebookID: note.notebookId, pageID: pageID, delay: .zero).value
        XCTAssertTrue(store.journalEntries[note.notebookId]?.topics["work"]?.present == true)
        XCTAssertFalse(try XCTUnwrap(store.journalEntries[catalog.notebookId]?.topics["work"]).present)
    }

    private func tagStore(automatic: Bool? = nil) throws -> NotebookStore {
        let name = "tags-test-\(UUID().uuidString)", defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        if let automatic { defaults.set(automatic, forKey: "journal.automaticTags") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        addTeardownBlock { try? FileManager.default.removeItem(at: root); UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        return NotebookStore(rootURL: root, preferences: defaults)
    }

    private func stroke(id: String = "original") throws -> StrokeDTO {
        let points: [NotableStrokePoint] = (0..<20).map { index in
            let x = Float(20 + index * 8), y = Float(80 + (index % 3) * 10)
            return NotableStrokePoint(x: x, y: y, pressure: 1)
        }
        let data = try SBStrokeCodec.encode(points)
        let now = SyncClock.shared.stamp()
        return StrokeDTO(id: id, size: 4, pen: .ballpen, color: -16777216, top: 80, bottom: 100, left: 20, right: 172, pointsData: data.base64EncodedString(), createdAt: now, updatedAt: now)
    }
}
