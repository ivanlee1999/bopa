import NotableKit
import PencilKit
import SwiftUI
import UIKit
import XCTest

@testable import Bopa

/// A live text view owns the uncommitted characters. Exercise that ownership together with
/// the page model, rather than supplying the model a finished string after navigation.
@MainActor
final class CanvasTextSessionLifecycleTests: XCTestCase {
    private var rootURL: URL!
    private var store: NotebookStore!
    private var notebookId = ""

    override func setUp() async throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("bopa-text-session-test-\(UUID().uuidString)")
        store = NotebookStore(rootURL: rootURL)
        notebookId = try store.createNotebook(title: "Text session notes").notebookId
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: rootURL)
    }

    private func model(opening pageId: String) -> EditorPageModel {
        let model = EditorPageModel()
        model.attach(store: store, notebookId: notebookId)
        XCTAssertTrue(model.open(pageId: pageId))
        return model
    }

    /// Wire the same text callbacks as EditorView.canvasArea and makeUIView. No window or
    /// synthesized touches are needed to test which page receives a text session's commit.
    @MainActor
    private final class Session {
        let model: EditorPageModel
        let viewport = CanvasViewportController()
        let selection = ToolSelection()
        let container = CanvasContainerView(
            frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        lazy var coordinator = canvasView.makeCoordinator()

        init(model: EditorPageModel) {
            self.model = model
            selection.select(.text)
            container.keepsFitToWidth = false
            container.pageWidth = CGFloat(model.page?.pageSize.width ?? 1404)
            container.sheetHeight = CGFloat(model.page?.pageSize.height ?? 1872)
            container.layoutIfNeeded()
            coordinator.container = container
            coordinator.toolSelection = selection
            container.textDelegate = coordinator
            container.textEditor.delegate = coordinator
            viewport.attach(container)
            container.setTextBlocks(model.textBlocks)
            coordinator.applyToolIfNeeded()
            // Explicit groups keep these tests independent of the simulator's run loop.
            container.pageUndoManager.groupsByEvent = false
        }

        var canvasView: EditorCanvasView {
            let model = model
            return EditorCanvasView(
                pageId: model.pageId,
                contentRevision: model.contentRevision,
                textBlocks: model.textBlocks,
                pageSize: model.page?.pageSize ?? .legacyUndeclared,
                drawing: Binding(get: { model.drawing }, set: { model.drawing = $0 }),
                toolSelection: selection,
                liveState: model.liveState,
                viewport: viewport,
                makeTextBlock: model.newTextBlock,
                beginTextBlockEditing: model.beginEditing,
                commitTextBlock: { model.commitEditing($0, text: $1) },
                moveTextBlock: { model.moveTextBlock(id: $0, to: $1) },
                resizeTextBlock: { model.resizeTextBlock(id: $0, width: $1) },
                currentTextBlock: { model.textBlock(id: $0) },
                restoreTextBlock: { model.restoreTextBlock(id: $0, to: $1) },
                onChanged: model.scheduleSave)
        }

        func beginNewText(_ text: String) {
            coordinator.canvasContainer(container, didTapEmptyPageAt: CGPoint(x: 100, y: 200))
            replaceDraft(with: text)
        }

        func replaceDraft(with text: String) {
            container.textEditor.text = text
            coordinator.textViewDidChange(container.textEditor)
        }

        func refreshPageState() {
            // updateUIView refreshes the parent snapshot and visible blocks before processing
            // a page reload. The coordinator must not mistake the old draft for this page's.
            coordinator.parent = canvasView
            container.setTextBlocks(model.textBlocks)
        }

        func finishThroughViewport() {
            // The current EditorView.commitOpenTextBox route used by tool changes, background
            // interruptions and navigation. Keep this helper on the shipping shared finish
            // route when that route is refactored; the undo assertions below are the contract.
            guard let finished = viewport.endTextEditing() else { return }
            model.commitEditing(finished.block, text: finished.text)
        }
    }

    func testRemotePageRemovalRecoversTheActiveDraftWithoutWritingItOnTheLandingPage() throws {
        let first = try XCTUnwrap(store.manifest(id: notebookId)?.pageIds.first)
        let second = try store.addPage(to: notebookId)
        let model = model(opening: second.id)
        let session = Session(model: model)
        let draft = "These unfinished words belong to the removed page."
        session.beginNewText(draft)
        XCTAssertNotNil(session.container.editingTextBlock)
        XCTAssertEqual(session.container.textEditor.text, draft)

        // A peer unlists the page and announces its applied manifest, as the existing
        // EditorPageModel remote-removal tests do. This is not an explicit local delete.
        var manifest = try XCTUnwrap(store.manifest(id: notebookId))
        manifest.pageIds.removeAll { $0 == second.id }
        manifest.deletedPageIds.append(
            CouchTombstone(id: second.id, deletedAt: SyncClock.shared.stamp()))
        let manifestURL = store.notebookDirURL(notebookId).appendingPathComponent("manifest.json")
        try JSONEncoder().encode(manifest).write(to: manifestURL, options: .atomic)
        store.refresh()
        NotificationCenter.default.post(
            name: NotebookStore.didApplyRemoteChangesNotification, object: nil)
        session.refreshPageState()
        XCTAssertEqual(model.pageId, second.id,
                       "the removed page must retain ownership while its draft is still open")
        XCTAssertEqual(session.container.textEditor.text, draft)

        // A late Done event must be harmless after recovery, never a commit into the new page.
        session.container.pageUndoManager.beginUndoGrouping()
        session.coordinator.endTextEditing()
        session.container.pageUndoManager.endUndoGrouping()
        XCTAssertTrue(model.saveNow())
        XCTAssertEqual(model.pageId, first, "successful recovery can now leave the removed page")
        XCTAssertTrue(model.textBlocks.isEmpty,
                      "the landing page must not acquire the removed page's active text")
        let landing = try store.loadPage(notebookId: notebookId, pageId: first)
        XCTAssertTrue(landing.blocks.isEmpty,
                      "a late text commit must not persist the draft on another page")

        let recoveredTexts = try store.notebooks
            .filter { $0.notebookId != notebookId }
            .flatMap { notebook in
                try notebook.pageIds.flatMap { pageId in
                    try store.loadPage(notebookId: notebook.notebookId, pageId: pageId)
                        .blocks.compactMap(\.text)
                }
            }
        XCTAssertEqual(recoveredTexts.filter { $0 == draft }.count, 1,
                       "the live text view's draft must survive exactly once in recovery")
        XCTAssertFalse(try XCTUnwrap(store.manifest(id: notebookId)).pageIds.contains(second.id),
                       "recovering the text must not resurrect the peer-deleted page")
    }

    func testSwitchingFromTextToPenLeavesOneUndoableParagraph() throws {
        let pageId = try XCTUnwrap(store.manifest(id: notebookId)?.pageIds.first)
        let model = model(opening: pageId)
        let session = Session(model: model)
        let draft = "A paragraph finished by choosing the pen."
        session.beginNewText(draft)

        let manager = session.container.pageUndoManager
        manager.beginUndoGrouping()
        session.selection.select(.pen)
        session.coordinator.applyToolIfNeeded()
        session.finishThroughViewport()
        manager.endUndoGrouping()
        XCTAssertNil(session.container.editingTextBlock)
        XCTAssertEqual(model.textBlocks.map(\.text), [draft])
        XCTAssertTrue(manager.canUndo, "choosing Pen must register the same text edit as Done")

        if manager.canUndo { manager.undo() }
        XCTAssertTrue(model.textBlocks.isEmpty, "one Undo must remove the new paragraph")
        XCTAssertFalse(manager.canUndo, "one text session must register only one undo entry")
        XCTAssertTrue(model.saveNow())
        XCTAssertTrue(try store.loadPage(notebookId: notebookId, pageId: pageId).blocks.isEmpty)
        XCTAssertTrue(manager.canRedo)
        if manager.canRedo { manager.redo() }
        XCTAssertEqual(model.textBlocks.map(\.text), [draft])
    }

    func testSwitchingToolsCanUndoAnEditToAnExistingParagraph() throws {
        let pageId = try XCTUnwrap(store.manifest(id: notebookId)?.pageIds.first)
        let model = model(opening: pageId)
        let block = try XCTUnwrap(model.newTextBlock(at: CGPoint(x: 100, y: 200)))
        model.beginEditing(block)
        model.commitEditing(block, text: "Original paragraph")
        XCTAssertTrue(model.saveNow())
        let session = Session(model: model)
        session.coordinator.canvasContainer(session.container, didTapTextBlock: block.id)
        session.replaceDraft(with: "Edited paragraph")

        let manager = session.container.pageUndoManager
        manager.beginUndoGrouping()
        session.selection.select(.pen)
        session.coordinator.applyToolIfNeeded()
        session.finishThroughViewport()
        manager.endUndoGrouping()
        XCTAssertEqual(model.textBlock(id: block.id)?.text, "Edited paragraph")
        XCTAssertTrue(manager.canUndo)
        if manager.canUndo { manager.undo() }
        XCTAssertEqual(model.textBlock(id: block.id)?.text, "Original paragraph")
        XCTAssertEqual(model.textBlocks.count, 1)
        XCTAssertFalse(manager.canUndo)
        XCTAssertTrue(manager.canRedo)
        if manager.canRedo { manager.redo() }
        XCTAssertEqual(model.textBlock(id: block.id)?.text, "Edited paragraph")
    }
}
