import os
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

    /// Computing a merge takes a network round trip, and the pen does not stop for it. A stroke
    /// saved while a push was in flight used to read as "present locally but absent from the merge
    /// result" and be dropped — no tombstone written, nothing left dirty, so the ink was gone from
    /// the page *and* never pushed. The merge may only drop what the merge itself saw.
    func testInkSavedWhileAPushIsInFlightSurvivesTheMerge() async throws {
        let shared = page(strokes: [stroke("s0", at: 0, device: "ipad")], updatedAt: 1, by: "ipad")
        ipadStore.set(pageID, .page(shared))
        await ipad.markDirty([pageID])
        _ = await ipad.flush()
        _ = try await boox.pull()

        // The BOOX writes first, so the iPad's next push takes a 409 and has to merge.
        var booxPage = booxStore.page(pageID)!
        booxPage.strokes.append(stroke("s-boox", at: 11, device: "boox"))
        booxPage.updatedAt = stamp(11)
        booxPage.updatedBy = "boox"
        booxStore.set(pageID, .page(booxPage))
        await boox.markDirty([pageID])
        _ = await boox.flush()

        var drawing = ipadStore.page(pageID)!
        drawing.strokes.append(stroke("s-ipad", at: 10, device: "ipad"))
        drawing.updatedAt = stamp(10)
        drawing.updatedBy = "ipad"
        ipadStore.set(pageID, .page(drawing))
        await ipad.markDirty([pageID])

        // The user goes on drawing *during* the merge round trip: the store hands the engine its
        // snapshot, and a further stroke lands before `apply` is called.
        let store = ipadStore!
        let id = pageID
        let mid = stroke("s-midflight", at: 12, device: "ipad")
        let midStamp = stamp(12)
        // A flush reads the page more than once — once to work out the push order, then again in
        // `push` itself. It is that second read the merge is built from, so that is the one the
        // stroke has to land just after; interrupting the first would simply put it in the snapshot.
        let loads = OSAllocatedUnfairLock(initialState: 0)
        store.onLoad = { [weak store] in
            let nth = loads.withLock { count -> Int in
                count += 1
                return count
            }
            guard nth == 2, let store, var page = store.page(id) else { return }
            page.strokes.append(mid)
            page.updatedAt = midStamp
            store.set(id, .page(page))
        }

        _ = await ipad.flush()
        store.onLoad = nil
        XCTAssertGreaterThanOrEqual(loads.withLock { $0 }, 2, "the push should have re-read the page")

        XCTAssertTrue(
            ipadStore.page(pageID)!.strokes.map(\.id).contains("s-midflight"),
            "the stroke saved during the merge must not be dropped")
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

    /// The other half of delete-vs-edit, and the one that used to lose the deletion.
    ///
    /// A plain `GET` of a deleted document is a 404 — CouchDB does not hand the tombstone back
    /// there — so a pusher that read 404 as "never existed" retried as a create, and a PUT with no
    /// revision over a tombstone *succeeds*: the peer's deletion silently came back as a live
    /// notebook. Then, once the tombstone is read correctly, the merge resolves to it, and writing
    /// that tombstone back is itself a 409 — so the id has to leave the outbox without a write.
    func testPeersDeletionSurvivesAnOlderLocalEditWaitingToBePushed() async throws {
        ipadStore.set(notebookID, .notebook(CouchNotebook(
            title: "notes", pageIds: [], createdAt: stamp(0), updatedAt: stamp(1),
            updatedBy: "ipad")))
        await ipad.markDirty([notebookID])
        _ = await ipad.flush()
        _ = try await boox.pull()

        // The iPad renames it offline...
        var renamed = ipadStore.notebook(notebookID)!
        renamed.title = "renamed on the iPad"
        renamed.updatedAt = stamp(10)
        ipadStore.set(notebookID, .notebook(renamed))
        await ipad.markDirty([notebookID])

        // ...while the BOOX deletes it, later, and gets there first.
        booxStore.set(notebookID, .deleted(CouchDeletedDoc(
            type: CouchDocType.notebook, deletedAt: stamp(20), updatedBy: "boox")))
        await boox.markDirty([notebookID])
        _ = await boox.flush()

        let flush = await ipad.flush()

        XCTAssertTrue(flush.failures.isEmpty, "the push should settle, not exhaust its retries")
        XCTAssertTrue(flush.stillDirty.isEmpty, "the document must leave the outbox")
        let pending = await ipad.pendingCount
        XCTAssertEqual(pending, 0)
        XCTAssertTrue(
            ipadStore.body(notebookID)?.isDeleted ?? false,
            "the iPad should have accepted the deletion rather than re-created the notebook")
        XCTAssertTrue(server.isDeleted(notebookID), "the deletion must still stand on the server")
    }

    /// Two people tidying up at once. Both delete the same notebook while apart, so the merge is
    /// tombstone against tombstone — and it settles on the earliest `deletedAt` with the *later*
    /// `updatedAt`/`updatedBy`, which is a different document from the one the server stored even
    /// though it records the identical deletion. Plain equality therefore said "still to send", and
    /// re-deleting an already deleted document is a 409 no matter which revision it carries: the id
    /// burned its retries and stayed in the outbox for good.
    func testBothDevicesDeletingTheSameNotebookSettlesRatherThanRetryingForever() async throws {
        ipadStore.set(notebookID, .notebook(CouchNotebook(
            title: "notes", pageIds: [], createdAt: stamp(0), updatedAt: stamp(1),
            updatedBy: "ipad")))
        await ipad.markDirty([notebookID])
        _ = await ipad.flush()
        _ = try await boox.pull()

        // The BOOX deletes first and reaches the server; the iPad deletes the same notebook a
        // moment later, knowing nothing about it.
        booxStore.set(notebookID, .deleted(CouchDeletedDoc(
            type: CouchDocType.notebook, deletedAt: stamp(10), updatedBy: "boox")))
        await boox.markDirty([notebookID])
        _ = await boox.flush()

        ipadStore.set(notebookID, .deleted(CouchDeletedDoc(
            type: CouchDocType.notebook, deletedAt: stamp(12), updatedBy: "ipad")))
        await ipad.markDirty([notebookID])

        let flush = await ipad.flush()

        XCTAssertTrue(flush.failures.isEmpty, "agreeing with the peer is not a failure")
        XCTAssertTrue(flush.stillDirty.isEmpty, "the document must leave the outbox")
        let pending = await ipad.pendingCount
        XCTAssertEqual(pending, 0)
        XCTAssertTrue(server.isDeleted(notebookID), "the deletion must still stand on the server")

        // And it stays settled: a later flush has nothing to offer rather than starting again.
        server.forgetRequests()
        let again = await ipad.flush()
        XCTAssertTrue(again.stillDirty.isEmpty)
        XCTAssertFalse(server.requestLog.contains { $0.method == "PUT" })
    }

    /// A `200` from `open_revs=all` that cannot be read must be reported, not read as "the document
    /// is absent" — absent is what sends the pusher back round as a create, and a create over a
    /// tombstone resurrects it. Failing keeps the work dirty, which is the safe direction.
    func testAnUnreadableTombstoneFetchFailsRatherThanReadingAsAbsent() async throws {
        let client = CouchDBClient(transport: NonsenseOnOpenRevs(), database: "notes")
        do {
            _ = try await client.getRaw(CouchDocID.notebook("nb1"))
            XCTFail("an unreadable revision list should not come back as nil")
        } catch let error as CouchError {
            guard case .malformedResponse = error else {
                return XCTFail("expected a malformed-response error, got \(error)")
            }
        }
    }

    /// 404 on the plain GET (the document is deleted), then a 200 whose body is not a revision list.
    private struct NonsenseOnOpenRevs: HTTPTransport {
        func send(_ request: HTTPRequest) async throws -> HTTPResponse {
            guard request.query.contains(where: { $0.name == "open_revs" }) else {
                return HTTPResponse(status: 404)
            }
            return HTTPResponse(status: 200, body: Data("{\"error\":\"nope\"}".utf8))
        }
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

    // MARK: Images

    private let picture = Data("the bytes of a picture".utf8)
    private var pictureID: String { CouchAssetID.forBytes(picture) }

    private func pageWithPicture(updatedAt: Int, by device: String) -> CouchPage {
        var page = page(updatedAt: updatedAt, by: device)
        page.images = [CouchImage(
            id: "i1", assetId: pictureID, x: 0, y: 0, width: 4, height: 4,
            createdAt: stamp(1), updatedAt: stamp(1))]
        return page
    }

    /// Nobody queues an asset — the app only ever edits a page. The bytes are derived from the
    /// page being sent, and they go first, so the peer never reads a reference to nothing.
    func testAnImagesBytesAreSentBeforeThePageThatPlacesThem() async throws {
        ipadStore.set(pageID, .page(pageWithPicture(updatedAt: 5, by: "ipad")))
        ipadStore.set(pictureID, .asset(CouchAsset(
            data: picture, at: stamp(1), updatedBy: "ipad")))
        await ipad.markDirty([pageID])

        let flush = await ipad.flush()
        XCTAssertEqual(flush.pushed, [pictureID, pageID])

        let puts = server.requestLog.filter { $0.method == "PUT" }.map(\.path)
        XCTAssertLessThan(
            puts.firstIndex { $0.contains("asset:") }!, puts.firstIndex { $0.contains("page:") }!)
    }

    /// Content-addressed means an id can only ever hold one thing. A second device offering the
    /// same picture is told 409, and that is the upload succeeding.
    func testTheSamePictureFromTwoDevicesIsNotAConflict() async throws {
        for (engine, store, device) in [(ipad!, ipadStore!, "ipad"), (boox!, booxStore!, "boox")] {
            store.set(pageID, .page(pageWithPicture(updatedAt: 5, by: device)))
            store.set(pictureID, .asset(CouchAsset(
                data: picture, at: stamp(1), updatedBy: device)))
            await engine.markDirty([pageID])
        }

        _ = await ipad.flush()
        let second = await boox.flush()
        XCTAssertTrue(second.failures.isEmpty, "a duplicate upload is not a failure")
        XCTAssertTrue(second.pushed.contains(pictureID))

        // And a third attempt does not even reach the wire: the revision says it is already there.
        server.forgetRequests()
        await boox.markDirty([pageID])
        _ = await boox.flush()
        XCTAssertFalse(server.requestLog.contains { $0.path.contains("asset:") })
    }

    /// The other half: a page arrives naming a picture, and the bytes have to follow.
    func testPullFetchesTheBytesOfAPictureThePageNames() async throws {
        ipadStore.set(pageID, .page(pageWithPicture(updatedAt: 5, by: "ipad")))
        ipadStore.set(pictureID, .asset(CouchAsset(
            data: picture, at: stamp(1), updatedBy: "ipad")))
        await ipad.markDirty([pageID])
        _ = await ipad.flush()

        let pulled = try await boox.pull()
        XCTAssertEqual(pulled.fetchedAssets, [pictureID])
        guard case .asset(let held)? = booxStore.body(pictureID) else {
            return XCTFail("the picture never arrived")
        }
        XCTAssertEqual(held.data, picture)
        XCTAssertEqual(held.contentType, "application/octet-stream")

        // Nothing left owed, so the next pull does not go asking again.
        server.forgetRequests()
        _ = try await boox.pull()
        XCTAssertFalse(server.requestLog.contains { $0.path.hasSuffix("/blob") })
    }

    /// A download that fails is retried, not forgotten: the reference stays owed.
    func testAPictureThatCouldNotBeFetchedIsTriedAgainOnTheNextPull() async throws {
        ipadStore.set(pageID, .page(pageWithPicture(updatedAt: 5, by: "ipad")))
        ipadStore.set(pictureID, .asset(CouchAsset(
            data: picture, at: stamp(1), updatedBy: "ipad")))
        await ipad.markDirty([pageID])
        _ = await ipad.flush()

        server.failingDocumentIDs["\(pictureID)/blob"] = 503
        var pulled = try await boox.pull()
        XCTAssertEqual(pulled.fetchedAssets, [])
        XCTAssertNil(booxStore.body(pictureID))
        XCTAssertEqual(try booxStore.missingAssetIDs(), [pictureID])

        server.failingDocumentIDs.removeAll()
        pulled = try await boox.pull()
        XCTAssertEqual(pulled.fetchedAssets, [pictureID])
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
        XCTAssertEqual(report.heldDeletions.sorted(), ids.sorted())
        XCTAssertTrue(report.pushed.isEmpty)
        XCTAssertTrue(server.documentIDs().isEmpty, "nothing should have reached the server")
    }

    /// The guard asks whether these deletions are most of the library. It used to ask that of
    /// `revs`, which is never pruned — so a device that had seen a hundred notebooks come and go
    /// counted all hundred, and deleting the ten it actually had left no longer looked like most of
    /// anything. A guard that grows unable to trip is worse than none, since it still reads as one.
    func testTheDeletionGuardMeasuresAgainstWhatTheDeviceHoldsNotWhatItHasEverSeen() async throws {
        // Two hundred notebooks this device pushed and has since stopped holding. They are gone
        // from the library but still named in `revs`, which nothing prunes.
        var old: [String] = []
        for index in 0..<200 {
            let id = CouchDocID.notebook("old\(index)")
            old.append(id)
            ipadStore.set(id, .notebook(CouchNotebook(
                title: "old", pageIds: [], createdAt: stamp(0), updatedAt: stamp(1),
                updatedBy: "ipad")))
        }
        await ipad.markDirty(old)
        _ = await ipad.flush()
        for id in old { ipadStore.remove(id) }

        var ids: [String] = []
        for index in 0..<12 {
            let id = CouchDocID.notebook("nb\(index)")
            ids.append(id)
            ipadStore.set(id, .deleted(CouchDeletedDoc(
                type: CouchDocType.notebook, deletedAt: stamp(10), updatedBy: "ipad")))
        }
        await ipad.markDirty(ids)

        let report = await ipad.flush()
        XCTAssertTrue(report.blockedByDeletionGuard, "wiping the whole library should still ask")
    }

    /// The guard exists to question a suspicious *deletion*. Stopping the rest of the queue with it
    /// meant a drawing could not sync either — and since the confirmation the warning asks for does
    /// not exist yet, that was a permanent stall rather than a prompt.
    func testTheDeletionGuardDoesNotHoldBackOrdinaryEdits() async throws {
        var ids: [String] = []
        for index in 0..<12 {
            let id = CouchDocID.notebook("nb\(index)")
            ids.append(id)
            ipadStore.set(id, .deleted(CouchDeletedDoc(
                type: CouchDocType.notebook, deletedAt: stamp(10), updatedBy: "ipad")))
        }
        ipadStore.set(pageID, .page(page(strokes: [stroke("s1", at: 1, device: "ipad")],
                                         updatedAt: 5, by: "ipad")))
        ids.append(pageID)
        await ipad.markDirty(ids)

        let report = await ipad.flush()
        XCTAssertTrue(report.blockedByDeletionGuard)
        XCTAssertEqual(report.pushed, [pageID], "the drawing should still have gone out")
        XCTAssertEqual(server.documentIDs(), [pageID])
        XCTAssertFalse(report.stillDirty.contains(pageID))
    }

    /// The guard is a question, so there has to be an answer. "Yes, delete them on the server too"
    /// sends exactly the ids that were approved — and nothing else, because the approval is about
    /// the batch someone looked at rather than about deletions in general.
    func testApprovingHeldDeletionsSendsExactlyThoseOnTheNextFlush() async throws {
        let ids = deleteTwelveNotebooks()
        await ipad.markDirty(ids)

        let held = await ipad.flush()
        XCTAssertEqual(held.heldDeletions.sorted(), ids.sorted())

        let approved = Array(ids.prefix(10))
        await ipad.approveHeldDeletions(approved)
        let report = await ipad.flush()

        XCTAssertEqual(report.pushed.sorted(), approved.sorted())
        XCTAssertEqual(server.documentIDs(), approved.sorted())
        XCTAssertTrue(approved.allSatisfy { server.isDeleted($0) },
                      "the approved ids should have gone out as tombstones")
        // The two nobody spoke for are still on hold, in the same flush that sent the other ten.
        XCTAssertTrue(report.blockedByDeletionGuard)
        XCTAssertEqual(report.heldDeletions.sorted(), ids.suffix(2).sorted())
    }

    /// "Keep them on the server" is the recovery path for a device that lost its library: the
    /// tombstones are dropped rather than published, so the server's copies survive and come back
    /// on the next pull. Nothing is sent, and nothing is left queued to send later.
    func testDiscardingHeldDeletionsDropsTheTombstonesWithoutSendingAnything() async throws {
        let ids = deleteTwelveNotebooks()
        await ipad.markDirty(ids)
        let held = await ipad.flush()

        await ipad.discardHeldDeletions(held.heldDeletions)

        XCTAssertTrue(ids.allSatisfy { ipadStore.body($0) == nil },
                      "the recorded deletions should be gone from the store")
        let pending = await ipad.pendingCount
        XCTAssertEqual(pending, 0, "and out of the outbox, so no later flush reproduces them")

        let report = await ipad.flush()
        XCTAssertFalse(report.blockedByDeletionGuard)
        XCTAssertTrue(report.pushed.isEmpty)
        XCTAssertTrue(server.documentIDs().isEmpty, "the server should still hold the notebooks")
    }

    /// The other half of "keep them on the server": they have to actually come back. Dropping the
    /// tombstones alone would leave the notebooks gone here, present there, and unreachable —
    /// `_changes` never re-announces a document that has not changed, and declining to publish a
    /// deletion changes nothing. The discard rewinds the checkpoint and forgets the ids' revisions
    /// so the feed replays them, which is what makes the promise in the UI true.
    func testDiscardingHeldDeletionsBringsTheNotebooksBackOnTheNextPull() async throws {
        // The device had a library and so does the server: the state a wiped database starts from.
        let ids = (0..<12).map { CouchDocID.notebook("nb\($0)") }
        for (index, id) in ids.enumerated() {
            ipadStore.set(id, .notebook(CouchNotebook(
                title: "notebook \(index)", pageIds: [], createdAt: stamp(0),
                updatedAt: stamp(1), updatedBy: "ipad")))
        }
        await ipad.markDirty(ids)
        _ = await ipad.flush()
        // Caught up, the way a device that has been syncing normally would be.
        _ = try await ipad.pull()

        // Now the local library vanishes and every notebook turns into a tombstone.
        for id in ids {
            ipadStore.set(id, .deleted(CouchDeletedDoc(
                type: CouchDocType.notebook, deletedAt: stamp(10), updatedBy: "ipad")))
        }
        await ipad.markDirty(ids)
        let held = await ipad.flush()
        XCTAssertEqual(held.heldDeletions.sorted(), ids.sorted())

        await ipad.discardHeldDeletions(held.heldDeletions)
        let pull = try await ipad.pull()

        XCTAssertEqual(pull.applied.sorted(), ids.sorted(), "the whole library should have replayed")
        XCTAssertTrue(pull.skippedEchoes.isEmpty,
                      "the recorded revisions must not make the replay look like this device's echo")
        for (index, id) in ids.enumerated() {
            XCTAssertEqual(ipadStore.notebook(id)?.title, "notebook \(index)",
                           "the notebook should be live again, with its title")
        }
        XCTAssertTrue(ids.allSatisfy { !server.isDeleted($0) },
                      "and nothing should have been deleted on the server")
    }

    /// One tap must not disarm the guard. An approval is consumed by the flush that acts on it and
    /// names only the ids it was given, so the *next* suspicious batch is asked about afresh —
    /// which is the difference between answering a question and turning a safety off.
    func testApprovingOneBatchDoesNotApproveTheNext() async throws {
        let first = deleteTwelveNotebooks()
        await ipad.markDirty(first)
        _ = await ipad.flush()
        await ipad.approveHeldDeletions(first)
        let sent = await ipad.flush()
        XCTAssertEqual(sent.pushed.sorted(), first.sorted())
        // Reaped the way a store drops a tombstone once it is published, so the second batch is
        // measured against a library that no longer counts the first.
        for id in first { ipadStore.remove(id) }

        let second = deleteTwelveNotebooks(prefix: "later")
        await ipad.markDirty(second)
        let report = await ipad.flush()

        XCTAssertTrue(report.blockedByDeletionGuard, "the second batch should be asked about too")
        XCTAssertEqual(report.heldDeletions.sorted(), second.sorted())
        XCTAssertTrue(report.pushed.isEmpty)
        XCTAssertTrue(second.allSatisfy { !server.documentIDs().contains($0) })
    }

    /// The engine-level twin of scenario 23, `ink-only-edit-resurrects` — protocol §6.4 and §5.5.
    ///
    /// The peer's later edit is a stroke and nothing else. What saves the notebook is that an ink
    /// save also bumps the owning notebook's `updatedAt`, which §6.4 reads as liveness: the
    /// notebook was alive more recently than the deletion, so it comes back and the drawing with
    /// it. Scenario 12 pins the same rule using a rename, whose own timestamp write would survive
    /// the tempting removal of that bump — this one would not, which is the point of having both.
    func testAnInkOnlyEditLaterThanADeletionResurrectsTheNotebook() async throws {
        let notebook = CouchDocID.notebook("nbW")
        ipadStore.set(notebook, .notebook(CouchNotebook(
            title: "W", pageIds: ["p1"], createdAt: stamp(0), updatedAt: stamp(0),
            updatedBy: "ipad")))
        ipadStore.set(pageID, .page(page(strokes: [stroke("w1", at: 1, device: "ipad")],
                                         updatedAt: 5, by: "ipad")))
        await ipad.markDirty([notebook, pageID])
        _ = await ipad.flush()
        _ = try await boox.pull()

        // The iPad deletes the whole notebook while the BOOX is offline.
        ipadStore.set(notebook, .deleted(CouchDeletedDoc(
            type: CouchDocType.notebook, deletedAt: stamp(100), updatedBy: "ipad")))
        await ipad.markDirty([notebook])

        // The BOOX draws — no rename, no metadata edit — later than the deletion. Saving ink
        // bumps the notebook too, exactly as `NotebookStore.savePage` does in the app.
        var drawn = booxStore.page(pageID)!
        drawn.strokes.append(stroke("w2", at: 200, device: "boox"))
        drawn.updatedAt = stamp(200)
        drawn.updatedBy = "boox"
        booxStore.set(pageID, .page(drawn))
        var owning = booxStore.notebook(notebook)!
        owning.updatedAt = stamp(200)
        owning.updatedBy = "boox"
        booxStore.set(notebook, .notebook(owning))
        await boox.markDirty([notebook, pageID])
        _ = await boox.flush()

        _ = await ipad.flush()
        _ = try await ipad.pull()

        guard case .notebook(let survived)? = ipadStore.body(notebook) else {
            return XCTFail("the notebook stayed deleted, taking the later drawing with it")
        }
        XCTAssertEqual(survived.title, "W")
        XCTAssertEqual(ipadStore.page(pageID)?.strokes.map(\.id).sorted(), ["w1", "w2"])
    }

    /// Twelve deleted notebooks in the local store: over the guard's threshold, and the whole
    /// library as far as this device is concerned.
    private func deleteTwelveNotebooks(prefix: String = "nb") -> [String] {
        (0..<12).map { index in
            let id = CouchDocID.notebook("\(prefix)\(index)")
            ipadStore.set(id, .deleted(CouchDeletedDoc(
                type: CouchDocType.notebook, deletedAt: stamp(10), updatedBy: "ipad")))
            return id
        }
    }

    /// A catch-up from `0` — a fresh install, or any device whose checkpoint was lost — used to
    /// ask for the whole library in one response and hold it all in memory before applying any of
    /// it. It arrives in batches now, each one checkpointed as it lands.
    func testACatchUpLongerThanOneBatchPagesThroughTheWholeFeed() async throws {
        let total = CouchSyncEngine.catchUpBatchSize + 25
        for index in 0..<total {
            let id = CouchDocID.page("p\(index)")
            booxStore.set(id, .page(page(strokes: [stroke("s\(index)", at: index, device: "boox")],
                                         updatedAt: 5, by: "boox")))
            await boox.markDirty([id])
        }
        _ = await boox.flush()

        let report = try await ipad.pull()

        XCTAssertEqual(report.applied.count, total, "every page should have arrived")
        XCTAssertGreaterThan(server.changeRequestCount(), 1, "and over more than one request")
        // The point is the size of each response, not the number of them: an unpaged read is one
        // big response followed by an empty one, which is also two requests.
        XCTAssertLessThanOrEqual(
            server.largestChangeBatch(), CouchSyncEngine.catchUpBatchSize,
            "no single response should have carried the whole library")
        // A second pull has nothing left to do: the checkpoint moved past everything applied.
        let again = try await ipad.pull()
        XCTAssertTrue(again.applied.isEmpty)
    }

    /// Stopping at the first dead connection is right; describing the run as though only that one
    /// document were left is not. The rest of the queue was never attempted and is still in the
    /// outbox, so a report that omits it drives the pending badge — and the peer's "is there more
    /// to send" question — from a number that is simply too small.
    func testAnEarlyStopReportsTheWholeRemainingQueueAsStillDirty() async throws {
        let ids = ["p1", "p2", "p3"].map(CouchDocID.page)
        for id in ids { ipadStore.set(id, .page(page(updatedAt: 5, by: "ipad"))) }
        await ipad.markDirty(ids)
        // The first document the flush reaches fails with something that applies to the rest too.
        server.failingDocumentIDs[ids[0]] = 503

        let report = await ipad.flush()

        XCTAssertEqual(report.stillDirty.sorted(), ids.sorted())
        XCTAssertEqual(report.failures.count, 1, "only the attempted document actually failed")
        let pending = await ipad.pendingCount
        XCTAssertEqual(report.stillDirty.count, pending, "the report must match the outbox")
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
