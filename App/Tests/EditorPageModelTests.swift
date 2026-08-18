import NotableKit
import PencilKit
import UIKit
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

    // MARK: Remote changes that carry no ink

    /// Puts a tiny valid PNG at `images/<name>` in the notebook dir, the way the sync engine's
    /// asset download does.
    private func installImageFile(named name: String) throws {
        let imagesDir = rootURL.appendingPathComponent(
            "notebooks/\(notebookId)/images", isDirectory: true)
        try FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let png = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4), format: format)
            .pngData { ctx in
                UIColor.systemRed.setFill()
                ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
            }
        try png.write(to: imagesDir.appendingPathComponent(name))
    }

    private func makeImageDTO(uri: String) -> ImageDTO {
        let now = NotableDate.format(Date())
        return ImageDTO(
            id: UUID().uuidString.lowercased(), x: 100, y: 200, width: 300, height: 150,
            uri: uri, createdAt: now, updatedAt: now)
    }

    /// The fold used to decide "changed" from strokes alone, so an image dropped on the BOOX was
    /// read as "the canvas already matches the file" and swallowed for as long as the page stayed
    /// open — every later apply re-armed the flag, and the stroke comparison cleared it again.
    func testAnImageOnlyRemoteChangeReachesTheOpenPage() throws {
        try installImageFile(named: "pix.png")
        let model = makeModel()
        XCTAssertTrue(model.open(pageId: pageIds[0]))
        let revisionBefore = model.contentRevision

        var onDisk = try store.loadPage(notebookId: notebookId, pageId: pageIds[0])
        onDisk.images = [makeImageDTO(uri: "images/pix.png")]
        try writePageDirectly(onDisk)
        NotificationCenter.default.post(
            name: NotebookStore.didApplyRemoteChangesNotification, object: nil)

        XCTAssertEqual(model.page?.images.map(\.id), onDisk.images.map(\.id))
        XCTAssertEqual(model.pageImages.count, 1, "the image never reached the open page")
        XCTAssertEqual(
            model.pageImages.first?.frame, CGRect(x: 100, y: 200, width: 300, height: 150))
        XCTAssertFalse(model.remoteInkPending)
        XCTAssertEqual(
            model.contentRevision, revisionBefore,
            "a surface change must not reload the canvas — that costs the undo stack")
    }

    func testAPaperOnlyRemoteChangeReachesTheOpenPage() throws {
        let model = makeModel()
        XCTAssertTrue(model.open(pageId: pageIds[0]))

        var onDisk = try store.loadPage(notebookId: notebookId, pageId: pageIds[0])
        onDisk.background = "lined"
        try writePageDirectly(onDisk)
        NotificationCenter.default.post(
            name: NotebookStore.didApplyRemoteChangesNotification, object: nil)

        XCTAssertEqual(model.page?.background, "lined", "the BOOX's paper change was swallowed")
        XCTAssertFalse(model.remoteInkPending)
    }

    /// Most applied documents are some other page, or this page's own echo. Those must still
    /// clear the flag — and touch nothing, or every pull would redraw the open page.
    func testANoChangeApplyClearsThePendingFlagWithoutTouchingState() throws {
        let model = makeModel()
        XCTAssertTrue(model.open(pageId: pageIds[0]))
        let revisionBefore = model.contentRevision
        let pageBefore = model.page

        NotificationCenter.default.post(
            name: NotebookStore.didApplyRemoteChangesNotification, object: nil)

        XCTAssertFalse(model.remoteInkPending)
        XCTAssertEqual(model.contentRevision, revisionBefore)
        XCTAssertEqual(model.page, pageBefore)
        XCTAssertTrue(model.pageImages.isEmpty)
    }

    /// The trust-fixes semantics hold for surfaces too: a failed pre-fold flush defers the whole
    /// fold, image and all, until a save has landed — and the retry then delivers both.
    func testAFailedFlushStillDefersAnImageOnlyFold() throws {
        try installImageFile(named: "pix.png")
        let model = makeModel()
        XCTAssertTrue(model.open(pageId: pageIds[0]))

        // Unsaved ink inside the debounce window...
        model.drawing = PencilKitBridge.drawing(from: [try makeStroke(id: "s1", second: 0)])
        model.scheduleSave()

        // ...an image lands in the file underneath the open page...
        var onDisk = try store.loadPage(notebookId: notebookId, pageId: pageIds[0])
        onDisk.images = [makeImageDTO(uri: "images/pix.png")]
        try writePageDirectly(onDisk)

        // ...and sync announces it while the store cannot take the flush.
        let heal = try breakTheStore()
        NotificationCenter.default.post(
            name: NotebookStore.didApplyRemoteChangesNotification, object: nil)

        XCTAssertTrue(model.remoteInkPending, "the fold ran over a flush that failed")
        XCTAssertTrue(model.pageImages.isEmpty, "state advanced while the flush is still owed")
        XCTAssertTrue(model.dirty)
        XCTAssertNotNil(model.saveError)

        // Once the store heals, the next apply flushes the stroke and delivers the image.
        try heal.write(to: manifestURL)
        NotificationCenter.default.post(
            name: NotebookStore.didApplyRemoteChangesNotification, object: nil)

        XCTAssertFalse(model.remoteInkPending)
        XCTAssertEqual(model.pageImages.count, 1)
        XCTAssertFalse(model.dirty)
        XCTAssertEqual(
            model.drawing.strokes.count, 1, "the flush-then-fold lost the unsaved stroke")
        let final = try store.loadPage(notebookId: notebookId, pageId: pageIds[0])
        XCTAssertEqual(final.strokes.count, 1)
        XCTAssertEqual(final.images.count, 1, "the flush dropped the image the sync had written")
    }

    // MARK: Switching pages flushes the one being left

    /// The navigator panel jumps pages through `open(pageId:)` alone — the one switch path that
    /// never flushed. Everything drawn inside the 2-second debounce window was silently lost,
    /// along with the unsaved scroll offset. `open` now flushes at the door.
    func testOpeningAnotherPageFlushesTheDebouncedWork() throws {
        let second = try store.addPage(to: notebookId)
        let model = makeModel()
        XCTAssertTrue(model.open(pageId: pageIds[0]))

        // Draw and scroll, then jump pages before the 2s debounce fires — the navigator's path.
        model.drawing = PencilKitBridge.drawing(from: [try makeStroke(id: "s1", second: 0)])
        model.scheduleSave()
        model.liveState.pageY = 500

        XCTAssertTrue(model.open(pageId: second.id))

        let left = try store.loadPage(notebookId: notebookId, pageId: pageIds[0])
        XCTAssertEqual(left.strokes.count, 1, "the stroke drawn inside the debounce window is gone")
        XCTAssertEqual(left.scroll, 500, "the scroll offset was dropped with it")
    }

    /// The fold's own path — saveNow, then open to reload — must stay a single flush: a second
    /// save inside `open` has to see a clean page and do nothing.
    func testOpeningTheSamePageAfterASaveIsANoOpFlush() throws {
        var page = try store.loadPage(notebookId: notebookId, pageId: pageIds[0])
        page.strokes = [try makeStroke(id: "s1", second: 0)]
        try store.savePage(page)

        let model = makeModel()
        XCTAssertTrue(model.open(pageId: pageIds[0]))
        let before = try store.loadPage(notebookId: notebookId, pageId: pageIds[0]).updatedAt

        XCTAssertTrue(model.open(pageId: pageIds[0]))

        let after = try store.loadPage(notebookId: notebookId, pageId: pageIds[0]).updatedAt
        XCTAssertEqual(after, before, "a clean page was rewritten just for being reopened")
    }

    // MARK: The open page vanishing underneath the editor

    /// Deleting the open page from the overview used to leave the editor writing into a
    /// tombstoned ghost file — it only listened for *remote* changes. It now hears the local
    /// delete, drops the pending work (the strokes belong to a page that no longer exists), and
    /// lands on the neighbor. No save alert: a deletion the user asked for is not a failure.
    func testDeletingTheOpenPageMovesTheEditorToItsNeighbor() throws {
        let second = try store.addPage(to: notebookId)
        let third = try store.addPage(to: notebookId)
        let model = makeModel()
        XCTAssertTrue(model.open(pageId: third.id))

        // Ink drawn moments before the delete: it belongs to the doomed page and goes with it.
        model.drawing = PencilKitBridge.drawing(from: [try makeStroke(id: "s1", second: 0)])
        model.scheduleSave()

        try store.deletePage(from: notebookId, pageId: third.id)

        XCTAssertEqual(model.pageId, second.id, "the nearest surviving neighbor")
        XCTAssertFalse(model.dirty)
        XCTAssertNil(model.saveError, "a deletion the user asked for is not a failed save")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: rootURL
                    .appendingPathComponent("notebooks/\(notebookId)/pages/\(third.id).json")
                    .path),
            "the editor recreated the ghost file the delete had just removed")
    }

    func testDeletingSomeOtherPageLeavesTheEditorWhereItIs() throws {
        let second = try store.addPage(to: notebookId)
        let model = makeModel()
        XCTAssertTrue(model.open(pageId: pageIds[0]))

        try store.deletePage(from: notebookId, pageId: second.id)

        XCTAssertEqual(model.pageId, pageIds[0])
    }

    /// The same vanish arriving from sync: the merge unlists the page, the pull loop refreshes
    /// and announces. The editor must move rather than fold ink into a tombstoned page.
    func testARemoteMergeThatDeletesTheOpenPageMovesTheEditor() throws {
        let second = try store.addPage(to: notebookId)
        let model = makeModel()
        XCTAssertTrue(model.open(pageId: second.id))

        var manifest = try XCTUnwrap(store.manifest(id: notebookId))
        manifest.pageIds.removeAll { $0 == second.id }
        manifest.deletedPageIds.append(
            CouchTombstone(id: second.id, deletedAt: NotableDate.format(Date())))
        try writeManifestDirectly(manifest)
        store.refresh()
        NotificationCenter.default.post(
            name: NotebookStore.didApplyRemoteChangesNotification, object: nil)

        XCTAssertEqual(model.pageId, pageIds[0])
        XCTAssertNil(model.saveError)
    }

    /// The notebook itself going — deleted for good while its editor is open — leaves nothing to
    /// land on; the editor asks to be dismissed.
    func testTheNotebookVanishingAsksTheEditorToClose() throws {
        let model = makeModel()
        XCTAssertTrue(model.open(pageId: pageIds[0]))
        var closed = false
        model.requestClose = { closed = true }

        try store.purgeNotebook(id: notebookId)

        XCTAssertTrue(closed)
    }

    /// Writes straight to disk, bypassing the store — standing in for the sync engine.
    private func writeManifestDirectly(_ manifest: NotebookManifest) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        try encoder.encode(manifest).write(
            to: manifestURL, options: .atomic)
    }

    // MARK: Where the editor lands, as a table

    func testLandingPrefersThePageThatTookTheVanishedOnesPlace() {
        XCTAssertEqual(
            EditorPageRecovery.landingPageId(
                vanished: "b", previousOrder: ["a", "b", "c"],
                pageIds: ["a", "c"], openPageId: "a"),
            "c")
    }

    func testLandingFallsBackToThePageBeforeWhenTheLastPageGoes() {
        XCTAssertEqual(
            EditorPageRecovery.landingPageId(
                vanished: "c", previousOrder: ["a", "b", "c"],
                pageIds: ["a", "b"], openPageId: "a"),
            "b")
    }

    /// A merge can take several pages at once; the walk skips neighbors that went with it.
    func testLandingSkipsNeighborsThatVanishedInTheSameSweep() {
        XCTAssertEqual(
            EditorPageRecovery.landingPageId(
                vanished: "b", previousOrder: ["a", "b", "c", "d"],
                pageIds: ["a", "d"], openPageId: nil),
            "d")
    }

    /// With no memory of where the page was, the manifest's own openPageId is the best guess —
    /// a merge may have retargeted it deliberately.
    func testLandingUsesOpenPageIdWhenThePositionIsUnknown() {
        XCTAssertEqual(
            EditorPageRecovery.landingPageId(
                vanished: "x", previousOrder: [],
                pageIds: ["a", "b"], openPageId: "b"),
            "b")
        XCTAssertEqual(
            EditorPageRecovery.landingPageId(
                vanished: "x", previousOrder: [],
                pageIds: ["a", "b"], openPageId: "gone-too"),
            "a")
    }

    func testLandingIsNowhereWhenNoPagesSurvive() {
        XCTAssertNil(
            EditorPageRecovery.landingPageId(
                vanished: "a", previousOrder: ["a"], pageIds: [], openPageId: nil))
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
