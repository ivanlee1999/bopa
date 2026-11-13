import NotableKit
import UIKit
import XCTest
@testable import Bopa

@MainActor
final class FlowPageModelTests: XCTestCase {
    private var root: URL!
    private var store: NotebookStore!
    private var notebook: NotebookManifest!
    private var pageID: String { notebook.pageIds[0] }
    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("bopa-flow-test-\(UUID().uuidString)")
        store = NotebookStore(rootURL: root)
        notebook = try store.createJournalEntry(topic: "Product")
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }
    private func model() -> FlowPageModel {
        let model = FlowPageModel()
        XCTAssertTrue(model.attach(store: store, notebookID: notebook.notebookId, pageID: pageID))
        return model
    }
    private func page() throws -> PageFile { try store.loadPage(notebookId: notebook.notebookId, pageId: pageID) }
    private func seed(_ text: String) throws -> [CouchBlock] {
        var value = try page()
        value.blocks = try FlowText.replacing(base: [], in: [], with: text, stamp: "2026-11-12T09:00:00Z", deviceID: "boox")
        return try store.savePage(value).blocks.filter { $0.kind == "md" }
    }

    func testTypingPreservesParagraphIDsAndJournalMetadataAcrossRepeatedAutosaves() throws {
        let before = try seed("One\n\nTwo")
        let organization = store.journalEntries[notebook.notebookId]
        let model = model(), id = try XCTUnwrap(model.parts.first?.id)
        model.beganEditing()
        model.update("One\n\nTwo edited", id: id)
        XCTAssertTrue(model.flush())
        model.update("One\n\nTwo edited again", id: id)
        XCTAssertTrue(model.flush())
        let after = try page().blocks.filter { $0.kind == "md" }
        XCTAssertEqual(Set(after.map(\.id)), Set(before.map(\.id)))
        XCTAssertEqual(FlowText.markdown(in: after), "One\n\nTwo edited again")
        XCTAssertEqual(store.journalEntries[notebook.notebookId], organization)
    }

    func testFlowEditAndRestoreOrderingBeatExistingFutureClocks() throws {
        _ = try seed("zulu")
        var saved = try page()
        saved.blocks[0].orderKey = "legacy-key"
        saved.blocks[0].updatedAt = NotableDate.format(SyncClock.shared.now().addingTimeInterval(60))
        _ = try store.savePage(saved)
        let flow = model(), id = try XCTUnwrap(flow.parts.first?.id)
        flow.update("alpha", id: id)
        XCTAssertTrue(flow.flush())
        XCTAssertEqual(FlowText.markdown(in: try page().blocks), "alpha")
        let primary = try XCTUnwrap(page().blocks.first { $0.kind == "md" })
        XCTAssertGreaterThan(CouchMerge.millis(primary.updatedAt), CouchMerge.millis(saved.blocks[0].updatedAt))
        let version = TextVersions.recovery(CouchBlock(id: "old", kind: "md", text: "Restored", createdAt: primary.createdAt, updatedAt: primary.updatedAt, deviceId: "boox"))
        flow.restoreVersion(version)
        XCTAssertEqual(FlowText.markdown(in: try page().blocks), "alpha\n\nRestored")
    }

    func testLocalDraftIsRecoverableBeforeCanonicalAutosaveRuns() throws {
        let first = model(), id = try XCTUnwrap(first.parts.first?.id)
        first.update("A thought kept through interruption 👋", id: id)
        XCTAssertTrue(try page().blocks.isEmpty)
        let reopened = model()
        XCTAssertEqual(reopened.parts.first?.source, "A thought kept through interruption 👋")
        XCTAssertTrue(reopened.flush())
        XCTAssertEqual(FlowText.markdown(in: try page().blocks), "A thought kept through interruption 👋")
    }

    func testRemoteEditKeepsCurrentSourceAndReadableDirtyRecovery() throws {
        let blocks = try seed("Original")
        let model = model(), id = try XCTUnwrap(model.parts.first?.id)
        model.beganEditing(); model.update("Local draft", id: id)
        var remote = try page(); remote.blocks[0].text = "Remote edit"
        remote.blocks[0].updatedAt = SyncClock.shared.stamp()
        _ = try store.savePage(remote)
        XCTAssertFalse(model.flush())
        XCTAssertEqual(FlowText.markdown(in: try page().blocks), "Remote edit")
        XCTAssertEqual(model.source(for: id), "Local draft")
        XCTAssertTrue(model.parts[0].conflict)
        XCTAssertTrue(try page().blocks.contains { $0.kind == TextVersions.kind && $0.text == "Local draft" && TextVersions.sourceID($0.id) == blocks[0].id })
        XCTAssertTrue(model.addDraftToNote())
        XCTAssertEqual(FlowText.markdown(in: try page().blocks), "Remote edit\n\nLocal draft")
    }

    func testUntouchedRemoteParagraphIsNotOverwrittenOnTheNextKeystroke() throws {
        _ = try seed("A\n\nB")
        let model = model(), id = try XCTUnwrap(model.parts.first?.id)
        model.beganEditing(); model.update("A local\n\nB", id: id)
        var remote = try page()
        let index = try XCTUnwrap(remote.blocks.firstIndex { $0.text == "B" })
        remote.blocks[index].text = "B remote"; remote.blocks[index].updatedAt = SyncClock.shared.stamp()
        _ = try store.savePage(remote)
        XCTAssertTrue(model.flush())
        model.update("A local again\n\nB", id: id)
        XCTAssertTrue(model.flush())
        XCTAssertEqual(FlowText.markdown(in: try page().blocks), "A local again\n\nB remote")
        model.endedEditing()
        XCTAssertEqual(model.parts.first?.source, "A local again\n\nB remote")
    }

    func testIncomingNonTextBoundaryNeverMovesThroughADirtyDraft() throws {
        _ = try seed("A\n\nB")
        let model = model(), id = try XCTUnwrap(model.parts.first?.id)
        model.beganEditing(); model.update("A local\n\nB", id: id)
        var remote = try page()
        let md = FlowText.ordered(remote.blocks)
        remote.blocks = [md[0], CouchBlock(id: "audio", kind: "audio", orderKey: "000000000000.5", createdAt: "2026-11-12T09:00:00Z", updatedAt: "2026-11-12T09:00:00Z", deviceId: "boox"), md[1]]
        _ = try store.savePage(remote)
        XCTAssertFalse(model.flush())
        XCTAssertEqual(FlowText.ordered(try page().blocks).map(\.kind), ["md", "audio", "md"])
        XCTAssertTrue(try page().blocks.contains { $0.kind == TextVersions.kind && $0.text == "A local\n\nB" })
    }

    func testFailedSaveKeepsDraftAndRefusesAnotherPageUntilRetrySucceeds() throws {
        let model = model(), id = try XCTUnwrap(model.parts.first?.id)
        let next = try store.addPage(to: notebook.notebookId)
        model.update("Keep this text", id: id)
        let url = store.notebookDirURL(notebook.notebookId).appendingPathComponent("manifest.json")
        let data = try Data(contentsOf: url); try FileManager.default.removeItem(at: url)
        XCTAssertFalse(model.attach(store: store, notebookID: notebook.notebookId, pageID: next.id))
        XCTAssertEqual(model.source(for: id), "Keep this text")
        try data.write(to: url)
        XCTAssertTrue(model.flush())
        XCTAssertEqual(FlowText.markdown(in: try page().blocks), "Keep this text")
    }

    func testOpeningAnUntouchedTypingSurfaceWritesNoEmptyBlock() throws {
        let before = try Data(contentsOf: store.notebookDirURL(notebook.notebookId).appendingPathComponent("pages/\(pageID).json"))
        let model = model()
        XCTAssertTrue(model.flush())
        XCTAssertEqual(before, try Data(contentsOf: store.notebookDirURL(notebook.notebookId).appendingPathComponent("pages/\(pageID).json")))
    }

    func testCommittedNewRunWithSurvivingDraftIsReplayedExactlyOnce() throws {
        let before = model(), slot = try XCTUnwrap(before.parts.first?.id)
        before.update("First thought", id: slot)
        let canonical = try seed("First thought")
        before.discardAfterLocalDeletion()
        struct Intent: Codable { var id: String; var blocks: [CouchBlock]; var source: String; var pending: [CouchBlock] }
        let url = root.appendingPathComponent("local-flow-drafts/\(notebook.notebookId)/\(pageID).json")
        try JSONEncoder().encode([Intent(id: slot, blocks: [], source: "First thought", pending: canonical)]).write(to: url, options: .atomic)
        let reopened = model()
        XCTAssertTrue(reopened.flush())
        XCTAssertEqual(try page().blocks.filter { $0.kind == "md" }.map(\.id), canonical.map(\.id))
        XCTAssertEqual(reopened.parts.filter(\.isMarkdown).map(\.source), ["First thought"])
    }

    func testSurvivingNewRunIntentCannotOverwriteRemoteEditsToItsMintedID() throws {
        let before = model(), slot = try XCTUnwrap(before.parts.first?.id)
        before.update("Local draft", id: slot)
        let canonical = try seed("Local draft")
        before.discardAfterLocalDeletion()
        var remote = try page()
        remote.blocks[0].text = "Changed on another device"
        remote.blocks[0].updatedAt = SyncClock.shared.stamp()
        _ = try store.savePage(remote)
        struct Intent: Codable { var id: String; var blocks: [CouchBlock]; var source: String; var pending: [CouchBlock] }
        let url = root.appendingPathComponent("local-flow-drafts/\(notebook.notebookId)/\(pageID).json")
        try JSONEncoder().encode([Intent(id: slot, blocks: [], source: "Local draft", pending: canonical)]).write(to: url, options: .atomic)
        let reopened = model()
        XCTAssertFalse(reopened.flush())
        XCTAssertEqual(FlowText.markdown(in: try page().blocks), "Changed on another device")
        XCTAssertTrue(try page().blocks.contains { $0.kind == TextVersions.kind && $0.text == "Local draft" })
    }

    func testRemotePageRemovalKeepsDirtyTypingInOneReadableRecoveryNotebook() throws {
        let flow = model(), slot = try XCTUnwrap(flow.parts.first?.id)
        flow.beganEditing(); flow.update("Words from the removed page", id: slot)
        var changed = try XCTUnwrap(store.manifest(id: notebook.notebookId))
        changed.pageIds = []
        changed.deletedPageIds.append(CouchTombstone(id: pageID, deletedAt: SyncClock.shared.stamp()))
        try JSONEncoder().encode(changed).write(to: store.notebookDirURL(notebook.notebookId).appendingPathComponent("manifest.json"), options: .atomic)
        store.refresh()
        XCTAssertTrue(flow.flush())
        let recoveredID = try XCTUnwrap(flow.recoveredNotebookID)
        let recovered = try XCTUnwrap(store.manifest(id: recoveredID))
        XCTAssertTrue(recovered.title.hasPrefix("Recovered text"))
        XCTAssertEqual(FlowText.markdown(in: try store.loadPage(notebookId: recoveredID, pageId: recovered.pageIds[0]).blocks), "Words from the removed page")
        XCTAssertTrue(flow.flush())
        XCTAssertEqual(store.notebooks.filter { $0.notebookId == recoveredID }.count, 1)
    }

    func testNativeFormattingKeepsUnicodeSourceAndSelectionOffsets() {
        let view = FlowNativeTextView()
        view.text = "Hi 👋 café"
        view.selectedRange = NSRange(location: 3, length: 2)
        view.apply(.bold)
        XCTAssertEqual(view.text, "Hi **👋** café")
        XCTAssertEqual(view.selectedRange, NSRange(location: 5, length: 2))
        view.styleSource()
        XCTAssertEqual(view.text, "Hi **👋** café")
    }

    func testFlowOnlyPreviewActuallyContainsTextPixels() throws {
        _ = try seed("# A visible typed note\n\nNo blank cover.")
        let value = try page(), original = value
        let image = FlowPagePreview.image(page: value, notebookDir: store.notebookDirURL(notebook.notebookId), storeRoot: store.rootURL)
        let cg = try XCTUnwrap(image.cgImage)
        var pixels = [UInt8](repeating: 255, count: cg.width * cg.height * 4)
        let context = try XCTUnwrap(CGContext(data: &pixels, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        XCTAssertGreaterThan(stride(from: 0, to: pixels.count, by: 4).filter { pixels[$0] < 180 && pixels[$0 + 1] < 180 && pixels[$0 + 2] < 180 }.count, 30)
        XCTAssertEqual(value, original)
    }
}
