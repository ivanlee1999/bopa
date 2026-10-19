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
            viewport.attach(container) { [weak coordinator = coordinator] in
                coordinator?.endTextEditing()
            }
            container.setTextBlocks(model.textBlocks)
            coordinator.loadedPageId = model.pageId
            coordinator.loadedRevision = model.contentRevision
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
                commitTextBlock: { model.commitEditing($0, text: $1, expectedPageID: $2) },
                moveTextBlock: { model.moveTextBlock(id: $0, to: $1) },
                resizeTextBlock: { model.resizeTextBlock(id: $0, width: $1) },
                currentTextBlock: { model.textBlock(id: $0) },
                restoreTextBlock: { model.restoreTextBlock(id: $0, to: $1, expectedPageID: $2) },
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
            let updated = canvasView
            // Match updateUIView's page-identity boundary, including the discard before the
            // new parent callbacks arrive and the page-local undo reset on reload.
            if coordinator.loadedPageId != updated.pageId {
                coordinator.discardTextEditingForPageChange()
                container.pageUndoManager.removeAllActions()
            }
            coordinator.parent = updated
            container.setTextBlocks(model.textBlocks)
            coordinator.loadedPageId = updated.pageId
            coordinator.loadedRevision = updated.contentRevision
        }

        func finishThroughViewport() {
            // The same route EditorView uses for tool changes, backgrounding and navigation.
            viewport.endTextEditing()
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

        // Finishing hands the draft back to its original page before recovery can navigate away.
        session.container.pageUndoManager.beginUndoGrouping()
        session.coordinator.endTextEditing()
        session.container.pageUndoManager.endUndoGrouping()
        XCTAssertTrue(model.saveNow())
        XCTAssertEqual(model.pageId, first, "successful recovery can now leave the removed page")
        session.refreshPageState()
        session.coordinator.endTextEditing()
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
        // A later disappearance/background callback must not register this session twice.
        // Do not manufacture an empty undo group around a callback that must be a no-op.
        session.finishThroughViewport()
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

    func testSavedUndoAndRedoKeepFollowingTheRestoredParagraphIdentity() throws {
        let pageId = try XCTUnwrap(store.manifest(id: notebookId)?.pageIds.first)
        let model = model(opening: pageId)
        let session = Session(model: model)
        let draft = "A saved paragraph must survive redo after a saved deletion."
        session.beginNewText(draft)
        let manager = session.container.pageUndoManager
        manager.beginUndoGrouping()
        session.finishThroughViewport()
        manager.endUndoGrouping()
        XCTAssertTrue(model.saveNow())

        // Saving every step makes each removal durable. A second cycle verifies that the
        // inverse action follows the newly restored ID rather than the first tombstoned ID.
        for _ in 0..<2 {
            let oldID = try XCTUnwrap(model.textBlocks.first?.id)
            XCTAssertTrue(manager.canUndo)
            if manager.canUndo { manager.undo() }
            XCTAssertTrue(model.textBlocks.isEmpty)
            XCTAssertTrue(model.saveNow())
            XCTAssertTrue(try store.loadPage(notebookId: notebookId, pageId: pageId).blocks.isEmpty)

            XCTAssertTrue(manager.canRedo)
            if manager.canRedo { manager.redo() }
            let restored = try XCTUnwrap(model.textBlocks.first)
            XCTAssertNotEqual(restored.id, oldID)
            XCTAssertEqual(restored.text, draft)
            XCTAssertEqual(model.textBlocks.count, 1)
            XCTAssertTrue(model.saveNow())
            let saved = try store.loadPage(notebookId: notebookId, pageId: pageId)
            XCTAssertEqual(saved.blocks.map(\.id), [restored.id])
            XCTAssertEqual(saved.blocks.first?.text, draft)
            XCTAssertTrue(saved.deletedBlocks.contains { $0.id == oldID })
        }
    }

    func testMultipleTextSessionsShareOneRestoredIdentityAcrossSavedUndoAndRedo() throws {
        let pageId = try XCTUnwrap(store.manifest(id: notebookId)?.pageIds.first)
        let model = model(opening: pageId)
        let session = Session(model: model)
        let manager = session.container.pageUndoManager
        let originalText = "The first completed text session."
        let editedText = "The second session edits the same paragraph."

        session.beginNewText(originalText)
        manager.beginUndoGrouping()
        session.finishThroughViewport()
        manager.endUndoGrouping()
        XCTAssertTrue(model.saveNow())
        let originalID = try XCTUnwrap(model.textBlocks.first?.id)

        session.refreshPageState()
        session.coordinator.canvasContainer(session.container, didTapTextBlock: originalID)
        session.replaceDraft(with: editedText)
        manager.beginUndoGrouping()
        session.finishThroughViewport()
        manager.endUndoGrouping()
        XCTAssertTrue(model.saveNow())
        XCTAssertEqual(model.textBlocks.map(\.text), [editedText])

        // Distinct completed sessions retain distinct undo actions, but must keep referring
        // to one logical paragraph after a saved deletion forces its identity to change.
        for _ in 0..<2 {
            let deletedID = try XCTUnwrap(model.textBlocks.first?.id)
            XCTAssertTrue(manager.canUndo)
            if manager.canUndo { manager.undo() }
            XCTAssertEqual(model.textBlocks.map(\.text), [originalText])
            XCTAssertTrue(model.saveNow())
            XCTAssertTrue(manager.canUndo)
            if manager.canUndo { manager.undo() }
            XCTAssertTrue(model.textBlocks.isEmpty)
            XCTAssertFalse(manager.canUndo, "two sessions must require exactly two undos")
            XCTAssertTrue(model.saveNow())
            XCTAssertTrue(try store.loadPage(notebookId: notebookId, pageId: pageId).blocks.isEmpty)

            XCTAssertTrue(manager.canRedo)
            if manager.canRedo { manager.redo() }
            let restored = try XCTUnwrap(model.textBlocks.first)
            XCTAssertNotEqual(restored.id, deletedID)
            XCTAssertEqual(model.textBlocks.map(\.text), [originalText])
            XCTAssertTrue(model.saveNow())

            XCTAssertTrue(manager.canRedo)
            if manager.canRedo { manager.redo() }
            XCTAssertEqual(model.textBlocks.map(\.id), [restored.id],
                           "redoing the later session must edit the restored paragraph, not append another")
            XCTAssertEqual(model.textBlocks.map(\.text), [editedText])
            XCTAssertFalse(manager.canRedo, "two sessions must require exactly two redos")
            XCTAssertTrue(model.saveNow())
            let saved = try store.loadPage(notebookId: notebookId, pageId: pageId)
            XCTAssertEqual(saved.blocks.map(\.id), [restored.id])
            XCTAssertEqual(saved.blocks.map(\.text), [editedText])
            XCTAssertTrue(saved.deletedBlocks.contains { $0.id == deletedID })
        }
    }

    func testExplicitLocalPageDeletionDiscardsItsDraftBeforeTheLandingPageArrives() throws {
        let first = try XCTUnwrap(store.manifest(id: notebookId)?.pageIds.first)
        let second = try store.addPage(to: notebookId)
        let model = model(opening: second.id)
        let session = Session(model: model)
        session.beginNewText("This draft is included in the explicitly deleted page.")
        XCTAssertNotNil(session.container.editingTextBlock)

        try store.deletePage(from: notebookId, pageId: second.id)
        XCTAssertEqual(model.pageId, first)
        XCTAssertNil(model.editingBlockID)
        session.refreshPageState()
        XCTAssertNil(session.container.editingTextBlock)
        XCTAssertTrue(session.container.textEditor.isHidden)

        // Late tool-change, Done and disappearance callbacks have no session left to commit.
        session.finishThroughViewport()
        session.coordinator.endTextEditing()
        XCTAssertTrue(model.saveNow())
        XCTAssertTrue(model.textBlocks.isEmpty)
        XCTAssertTrue(try store.loadPage(notebookId: notebookId, pageId: first).blocks.isEmpty)
        XCTAssertFalse(session.container.pageUndoManager.canUndo)
        XCTAssertEqual(store.notebooks.count, 1,
                       "an explicit local delete must not create a recovery notebook")
        XCTAssertFalse(try XCTUnwrap(store.manifest(id: notebookId)).pageIds.contains(second.id))
    }

    func testLocalPageDeletionRejectsALateCommitBeforeTheCanvasRefreshes() throws {
        let first = try XCTUnwrap(store.manifest(id: notebookId)?.pageIds.first)
        let second = try store.addPage(to: notebookId)
        let model = model(opening: second.id)
        let session = Session(model: model)
        session.beginNewText("This draft must never be committed onto the landing page.")

        try store.deletePage(from: notebookId, pageId: second.id)
        XCTAssertEqual(model.pageId, first)
        XCTAssertEqual(session.coordinator.parent.pageId, second.id,
                       "exercise the interval before updateUIView receives the new page")
        XCTAssertNotNil(session.container.editingTextBlock)

        let manager = session.container.pageUndoManager
        // Rejection must register nothing, so the test must not add its own empty group.
        session.finishThroughViewport()
        XCTAssertNil(session.container.editingTextBlock)
        XCTAssertNil(model.editingBlockID)
        XCTAssertTrue(model.textBlocks.isEmpty)
        XCTAssertFalse(manager.canUndo, "a rejected stale commit must not register undo")
        XCTAssertTrue(model.saveNow())
        XCTAssertTrue(try store.loadPage(notebookId: notebookId, pageId: first).blocks.isEmpty)
        XCTAssertEqual(store.notebooks.count, 1)

        session.refreshPageState()
        session.finishThroughViewport()
        XCTAssertTrue(model.textBlocks.isEmpty)
    }

    func testLocalPageDeletionRejectsALateUndoBeforeTheCanvasRefreshes() throws {
        let first = try XCTUnwrap(store.manifest(id: notebookId)?.pageIds.first)
        let second = try store.addPage(to: notebookId)
        let model = model(opening: second.id)
        let original = try XCTUnwrap(model.newTextBlock(at: CGPoint(x: 100, y: 200)))
        model.beginEditing(original)
        model.commitEditing(original, text: "The original paragraph belongs on the deleted page.")
        XCTAssertTrue(model.saveNow())
        let session = Session(model: model)
        session.coordinator.canvasContainer(session.container, didTapTextBlock: original.id)
        session.replaceDraft(with: "The edited paragraph also belongs on the deleted page.")
        let manager = session.container.pageUndoManager
        manager.beginUndoGrouping()
        session.finishThroughViewport()
        manager.endUndoGrouping()
        XCTAssertTrue(model.saveNow())
        XCTAssertTrue(manager.canUndo)

        try store.deletePage(from: notebookId, pageId: second.id)
        XCTAssertEqual(model.pageId, first)
        XCTAssertEqual(session.coordinator.parent.pageId, second.id)
        // The inverse edit would put the original paragraph onto A without its page guard.
        if manager.canUndo { manager.undo() }
        XCTAssertTrue(model.textBlocks.isEmpty)
        XCTAssertFalse(manager.canRedo, "a rejected stale undo must not register redo")
        XCTAssertTrue(model.saveNow())
        XCTAssertTrue(try store.loadPage(notebookId: notebookId, pageId: first).blocks.isEmpty)
        session.refreshPageState()
        XCTAssertFalse(manager.canUndo)
    }

    func testUndoTargetsTheFreshIDWhenThePeerDeletedTheParagraphBeingEdited() throws {
        let pageId = try XCTUnwrap(store.manifest(id: notebookId)?.pageIds.first)
        let model = model(opening: pageId)
        let original = try XCTUnwrap(model.newTextBlock(at: CGPoint(x: 100, y: 200)))
        model.beginEditing(original)
        model.commitEditing(original, text: "The original paragraph")
        XCTAssertTrue(model.saveNow())
        let session = Session(model: model)
        session.coordinator.canvasContainer(session.container, didTapTextBlock: original.id)
        session.replaceDraft(with: "The local edit survives under a new ID.")

        var onDisk = try store.loadPage(notebookId: notebookId, pageId: pageId)
        onDisk.blocks.removeAll { $0.id == original.id }
        onDisk.deletedBlocks.append(
            CouchTombstone(id: original.id, deletedAt: SyncClock.shared.stamp()))
        _ = try store.savePage(onDisk)
        NotificationCenter.default.post(
            name: NotebookStore.didApplyRemoteChangesNotification, object: nil)
        session.refreshPageState()
        XCTAssertNotNil(session.container.editingTextBlock,
                        "a same-page remote refresh must leave the live draft open")

        let manager = session.container.pageUndoManager
        manager.beginUndoGrouping()
        session.finishThroughViewport()
        manager.endUndoGrouping()
        let restored = try XCTUnwrap(model.textBlocks.first)
        XCTAssertNotEqual(restored.id, original.id)
        XCTAssertEqual(restored.text, "The local edit survives under a new ID.")
        XCTAssertTrue(manager.canUndo)
        if manager.canUndo { manager.undo() }
        XCTAssertTrue(model.textBlocks.isEmpty,
                      "Undo must remove the reminted box, not target the tombstoned old ID")
        XCTAssertTrue(manager.canRedo)
        if manager.canRedo { manager.redo() }
        XCTAssertEqual(model.textBlocks.map(\.id), [restored.id])
        XCTAssertTrue(model.saveNow())
        let saved = try store.loadPage(notebookId: notebookId, pageId: pageId)
        XCTAssertEqual(saved.blocks.map(\.id), [restored.id])
        XCTAssertEqual(saved.blocks.first?.text, restored.text)
        XCTAssertTrue(saved.deletedBlocks.contains { $0.id == original.id })
    }
}
