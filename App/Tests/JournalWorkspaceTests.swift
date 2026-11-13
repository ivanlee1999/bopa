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
