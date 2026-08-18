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
