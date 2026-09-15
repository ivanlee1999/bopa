import NotableKit
import PencilKit
import UIKit
import XCTest

@testable import Bopa

/// Creating, typing into, moving and deleting a text box — and what each of those owes the
/// merge. A box is a `kind: "md"` block carrying its own coordinates, so every rule the sync
/// protocol has for blocks applies to it: a local delete has to leave a tombstone, and every
/// edit has to carry a clock the other device can lose to.
@MainActor
final class TextBoxEditingTests: XCTestCase {
    private var rootURL: URL!
    private var store: NotebookStore!
    private var notebookId = ""

    override func setUp() async throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("bopa-textbox-test-\(UUID().uuidString)")
        store = NotebookStore(rootURL: rootURL)
        notebookId = try store.createNotebook(title: "Notes").notebookId
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: rootURL)
    }

    private func openedModel() -> EditorPageModel {
        let model = EditorPageModel()
        model.attach(store: store, notebookId: notebookId)
        model.openInitialPage()
        return model
    }

    private func reloadPage(_ model: EditorPageModel) throws -> PageFile {
        try store.loadPage(notebookId: notebookId, pageId: model.pageId!)
    }

    /// Types `text` into a fresh box and flushes, returning the block as it was written.
    @discardableResult
    private func typeBox(
        _ model: EditorPageModel, _ text: String, at point: CGPoint = CGPoint(x: 100, y: 200)
    ) throws -> CouchBlock {
        let box = try XCTUnwrap(model.newTextBlock(at: point))
        model.beginEditing(box)
        model.commitEditing(box, text: text)
        XCTAssertTrue(model.saveNow())
        return try XCTUnwrap(reloadPage(model).blocks.first { $0.id == box.id })
    }

    // MARK: Creating

    func testACommittedBoxIsWrittenAsAPositionedMarkdownBlock() throws {
        let model = openedModel()
        let written = try typeBox(model, "# Groceries")

        XCTAssertEqual(written.kind, "md")
        XCTAssertEqual(written.text, "# Groceries")
        XCTAssertEqual(written.x, 100)
        XCTAssertEqual(written.y, 200)
        XCTAssertNotNil(written.width)
        XCTAssertNotNil(written.height)
        XCTAssertFalse(written.isFlowing, "a text box carries its own place on the page")
        // Empty is legal and sorts first. A positioned block is not in the page's flow, so
        // there is no order for two devices to disagree about and nothing to mint.
        XCTAssertEqual(written.orderKey, "")
        XCTAssertEqual(written.deviceId, CouchSettings.load().deviceID)
    }

    func testAnEmptyBoxIsNeverWritten() throws {
        let model = openedModel()
        let box = try XCTUnwrap(model.newTextBlock(at: CGPoint(x: 10, y: 10)))
        model.beginEditing(box)
        model.commitEditing(box, text: "   \n  ")
        XCTAssertTrue(model.saveNow())

        XCTAssertTrue(try reloadPage(model).blocks.isEmpty)
        XCTAssertTrue(model.textBlocks.isEmpty)
        XCTAssertNil(model.editingBlockID)
    }

    func testANewBoxIsNotOnThePageUntilItIsCommitted() throws {
        let model = openedModel()
        let box = try XCTUnwrap(model.newTextBlock(at: CGPoint(x: 10, y: 10)))
        model.beginEditing(box)
        XCTAssertTrue(model.textBlocks.isEmpty, "an empty box is not content")
        model.cancelEditing()
        XCTAssertTrue(model.saveNow())
        XCTAssertTrue(try reloadPage(model).blocks.isEmpty)
    }

    func testABoxStartsOnThePaperAndInsideTheRightMargin() throws {
        let model = openedModel()
        let sheet = model.page!.pageSize
        let box = try XCTUnwrap(
            model.newTextBlock(at: CGPoint(x: CGFloat(sheet.width) + 500, y: -40)))
        XCTAssertGreaterThanOrEqual(box.y!, 0)
        XCTAssertLessThan(box.x!, sheet.width)
        XCTAssertGreaterThanOrEqual(box.width!, Int(TextBoxMetrics.standard.minimumWidth))
    }

    // MARK: Editing

    func testHeightFollowsTheTextAndTheWidth() throws {
        let model = openedModel()
        let short = try typeBox(model, "one")
        let box = try XCTUnwrap(model.textBlocks.first)
        model.commitEditing(box, text: "one\ntwo\nthree\nfour")
        XCTAssertTrue(model.saveNow())
        let tall = try XCTUnwrap(reloadPage(model).blocks.first { $0.id == short.id })
        XCTAssertGreaterThan(tall.height!, short.height!)

        model.resizeTextBlock(id: short.id, width: TextBoxMetrics.standard.minimumWidth)
        XCTAssertTrue(model.saveNow())
        let narrow = try XCTUnwrap(reloadPage(model).blocks.first { $0.id == short.id })
        XCTAssertEqual(narrow.width!, Int(TextBoxMetrics.standard.minimumWidth))
        XCTAssertGreaterThan(narrow.height!, tall.height!, "a narrower box wraps to more lines")
    }

    func testEveryEditStampsAFreshClock() throws {
        let model = openedModel()
        let first = try typeBox(model, "before")
        let box = try XCTUnwrap(model.textBlocks.first)
        model.commitEditing(box, text: "after")
        XCTAssertTrue(model.saveNow())
        let second = try XCTUnwrap(reloadPage(model).blocks.first { $0.id == first.id })
        // The merge is whole-element last-writer-wins on `updatedAt`. An edit that forgot to
        // bump it would silently lose to the very copy it was editing.
        XCTAssertGreaterThanOrEqual(second.updatedAt, first.updatedAt)
        XCTAssertEqual(second.createdAt, first.createdAt)
        XCTAssertEqual(second.text, "after")
    }

    func testMovingABoxKeepsItOnThePaper() throws {
        let model = openedModel()
        let written = try typeBox(model, "note")
        model.moveTextBlock(id: written.id, to: CGPoint(x: 40, y: -10))
        XCTAssertTrue(model.saveNow())
        let moved = try XCTUnwrap(reloadPage(model).blocks.first { $0.id == written.id })
        XCTAssertEqual(moved.x, 40)
        XCTAssertEqual(moved.y, 0)
    }

    // MARK: Deleting

    func testDeletingABoxLeavesATombstone() throws {
        let model = openedModel()
        let written = try typeBox(model, "delete me")
        model.deleteTextBlock(id: written.id)
        XCTAssertTrue(model.saveNow())

        let after = try reloadPage(model)
        XCTAssertTrue(after.blocks.isEmpty)
        // Without the tombstone, absence alone cannot be told from "that block has not reached
        // this device yet", and the peer's copy would return on the next merge.
        XCTAssertEqual(after.deletedBlocks.map(\.id), [written.id])
    }

    func testTypingNothingIntoAnExistingBoxDeletesIt() throws {
        let model = openedModel()
        let written = try typeBox(model, "temporary")
        let box = try XCTUnwrap(model.textBlocks.first)
        model.commitEditing(box, text: "")
        XCTAssertTrue(model.saveNow())

        let after = try reloadPage(model)
        XCTAssertTrue(after.blocks.isEmpty)
        XCTAssertEqual(after.deletedBlocks.map(\.id), [written.id])
    }

    // MARK: Against the other device

    func testABoxArrivingFromThePeerIsNotDeletedByTheNextLocalSave() throws {
        let model = openedModel()
        let mine = try typeBox(model, "mine")

        // The BOOX writes its own box into the file underneath the open editor.
        var onDisk = try reloadPage(model)
        let theirs = CouchBlock(
            id: "boox-box", kind: "md", orderKey: "", text: "theirs",
            x: 10, y: 800, width: 400, height: 60,
            createdAt: "2026-01-01T00:00:00.000Z", updatedAt: "2026-01-01T00:00:00.000Z",
            deviceId: "boox")
        onDisk.blocks.append(theirs)
        _ = try store.savePage(onDisk)

        // The editor hears about it, then saves for an unrelated reason.
        NotificationCenter.default.post(
            name: NotebookStore.didApplyRemoteChangesNotification, object: nil)
        model.moveTextBlock(id: mine.id, to: CGPoint(x: 5, y: 5))
        XCTAssertTrue(model.saveNow())

        let after = try reloadPage(model)
        XCTAssertEqual(after.blocks.count, 2)
        XCTAssertTrue(after.deletedBlocks.isEmpty, "nothing was deleted, so nothing is tombstoned")
        XCTAssertEqual(model.textBlocks.count, 2)
    }

    func testRetypingABoxThePeerDeletedMintsAFreshID() throws {
        let model = openedModel()
        let written = try typeBox(model, "contested")
        let box = try XCTUnwrap(model.textBlocks.first)
        model.beginEditing(box)

        // While it is being typed into, the other device deletes it.
        var onDisk = try reloadPage(model)
        onDisk.blocks.removeAll { $0.id == written.id }
        onDisk.deletedBlocks.append(
            CouchTombstone(id: written.id, deletedAt: SyncClock.shared.stamp()))
        _ = try store.savePage(onDisk)
        NotificationCenter.default.post(
            name: NotebookStore.didApplyRemoteChangesNotification, object: nil)

        model.commitEditing(box, text: "typed anyway")
        XCTAssertTrue(model.saveNow())

        let after = try reloadPage(model)
        let survivor = try XCTUnwrap(after.blocks.first)
        // Keeping the old id would hand the typing to a tombstone and lose it on the next merge.
        XCTAssertNotEqual(survivor.id, written.id)
        XCTAssertEqual(survivor.text, "typed anyway")
    }

    // MARK: Projection

    func testOnlyPositionedMarkdownBlocksReachTheCanvas() throws {
        let model = openedModel()
        var onDisk = try reloadPage(model)
        onDisk.blocks = [
            CouchBlock(
                id: "flowing", kind: "md", orderKey: "a0", text: "a paragraph",
                createdAt: "2026-01-01T00:00:00.000Z", updatedAt: "2026-01-01T00:00:00.000Z"),
            CouchBlock(
                id: "picture", kind: "image", orderKey: "", imageAssetId: "asset:abc",
                x: 0, y: 0, width: 10, height: 10,
                createdAt: "2026-01-01T00:00:00.000Z", updatedAt: "2026-01-01T00:00:00.000Z"),
        ]
        _ = try store.savePage(onDisk)

        let reopened = EditorPageModel()
        reopened.attach(store: store, notebookId: notebookId)
        reopened.openInitialPage()
        XCTAssertTrue(reopened.textBlocks.isEmpty)
        // Carried through the file untouched, though: this app has no UI for either, and
        // dropping them would delete the other device's work.
        XCTAssertEqual(reopened.page?.blocks.count, 2)
    }
}
