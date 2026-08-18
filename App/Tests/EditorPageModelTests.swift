import NotableKit
import PencilKit
import XCTest

@testable import Bopa

/// The editor's save/reload rules, driven without a canvas: what survives a failed flush, and
/// where the editor goes when the store changes underneath it. These are the paths that used to
/// be `@State` inside `EditorView`, reachable only by a finger on a simulator — and the ones
/// that decide whether ink survives.
@MainActor
final class EditorPageModelTests: XCTestCase {
    private var rootURL: URL!
    private var store: NotebookStore!
    private var notebookId = ""

    override func setUp() async throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("bopa-editor-model-test-\(UUID().uuidString)")
        store = NotebookStore(rootURL: rootURL)
        notebookId = try store.createNotebook(title: "Notes").notebookId
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: rootURL)
    }

    private var pageIds: [String] { store.manifest(id: notebookId)?.pageIds ?? [] }

    private func makeModel() -> EditorPageModel {
        let model = EditorPageModel()
        model.attach(store: store, notebookId: notebookId)
        return model
    }

    /// A stroke with real point data, so it survives the round trip through PencilKit. Distinct
    /// `createdAt`s matter: they are how the bridge re-identifies untouched strokes on export.
    private func makeStroke(id: String, second: Int) throws -> StrokeDTO {
        let points = [
            NotableStrokePoint(x: 10, y: Float(second) * 50 + 10, pressure: 0.5),
            NotableStrokePoint(x: 60, y: Float(second) * 50 + 40, pressure: 0.5),
        ]
        let created = String(format: "2026-08-15T00:00:%02d.000Z", second)
        return StrokeDTO(
            id: id, size: 3, pen: .ballpen, color: -16_777_216,
            top: Float(second) * 50 + 10, bottom: Float(second) * 50 + 40, left: 10, right: 60,
            pointsData: try SBStrokeCodec.encode(points).base64EncodedString(),
            createdAt: created, updatedAt: created)
    }

    private var manifestURL: URL {
        rootURL.appendingPathComponent("notebooks/\(notebookId)/manifest.json")
    }

    /// Makes the next save fail the way a torn or deleted notebook does, returning what it takes
    /// to heal the store again.
    private func breakTheStore() throws -> Data {
        let data = try Data(contentsOf: manifestURL)
        try FileManager.default.removeItem(at: manifestURL)
        return data
    }

    // MARK: The baseline advances only after a save lands

    /// An erasure must survive a failed flush. The baseline (`canvasStrokeIDs`) used to advance
    /// before the write: a failed save consumed the erasure, so the successful retry derived no
    /// tombstone and the fold against the file resurrected the erased stroke.
    func testAFailedSaveDoesNotConsumeAnErasure() throws {
        var page = try store.loadPage(notebookId: notebookId, pageId: pageIds[0])
        let keep = try makeStroke(id: "keep", second: 0)
        let gone = try makeStroke(id: "gone", second: 1)
        page.strokes = [keep, gone]
        try store.savePage(page)

        let model = makeModel()
        XCTAssertTrue(model.open(pageId: pageIds[0]))
        XCTAssertEqual(model.canvasStrokeIDs, ["keep", "gone"])

        // The user erases "gone", and the flush fails underneath the save alert.
        model.drawing = PencilKitBridge.drawing(from: [keep])
        model.scheduleSave()
        let heal = try breakTheStore()
        model.saveNow()

        XCTAssertNotNil(model.saveError, "the failure must surface")
        XCTAssertTrue(model.dirty, "a failed save must keep the retry armed")
        XCTAssertEqual(
            model.canvasStrokeIDs, ["keep", "gone"],
            "the baseline advanced on a save that never landed")
        XCTAssertEqual(
            model.page?.strokes.map(\.id), ["keep", "gone"],
            "`page` must keep the last truly-written DTOs across a failure")

        // The store heals; the retry must still record the erasure.
        try heal.write(to: manifestURL)
        model.saveNow()

        XCTAssertFalse(model.dirty)
        let onDisk = try store.loadPage(notebookId: notebookId, pageId: pageIds[0])
        XCTAssertEqual(onDisk.strokes.map(\.id), ["keep"], "the erased stroke came back")
        XCTAssertEqual(
            onDisk.deletedStrokes.map(\.id), ["gone"],
            "without a tombstone the peer resurrects the stroke on the next merge")
    }

    // MARK: Folding in remote ink must not cost local ink

    /// The fold flushes, then reloads from the file. When the flush *fails*, the reload used to
    /// run anyway — replacing the drawing with the file and clearing `dirty`, which discarded the
    /// very strokes the save alert had just promised were safe and cancelled their retry. The
    /// fold now waits until a save has landed; `remoteInkPending` stays set so it still happens.
    func testARemoteApplyDoesNotReloadOverInkAFailedSaveStillOwes() throws {
        var page = try store.loadPage(notebookId: notebookId, pageId: pageIds[0])
        let s1 = try makeStroke(id: "s1", second: 0)
        page.strokes = [s1]
        try store.savePage(page)

        let model = makeModel()
        XCTAssertTrue(model.open(pageId: pageIds[0]))

        // The user draws a second stroke; it is not saved yet.
        let unsaved = PencilKitBridge.drawing(from: [try makeStroke(id: "s2", second: 2)])
        model.drawing = PKDrawing(strokes: model.drawing.strokes + unsaved.strokes)
        model.scheduleSave()

        // The BOOX's stroke lands in the file underneath the open page...
        var onDisk = try store.loadPage(notebookId: notebookId, pageId: pageIds[0])
        onDisk.strokes.append(try makeStroke(id: "from-boox", second: 4))
        try writePageDirectly(onDisk)

        // ...and sync announces it while the store cannot take the flush.
        let heal = try breakTheStore()
        NotificationCenter.default.post(
            name: NotebookStore.didApplyRemoteChangesNotification, object: nil)

        XCTAssertEqual(
            model.drawing.strokes.count, 2,
            "the reload threw away the unsaved stroke the save alert promised was safe")
        XCTAssertTrue(model.dirty, "clearing dirty here cancels the retry")
        XCTAssertTrue(model.remoteInkPending, "the fold still owes the canvas the BOOX's stroke")
        XCTAssertNotNil(model.saveError)

        // Once the store heals, the next apply folds everything together: the local stroke is
        // flushed first, so the reload holds both devices' ink.
        try heal.write(to: manifestURL)
        NotificationCenter.default.post(
            name: NotebookStore.didApplyRemoteChangesNotification, object: nil)

        XCTAssertEqual(model.drawing.strokes.count, 3)
        XCTAssertFalse(model.dirty)
        XCTAssertFalse(model.remoteInkPending)
        let final = try store.loadPage(notebookId: notebookId, pageId: pageIds[0])
        XCTAssertEqual(final.strokes.count, 3)
    }

    /// Writes straight to disk, bypassing the store — standing in for the sync engine.
    private func writePageDirectly(_ page: PageFile) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        try encoder.encode(page).write(
            to: rootURL.appendingPathComponent(
                "notebooks/\(notebookId)/pages/\(page.id).json"),
            options: .atomic)
    }

    /// The ordinary path still works: drawing, saving, and the baseline following the save.
    func testASuccessfulSaveAdvancesTheBaseline() throws {
        var page = try store.loadPage(notebookId: notebookId, pageId: pageIds[0])
        page.strokes = [try makeStroke(id: "s1", second: 0)]
        try store.savePage(page)

        let model = makeModel()
        XCTAssertTrue(model.open(pageId: pageIds[0]))

        model.drawing = PencilKitBridge.drawing(from: [])
        model.scheduleSave()
        model.saveNow()

        XCTAssertNil(model.saveError)
        XCTAssertFalse(model.dirty)
        XCTAssertEqual(model.canvasStrokeIDs, [])
        let onDisk = try store.loadPage(notebookId: notebookId, pageId: pageIds[0])
        XCTAssertTrue(onDisk.strokes.isEmpty)
        XCTAssertEqual(onDisk.deletedStrokes.map(\.id), ["s1"])
    }
}
