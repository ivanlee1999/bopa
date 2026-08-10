import XCTest
@testable import NotableKit

/// Two engines against one in-memory CouchDB — the iPad and the BOOX, as far as these tests are
/// concerned. Scenarios are the ones that actually went wrong over WebDAV.
final class CouchSyncEngineTests: XCTestCase {

    private var server: MockCouchServer!
    private var ipadStore: FakeLocalStore!
    private var booxStore: FakeLocalStore!
    private var ipad: CouchSyncEngine!
    private var boox: CouchSyncEngine!

    private let pageID = CouchDocID.page("p1")
    private let notebookID = CouchDocID.notebook("nb1")

    override func setUp() {
        super.setUp()
        server = MockCouchServer()
        ipadStore = FakeLocalStore()
        booxStore = FakeLocalStore()
        let client = CouchDBClient(transport: server, database: "notes")
        ipad = CouchSyncEngine(client: client, store: ipadStore, deviceID: "ipad")
        boox = CouchSyncEngine(client: client, store: booxStore, deviceID: "boox")
    }

    // MARK: Fixtures

    private func stroke(_ id: String, at second: Int, device: String) -> CouchStroke {
        CouchStroke(
            id: id, createdAt: stamp(second), updatedAt: stamp(second), deviceId: device,
            pen: "BALLPEN", color: -16_777_216, size: 3,
            top: 0, bottom: 1, left: 0, right: 1, pointsData: "AAA=")
    }

    private func stamp(_ second: Int) -> String {
        NotableDate.format(Date(timeIntervalSince1970: 1_770_000_000 + Double(second)))
    }

    private func page(
        strokes: [CouchStroke] = [], deleted: [CouchTombstone] = [],
        updatedAt: Int, by device: String
    ) -> CouchPage {
        CouchPage(
            notebookId: "nb1", strokes: strokes, deletedStrokes: deleted,
            createdAt: stamp(0), updatedAt: stamp(updatedAt), updatedBy: device)
    }

    // MARK: Tests

    func testPushCreatesDocumentThenPullDeliversItToTheOtherDevice() async throws {
        ipadStore.set(pageID, .page(page(strokes: [stroke("s1", at: 1, device: "ipad")],
                                        updatedAt: 5, by: "ipad")))
        await ipad.markDirty([pageID])

        let flush = await ipad.flush()
        XCTAssertEqual(flush.pushed, [pageID])
        XCTAssertTrue(flush.failures.isEmpty)
        XCTAssertEqual(server.documentIDs(), [pageID])

        let pull = try await boox.pull()
        XCTAssertEqual(pull.applied, [pageID])
        XCTAssertEqual(booxStore.page(pageID)?.strokes.map(\.id), ["s1"])
    }

    func testOwnWriteComingBackOnTheFeedIsNotReapplied() async throws {
        ipadStore.set(pageID, .page(page(strokes: [stroke("s1", at: 1, device: "ipad")],
                                        updatedAt: 5, by: "ipad")))
        await ipad.markDirty([pageID])
        _ = await ipad.flush()

        let pull = try await ipad.pull()
        XCTAssertEqual(pull.skippedEchoes, [pageID])
        XCTAssertTrue(pull.applied.isEmpty)
        // An echo that were applied would mark the document dirty and start a push ping-pong.
        let pending = await ipad.pendingCount
        XCTAssertEqual(pending, 0)
    }

    /// The headline case: both devices draw on the same page with no network, then both sync.
    func testConcurrentOfflineEditsToOnePageUnionRatherThanOverwrite() async throws {
        let shared = page(strokes: [stroke("s0", at: 0, device: "ipad")], updatedAt: 1, by: "ipad")
        ipadStore.set(pageID, .page(shared))
        await ipad.markDirty([pageID])
        _ = await ipad.flush()
        _ = try await boox.pull()

        // Both go offline and draw.
        var ipadPage = ipadStore.page(pageID)!
        ipadPage.strokes.append(stroke("s-ipad", at: 10, device: "ipad"))
        ipadPage.updatedAt = stamp(10)
        ipadPage.updatedBy = "ipad"
        ipadStore.set(pageID, .page(ipadPage))
        await ipad.markDirty([pageID])

        var booxPage = booxStore.page(pageID)!
        booxPage.strokes.append(stroke("s-boox", at: 11, device: "boox"))
        booxPage.updatedAt = stamp(11)
        booxPage.updatedBy = "boox"
        booxStore.set(pageID, .page(booxPage))
        await boox.markDirty([pageID])

        // iPad reaches the server first; the BOOX hits a 409 and merges.
        _ = await ipad.flush()
        let booxFlush = await boox.flush()
        XCTAssertEqual(booxFlush.merged, [pageID], "the BOOX should have merged, not overwritten")

        XCTAssertEqual(booxStore.page(pageID)?.strokes.map(\.id).sorted(),
                       ["s-boox", "s-ipad", "s0"])

        // And the iPad converges on the same content when it next pulls.
        _ = try await ipad.pull()
        XCTAssertEqual(ipadStore.page(pageID)?.strokes.map(\.id).sorted(),
                       ["s-boox", "s-ipad", "s0"])
    }

    /// Drawing on one device while erasing the same stroke on the other: the erase must win, and
    /// must stay won after further syncs.
    func testErasureOnOneDeviceSticksOnTheOther() async throws {
        let shared = page(
            strokes: [stroke("s1", at: 1, device: "ipad"), stroke("s2", at: 2, device: "ipad")],
            updatedAt: 3, by: "ipad")
        ipadStore.set(pageID, .page(shared))
        await ipad.markDirty([pageID])
        _ = await ipad.flush()
        _ = try await boox.pull()

        var erased = booxStore.page(pageID)!
        erased.strokes.removeAll { $0.id == "s2" }
        erased.deletedStrokes = [CouchTombstone(id: "s2", deletedAt: stamp(20))]
        erased.updatedAt = stamp(20)
        erased.updatedBy = "boox"
        booxStore.set(pageID, .page(erased))
        await boox.markDirty([pageID])
        _ = await boox.flush()

        _ = try await ipad.pull()
        XCTAssertEqual(ipadStore.page(pageID)?.strokes.map(\.id), ["s1"])

        // The iPad still had s2 locally a moment ago; re-pushing must not resurrect it.
        await ipad.markDirty([pageID])
        _ = await ipad.flush()
        _ = try await boox.pull()
        XCTAssertEqual(booxStore.page(pageID)?.strokes.map(\.id), ["s1"])
    }

    func testDeletionPropagatesButAnEditAfterItResurrects() async throws {
        let notebook = CouchNotebook(
            title: "notes", pageIds: ["p1"], createdAt: stamp(0), updatedAt: stamp(1),
            updatedBy: "ipad")
        ipadStore.set(notebookID, .notebook(notebook))
        await ipad.markDirty([notebookID])
        _ = await ipad.flush()
        _ = try await boox.pull()

        // BOOX deletes it.
        booxStore.set(notebookID, .deleted(CouchDeletedDoc(
            type: CouchDocType.notebook, deletedAt: stamp(10), updatedBy: "boox")))
        await boox.markDirty([notebookID])
        _ = await boox.flush()
        XCTAssertTrue(server.isDeleted(notebookID))

        _ = try await ipad.pull()
        XCTAssertTrue(ipadStore.body(notebookID)?.isDeleted ?? false)

        // A different notebook, edited *after* a delete, comes back instead.
        let otherID = CouchDocID.notebook("nb2")
        ipadStore.set(otherID, .notebook(CouchNotebook(
            title: "kept", pageIds: [], createdAt: stamp(0), updatedAt: stamp(1),
            updatedBy: "ipad")))
        await ipad.markDirty([otherID])
        _ = await ipad.flush()
        _ = try await boox.pull()

        booxStore.set(otherID, .deleted(CouchDeletedDoc(
            type: CouchDocType.notebook, deletedAt: stamp(20), updatedBy: "boox")))
        await boox.markDirty([otherID])
        _ = await boox.flush()

        var edited = ipadStore.notebook(otherID)!
        edited.title = "edited after the delete"
        edited.updatedAt = stamp(30)
        ipadStore.set(otherID, .notebook(edited))
        await ipad.markDirty([otherID])
        let flush = await ipad.flush()

        XCTAssertEqual(flush.merged, [otherID])
        XCTAssertEqual(ipadStore.notebook(otherID)?.title, "edited after the delete")
        XCTAssertFalse(server.isDeleted(otherID), "the newer edit should have resurrected it")
    }

    func testOfflineEditsQueueAndDrainOnReconnect() async throws {
        server.isOffline = true
        ipadStore.set(pageID, .page(page(strokes: [stroke("s1", at: 1, device: "ipad")],
                                        updatedAt: 5, by: "ipad")))
        await ipad.markDirty([pageID])

        let offlineFlush = await ipad.flush()
        XCTAssertEqual(offlineFlush.stillDirty, [pageID])
        XCTAssertTrue(offlineFlush.pushed.isEmpty)
        var pending = await ipad.pendingCount
        XCTAssertEqual(pending, 1, "work must survive being offline")

        server.isOffline = false
        let onlineFlush = await ipad.flush()
        XCTAssertEqual(onlineFlush.pushed, [pageID])
        pending = await ipad.pendingCount
        XCTAssertEqual(pending, 0)
    }

    /// A lost checkpoint replays the whole feed. Because merges are idempotent that has to be a
    /// slow no-op, not a source of duplicates or spurious conflicts.
    func testReplayingTheFeedFromZeroIsANoOp() async throws {
        ipadStore.set(pageID, .page(page(strokes: [stroke("s1", at: 1, device: "ipad")],
                                        updatedAt: 5, by: "ipad")))
        await ipad.markDirty([pageID])
        _ = await ipad.flush()
        _ = try await boox.pull()
        let before = booxStore.page(pageID)

        let replayed = CouchSyncEngine(
            client: CouchDBClient(transport: server, database: "notes"),
            store: booxStore, deviceID: "boox", state: CouchSyncState())
        let report = try await replayed.pull()

        XCTAssertEqual(report.applied, [pageID])
        XCTAssertEqual(booxStore.page(pageID), before, "replay changed content")
        XCTAssertTrue(report.pushBack.isEmpty, "replay should not think we are ahead of the server")
    }

    /// Local content the server has not seen must be pushed back rather than quietly dropped.
    func testPullQueuesAPushBackWhenTheLocalCopyHasMore() async throws {
        server.seed(pageID, page(strokes: [stroke("s-remote", at: 2, device: "boox")],
                                 updatedAt: 6, by: "boox"))
        ipadStore.set(pageID, .page(page(strokes: [stroke("s-local", at: 1, device: "ipad")],
                                        updatedAt: 5, by: "ipad")))

        let report = try await ipad.pull()
        XCTAssertEqual(report.pushBack, [pageID])
        XCTAssertEqual(ipadStore.page(pageID)?.strokes.map(\.id).sorted(), ["s-local", "s-remote"])

        let flush = await ipad.flush()
        XCTAssertEqual(flush.pushed, [pageID])
    }

    func testDocumentFromANewerSchemaBecomesAConflictCopy() async throws {
        server.seedRaw(pageID, [
            "type": "page", "schema": 99, "notebookId": "nb1",
            "createdAt": stamp(0), "updatedAt": stamp(5), "updatedBy": "boox",
            "strokes": [], "somethingNew": ["shape": "unknown"],
        ])

        let report = try await ipad.pull()
        XCTAssertEqual(report.conflictCopies, [pageID])
        XCTAssertEqual(ipadStore.conflictCopies, [pageID])
        XCTAssertNil(ipadStore.page(pageID), "a future document must not be decoded as if understood")
    }

    func testNotebooksArePushedAfterTheirPages() async throws {
        ipadStore.set(pageID, .page(page(updatedAt: 5, by: "ipad")))
        ipadStore.set(notebookID, .notebook(CouchNotebook(
            title: "notes", pageIds: ["p1"], createdAt: stamp(0), updatedAt: stamp(5),
            updatedBy: "ipad")))
        ipadStore.set(CouchDocID.folder("f1"), .folder(CouchFolder(
            title: "school", createdAt: stamp(0), updatedAt: stamp(5), updatedBy: "ipad")))
        await ipad.markDirty([notebookID, pageID, CouchDocID.folder("f1")])

        _ = await ipad.flush()

        let puts = server.requestLog.filter { $0.method == "PUT" }.map(\.path)
        let pageIndex = puts.firstIndex { $0.contains("page:") }
        let notebookIndex = puts.firstIndex { $0.contains("notebook:") }
        let folderIndex = puts.firstIndex { $0.contains("folder:") }
        XCTAssertNotNil(pageIndex)
        XCTAssertNotNil(notebookIndex)
        XCTAssertLessThan(folderIndex!, notebookIndex!)
        XCTAssertLessThan(pageIndex!, notebookIndex!,
                          "a notebook must never land before the pages it names")
    }

    /// A wiped local database looks exactly like "the user deleted everything"; the guard makes
    /// the difference a human decision rather than a silent mass delete.
    func testMassDeletionIsRefusedRatherThanPushed() async throws {
        var ids: [String] = []
        for index in 0..<12 {
            let id = CouchDocID.notebook("nb\(index)")
            ids.append(id)
            ipadStore.set(id, .deleted(CouchDeletedDoc(
                type: CouchDocType.notebook, deletedAt: stamp(10), updatedBy: "ipad")))
        }
        await ipad.markDirty(ids)

        let report = await ipad.flush()
        XCTAssertTrue(report.blockedByDeletionGuard)
        XCTAssertTrue(report.pushed.isEmpty)
        XCTAssertTrue(server.documentIDs().isEmpty, "nothing should have reached the server")
    }

    func testUnauthorizedStopsImmediatelyAndKeepsWork() async throws {
        server.failingDocumentIDs[pageID] = 401
        ipadStore.set(pageID, .page(page(updatedAt: 5, by: "ipad")))
        await ipad.markDirty([pageID])

        let report = await ipad.flush()
        XCTAssertEqual(report.stillDirty, [pageID])
        XCTAssertEqual(report.failures[pageID], String(describing: CouchError.unauthorized))
        let pending = await ipad.pendingCount
        XCTAssertEqual(pending, 1)
    }
}
