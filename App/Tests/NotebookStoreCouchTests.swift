import NotableKit
import XCTest

@testable import Bopa

/// What the store has to do for CouchDB sync: record erasures, stamp the writing device, and
/// name the documents each mutation touched so sync queues exactly those.
@MainActor
final class NotebookStoreCouchTests: XCTestCase {
    private var rootURL: URL!
    private var store: NotebookStore!
    private var changed: [[String]] = []
    private var deleted: [[String]] = []

    override func setUp() async throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("bopa-couch-store-\(UUID().uuidString)")
        store = NotebookStore(rootURL: rootURL)
        store.deviceID = "ipad"
        changed = []
        deleted = []
        store.didChangeDocuments = { [weak self] ids in self?.changed.append(ids) }
        store.didDeleteDocuments = { [weak self] ids in self?.deleted.append(ids) }
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: rootURL)
    }

    private func stroke(_ id: String) -> StrokeDTO {
        StrokeDTO(
            id: id, size: 3, pen: .ballpen, color: -16_777_216, maxPressure: 1,
            top: 0, bottom: 1, left: 0, right: 1, pointsData: "AAA=",
            createdAt: NotableDate.format(Date()), updatedAt: NotableDate.format(Date()))
    }

    // MARK: Erasure

    /// The whole reason tombstones exist: without this, the BOOX's copy of an erased stroke comes
    /// back on the next merge, because absence cannot be told from "not synced yet".
    func testErasingAStrokeRecordsATombstone() throws {
        let manifest = try store.createNotebook(title: "notes")
        let pageId = manifest.pageIds[0]
        var page = try store.loadPage(notebookId: manifest.notebookId, pageId: pageId)

        page.strokes = [stroke("s1"), stroke("s2")]
        try store.savePage(page)

        var afterWriting = try store.loadPage(notebookId: manifest.notebookId, pageId: pageId)
        XCTAssertTrue(afterWriting.deletedStrokes.isEmpty, "drawing should not tombstone anything")

        afterWriting.strokes.removeAll { $0.id == "s2" }
        try store.savePage(afterWriting)

        let afterErasing = try store.loadPage(notebookId: manifest.notebookId, pageId: pageId)
        XCTAssertEqual(afterErasing.strokes.map(\.id), ["s1"])
        XCTAssertEqual(afterErasing.deletedStrokes.map(\.id), ["s2"])
    }

    /// Re-stamping an existing tombstone on every save would let an arbitrarily later time win a
    /// delete-vs-edit comparison it should lose.
    func testATombstoneKeepsItsOriginalTimeAcrossLaterSaves() throws {
        let manifest = try store.createNotebook(title: "notes")
        let pageId = manifest.pageIds[0]
        var page = try store.loadPage(notebookId: manifest.notebookId, pageId: pageId)
        page.strokes = [stroke("s1")]
        try store.savePage(page)

        page.strokes = []
        try store.savePage(page)
        let firstTime = try store.loadPage(notebookId: manifest.notebookId, pageId: pageId)
            .deletedStrokes.first?.deletedAt
        XCTAssertNotNil(firstTime)

        // Draw something else later; the old tombstone must not move.
        var later = try store.loadPage(notebookId: manifest.notebookId, pageId: pageId)
        later.strokes = [stroke("s9")]
        try store.savePage(later)

        let reread = try store.loadPage(notebookId: manifest.notebookId, pageId: pageId)
        XCTAssertEqual(reread.deletedStrokes.first?.deletedAt, firstTime)
    }

    func testSavingStampsTheWritingDevice() throws {
        let manifest = try store.createNotebook(title: "notes")
        let page = try store.loadPage(
            notebookId: manifest.notebookId, pageId: manifest.pageIds[0])
        try store.savePage(page)

        let saved = try store.loadPage(
            notebookId: manifest.notebookId, pageId: manifest.pageIds[0])
        XCTAssertEqual(saved.updatedBy, "ipad")
        // The page alone: stamping the manifest too would rewrite the envelope the merge
        // decides renames and moves by, which is how ink used to undo a peer's rename.
        XCTAssertEqual(store.manifest(id: manifest.notebookId)?.updatedBy, manifest.updatedBy)
    }

    // MARK: Sync writing underneath an open page

    /// Applies a document the way the CouchDB pull loop does — straight to disk, with no regard
    /// for what the editor currently has open. That is the whole difference from the WebDAV
    /// engine, which is handed `uploadOnly: [openNotebookId]` and never writes there.
    private func applyFromTheBoox(_ page: PageFile) throws {
        var incoming = page
        incoming.updatedAt = NotableDate.format(Date())
        let notebookDir = rootURL.appendingPathComponent(
            "notebooks/\(page.notebookId ?? "")", isDirectory: true)
        try FileCouchStore(rootURL: rootURL, deviceID: "boox")
            .apply(CouchDocID.page(page.id), .page(CouchMapping.couchPage(
                from: incoming, deviceID: "boox", notebookDir: notebookDir)))
    }

    /// The bug: the editor loads a page, the BOOX's ink lands in the file while it is open, and
    /// the next autosave writes back the stroke set the editor still remembers. Without a baseline
    /// that says what the editor actually saw, the arriving stroke is both overwritten here *and*
    /// tombstoned — so the merge then deletes it on every device, permanently.
    func testInkThatArrivedWhileThePageWasOpenSurvivesTheNextSave() throws {
        let manifest = try store.createNotebook(title: "notes")
        let pageId = manifest.pageIds[0]

        // The editor opens the page and draws.
        var opened = try store.loadPage(notebookId: manifest.notebookId, pageId: pageId)
        opened.strokes = [stroke("mine")]
        let onCanvas = try store.savePage(opened, baselineStrokeIDs: [])

        // The BOOX's stroke arrives while that page is still open.
        var fromBoox = onCanvas
        fromBoox.strokes.append(stroke("from-boox"))
        try applyFromTheBoox(fromBoox)

        // The editor autosaves what it has, which is still only its own stroke.
        var stale = onCanvas
        stale.scroll = 40
        let written = try store.savePage(stale, baselineStrokeIDs: ["mine"])

        XCTAssertEqual(
            Set(written.strokes.map(\.id)), ["mine", "from-boox"],
            "a stale save overwrote ink that arrived from the other device")
        XCTAssertTrue(
            written.deletedStrokes.isEmpty,
            "the editor never saw that stroke, so it cannot have erased it: "
                + "\(written.deletedStrokes.map(\.id))")

        let reread = try store.loadPage(notebookId: manifest.notebookId, pageId: pageId)
        XCTAssertEqual(Set(reread.strokes.map(\.id)), ["mine", "from-boox"])
        XCTAssertEqual(reread.scroll, 40, "the caller's own fields still win")
    }

    /// The same race one step on: a page that was reconciled once must stay reconciled. Passing
    /// the file's own ids back as the baseline would tombstone the arrival on the *second* save.
    func testARepeatedStaleSaveStillDoesNotTombstoneTheArrival() throws {
        let manifest = try store.createNotebook(title: "notes")
        let pageId = manifest.pageIds[0]
        var opened = try store.loadPage(notebookId: manifest.notebookId, pageId: pageId)
        opened.strokes = [stroke("mine")]
        let onCanvas = try store.savePage(opened, baselineStrokeIDs: [])

        var fromBoox = onCanvas
        fromBoox.strokes.append(stroke("from-boox"))
        try applyFromTheBoox(fromBoox)

        // Two more autosaves from an editor that still only knows about its own stroke.
        var stale = onCanvas
        stale.scroll = 10
        _ = try store.savePage(stale, baselineStrokeIDs: ["mine"])
        stale.scroll = 20
        let written = try store.savePage(stale, baselineStrokeIDs: ["mine"])

        XCTAssertEqual(Set(written.strokes.map(\.id)), ["mine", "from-boox"])
        XCTAssertTrue(written.deletedStrokes.isEmpty, "the arrival was erased on a later save")
    }

    /// The other direction: a stroke the BOOX erased must not be resurrected by an editor that
    /// still has it on screen. Erasure beats drawing, the same rule the merge uses.
    func testAStrokeErasedOnTheOtherDeviceIsNotWrittenBackByAStaleSave() throws {
        let manifest = try store.createNotebook(title: "notes")
        let pageId = manifest.pageIds[0]
        var opened = try store.loadPage(notebookId: manifest.notebookId, pageId: pageId)
        opened.strokes = [stroke("keep"), stroke("gone")]
        let onCanvas = try store.savePage(opened, baselineStrokeIDs: [])

        var fromBoox = onCanvas
        fromBoox.strokes.removeAll { $0.id == "gone" }
        fromBoox.deletedStrokes = [
            CouchTombstone(id: "gone", deletedAt: NotableDate.format(Date()))
        ]
        try applyFromTheBoox(fromBoox)

        let written = try store.savePage(onCanvas, baselineStrokeIDs: ["keep", "gone"])

        XCTAssertEqual(written.strokes.map(\.id), ["keep"], "the erased stroke came back")
        XCTAssertEqual(written.deletedStrokes.map(\.id), ["gone"], "the tombstone was dropped")
    }

    /// Erasing still has to work — the baseline is what the caller had, so what left it is gone.
    func testErasingAgainstAnExplicitBaselineStillTombstones() throws {
        let manifest = try store.createNotebook(title: "notes")
        let pageId = manifest.pageIds[0]
        var opened = try store.loadPage(notebookId: manifest.notebookId, pageId: pageId)
        opened.strokes = [stroke("s1"), stroke("s2")]
        var onCanvas = try store.savePage(opened, baselineStrokeIDs: [])

        onCanvas.strokes.removeAll { $0.id == "s2" }
        let written = try store.savePage(onCanvas, baselineStrokeIDs: ["s1", "s2"])

        XCTAssertEqual(written.strokes.map(\.id), ["s1"])
        XCTAssertEqual(written.deletedStrokes.map(\.id), ["s2"])
    }

    /// Images ride along the same path and the editor never removes them, so an add-wins union
    /// is the whole rule — an image from the BOOX must not vanish on the next autosave either.
    func testAnImageThatArrivedWhileThePageWasOpenSurvivesTheNextSave() throws {
        let manifest = try store.createNotebook(title: "notes")
        let pageId = manifest.pageIds[0]
        let onCanvas = try store.savePage(
            try store.loadPage(notebookId: manifest.notebookId, pageId: pageId),
            baselineStrokeIDs: [])

        // Its bytes land first, as sync delivers them — under the hash that names them, which is
        // the uri a page arriving over CouchDB carries.
        let bytes = Data("a picture".utf8)
        let uri = try XCTUnwrap(NotableImageFiles.localURI(forAssetID: CouchAssetID.forBytes(bytes)))
        let images = rootURL.appendingPathComponent(
            "notebooks/\(manifest.notebookId)/images", isDirectory: true)
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        try bytes.write(to: images.appendingPathComponent((uri as NSString).lastPathComponent))

        var fromBoox = onCanvas
        fromBoox.images = [
            ImageDTO(
                id: "img", x: 0, y: 0, width: 10, height: 10, uri: uri,
                createdAt: NotableDate.format(Date()), updatedAt: NotableDate.format(Date()))
        ]
        try applyFromTheBoox(fromBoox)

        let written = try store.savePage(onCanvas, baselineStrokeIDs: [])
        XCTAssertEqual(written.images.map(\.id), ["img"])
        // And it still points at the picture, not at a name nothing will ever write.
        XCTAssertEqual(written.images.map(\.uri), [uri])
    }

    // MARK: Change reporting

    func testCreatingANotebookNamesBothItAndItsPage() throws {
        let manifest = try store.createNotebook(title: "notes")
        XCTAssertEqual(changed.last, [
            CouchDocID.notebook(manifest.notebookId), CouchDocID.page(manifest.pageIds[0]),
        ])
    }

    /// The page alone — the notebook document did not change, and offering it anyway meant
    /// pushing an envelope whose clock the save had just bumped, which is how ink used to undo
    /// a rename arriving from the other device.
    func testSavingAPageNamesThePageAlone() throws {
        let manifest = try store.createNotebook(title: "notes")
        let page = try store.loadPage(
            notebookId: manifest.notebookId, pageId: manifest.pageIds[0])
        changed = []
        try store.savePage(page)

        XCTAssertEqual(changed.last, [CouchDocID.page(page.id)])
    }

    func testRenamingNamesOnlyTheNotebook() throws {
        let manifest = try store.createNotebook(title: "notes")
        changed = []
        try store.renameNotebook(id: manifest.notebookId, title: "renamed")
        XCTAssertEqual(changed.last, [CouchDocID.notebook(manifest.notebookId)])
    }

    /// The pages go with the notebook, so sync has to hear about them: one left queued would be
    /// pushed back under a notebook that no longer exists.
    func testDeletingANotebookNamesItsPagesToo() throws {
        let manifest = try store.createNotebook(title: "notes")
        let extraPage = try store.addPage(to: manifest.notebookId)
        changed = []

        try store.purgeNotebook(id: manifest.notebookId)

        let reported = Set(changed.last ?? [])
        XCTAssertTrue(reported.contains(CouchDocID.notebook(manifest.notebookId)))
        XCTAssertTrue(reported.contains(CouchDocID.page(manifest.pageIds[0])))
        XCTAssertTrue(reported.contains(CouchDocID.page(extraPage.id)))
    }

    func testFolderChangesAreReported() throws {
        let folder = try store.createFolder(title: "school")
        XCTAssertEqual(changed.last, [CouchDocID.folder(folder.id)])
    }

    /// `folders.json` says which folders *survive*, so the one id that most needed syncing — the
    /// deleted one — was the only id never reported. The folder stayed live on the server and came
    /// back on the next pull, looking for all the world like the peer had just created it.
    func testDeletingAFolderReportsItAndRecordsATombstone() throws {
        let folder = try store.createFolder(title: "school")
        changed = []
        deleted = []

        try store.purgeFolder(id: folder.id)

        XCTAssertEqual(deleted, [[CouchDocID.folder(folder.id)]])
        XCTAssertTrue(
            (changed.last ?? []).contains(CouchDocID.folder(folder.id)),
            "the queue has to hear about the folder that went, not only the ones that stayed")
    }

    /// Wired exactly as `SyncBackendHost` wires it. The tombstone is the whole point: without one
    /// the engine loads nothing for the id, reads that as "never created", and drops it.
    func testTheDeletionSignalGivesTheCouchStoreATombstoneToPush() throws {
        let couch = FileCouchStore(rootURL: rootURL, deviceID: "ipad")
        store.didDeleteDocuments = { ids in for id in ids { couch.recordDeletion(id) } }
        let folder = try store.createFolder(title: "school")

        try store.purgeFolder(id: folder.id)

        XCTAssertEqual(couch.pendingDeletionIDs(), [CouchDocID.folder(folder.id)])
        XCTAssertTrue(try couch.load(CouchDocID.folder(folder.id))?.isDeleted ?? false)
    }

    func testDeletingANotebookRecordsATombstone() throws {
        let manifest = try store.createNotebook(title: "notes")
        deleted = []

        try store.purgeNotebook(id: manifest.notebookId)

        XCTAssertEqual(deleted, [[CouchDocID.notebook(manifest.notebookId)]])
    }

    /// The tombstone has to land between the two: after the local deletion, because a tombstone is
    /// authoritative the moment it is written and one recorded for a deletion that threw would
    /// publish a deletion this device never made; before the change signal, because the push that
    /// signal starts would otherwise find nothing on disk and drop the id from the outbox.
    func testTheTombstoneIsRecordedBeforeTheChangeIsAnnounced() throws {
        let folder = try store.createFolder(title: "school")
        var order: [String] = []
        store.didDeleteDocuments = { _ in order.append("deleted") }
        store.didChangeDocuments = { _ in order.append("changed") }

        try store.purgeFolder(id: folder.id)

        XCTAssertEqual(order, ["deleted", "changed"])
    }

    /// The tombstone used to be written by the caller *before* the local delete, with the failure
    /// then swallowed by `try?`. The notebook stayed on this iPad while `FileCouchStore` handed the
    /// tombstone back in its place — so the next sync deleted the peer's copy of a notebook nobody
    /// had managed to delete anywhere.
    func testAFailedNotebookDeletionRecordsNoTombstone() throws {
        deleted = []

        XCTAssertThrowsError(try store.purgeNotebook(id: "no-such-notebook"))

        XCTAssertTrue(deleted.isEmpty, "nothing was deleted, so nothing may be published")
    }

    /// A folder is no longer refused for being populated — it goes to the Trash and can come back
    /// — but the invariant that refusal protected still holds: a folder that is still in this
    /// library must not be tombstoned. `FileCouchStore` hands a recorded tombstone back in place
    /// of the live document, so writing one would delete the peer's copy of a folder that is
    /// sitting right here.
    ///
    /// A purge fails part-way when one of its notebooks cannot be removed, which is what this
    /// arranges: the folder's own rows are only rewritten after every notebook in it is gone.
    func testAFolderPurgeThatCannotFinishRecordsNoFolderTombstone() throws {
        let folder = try store.createFolder(title: "school")
        _ = try store.createNotebook(title: "notes", parentFolderId: folder.id)
        let notebooksDir = rootURL.appendingPathComponent("notebooks")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500], ofItemAtPath: notebooksDir.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: notebooksDir.path)
        }
        deleted = []

        XCTAssertThrowsError(try store.purgeFolder(id: folder.id))

        XCTAssertFalse(
            deleted.flatMap { $0 }.contains(CouchDocID.folder(folder.id)),
            "a folder that is still here must not be tombstoned")
        XCTAssertEqual(store.folders.map(\.id), [folder.id])
    }

    /// `refresh()` is what sync itself calls after applying a change; reporting from there would
    /// be a feedback loop that re-queues everything sync just downloaded.
    func testRefreshReportsNothing() throws {
        _ = try store.createNotebook(title: "notes")
        changed = []
        store.refresh()
        XCTAssertTrue(changed.isEmpty)
    }

    // MARK: Provenance under CouchDB

    /// The bug: CouchDB writes no `RemoteIndex`, so every cover kept the "local only" arrow no
    /// matter how many times the notebook had been pushed. The rev map is this backend's record
    /// of what the server holds, and it has to outrank an index left over from WebDAV use.
    func testProvenanceUnderCouchComesFromTheRevMap() throws {
        let synced = try store.createNotebook(title: "synced")
        let fresh = try store.createNotebook(title: "fresh")
        let syncedFolder = try store.createFolder(title: "school")
        let freshFolder = try store.createFolder(title: "new")

        // An index from back when this library synced over WebDAV, naming none of them.
        try RemoteIndex(
            notebookIds: [], folderIds: [], syncedAt: NotableDate.format(Date()))
            .save(root: rootURL)
        store.refresh()

        store.noteRemoteDocuments([
            CouchDocID.notebook(synced.notebookId), CouchDocID.folder(syncedFolder.id),
        ])

        XCTAssertTrue(store.hasSyncedAtLeastOnce)
        XCTAssertEqual(store.provenance(ofNotebook: synced.notebookId), .onServer)
        XCTAssertEqual(store.provenance(ofNotebook: fresh.notebookId), .localOnly)
        XCTAssertEqual(store.provenance(ofFolder: syncedFolder.id), .onServer)
        XCTAssertEqual(store.provenance(ofFolder: freshFolder.id), .localOnly)

        // `refresh()` reloads the WebDAV index; it must not take the answer back.
        store.refresh()
        XCTAssertEqual(store.provenance(ofNotebook: synced.notebookId), .onServer)
    }

    /// Switching off CouchDB hands the badges back to the WebDAV index rather than leaving them
    /// on a rev map that no longer describes where anything is.
    func testClearingTheRevMapReturnsTheAnswerToTheWebDAVIndex() throws {
        let notebook = try store.createNotebook(title: "notes")
        try RemoteIndex(
            notebookIds: [notebook.notebookId], folderIds: [],
            syncedAt: NotableDate.format(Date()))
            .save(root: rootURL)
        store.refresh()

        store.noteRemoteDocuments([])
        XCTAssertEqual(store.provenance(ofNotebook: notebook.notebookId), .localOnly)

        store.noteRemoteDocuments(nil)
        XCTAssertEqual(store.provenance(ofNotebook: notebook.notebookId), .onServer)
    }

    /// The stack reports the state it loaded, not only the ones it goes on to write — otherwise
    /// every launch would show the whole library as local-only until the first sync landed.
    func testTheStackReportsItsLoadedStateBeforeAnySync() throws {
        let notebook = try store.createNotebook(title: "notes")
        let settings = CouchSettings(
            serverURL: "http://127.0.0.1:5984", database: "notes", username: "sync",
            password: "pw", deviceID: "ipad")
        CouchSyncStack.save(
            CouchSyncState(
                lastSeq: "42",
                revs: [CouchDocID.notebook(notebook.notebookId): "1-abc"]),
            to: rootURL.appendingPathComponent(CouchSyncStack.stateFileName(for: settings)))

        let sink = StateSink()
        let stack = CouchSyncStack.make(
            settings: settings, rootURL: rootURL, onChange: {},
            onState: { state in sink.reported.append(state) })

        XCTAssertNotNil(stack)
        XCTAssertEqual(sink.reported.count, 1)
        XCTAssertEqual(sink.reported.first?.lastSeq, "42")
        XCTAssertEqual(
            sink.reported.first?.revs[CouchDocID.notebook(notebook.notebookId)], "1-abc")
    }

    /// An *edit's* dirty mark travels the same async hop a deletion's did, and matched neither
    /// construction-time seed: the document is on disk (so it is not a deletion) and the server
    /// holds a revision for it (so the unsent scan skips it). The host now records the intent
    /// durably before the hop — synchronously, inside the mutation's own change signal — and
    /// clears it only after the engine has persisted the mark.
    func testAnEditsDirtyMarkIsDurableAcrossTheHopToTheEngine() async throws {
        let settings = CouchSettings(
            serverURL: "http://127.0.0.1:5984", database: "notes", username: "sync",
            password: "pw", deviceID: "ipad")
        let host = SyncBackendHost(loadSettings: { settings }, loadBackend: { .couchdb })
        host.attach(store: store, coordinator: SyncCoordinator())
        // A fresh reader over the same directory — the file is the record, not the instance.
        let reader = FileCouchStore(rootURL: rootURL, deviceID: "ipad")

        _ = try store.createNotebook(title: "durable")
        // No suspension has happened since the mutation, so the Task carrying markDirty cannot
        // have run yet — this is exactly the window an app kill used to strand.
        XCTAssertFalse(
            reader.pendingMarkIDs().isEmpty,
            "the mark must be durable before the hop to the engine, not after it")

        // Once the engine holds the ids in its persisted outbox, the record has done its job.
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(reader.pendingMarkIDs().isEmpty, "a confirmed mark must not linger")
    }

    /// The healing half: a mark still recorded at launch — the app died mid-hop — re-enters the
    /// outbox at construction, exactly as a recorded deletion does.
    func testTheStackSeedsTheOutboxWithUnconfirmedDirtyMarks() async throws {
        let notebook = try store.createNotebook(title: "edited then killed")
        let pageId = try XCTUnwrap(notebook.pageIds.first)
        let settings = CouchSettings(
            serverURL: "http://127.0.0.1:5984", database: "notes", username: "sync",
            password: "pw", deviceID: "ipad")
        // The server already holds the page — a recorded revision — so the unsent scan cannot
        // see the edit; only the pending mark says one is waiting.
        CouchSyncStack.save(
            CouchSyncState(
                lastSeq: "42",
                revs: [
                    CouchDocID.notebook(notebook.notebookId): "2-abc",
                    CouchDocID.page(pageId): "2-def",
                ]),
            to: rootURL.appendingPathComponent(CouchSyncStack.stateFileName(for: settings)))
        FileCouchStore(rootURL: rootURL, deviceID: "ipad")
            .recordPendingMarks([CouchDocID.page(pageId)])

        let stack = try XCTUnwrap(CouchSyncStack.make(
            settings: settings, rootURL: rootURL, onChange: {}))

        let state = await stack.engine.currentState
        XCTAssertTrue(
            state.dirty.contains(CouchDocID.page(pageId)),
            "the stranded edit must re-enter the outbox at construction")
        XCTAssertFalse(
            state.dirty.contains(CouchDocID.notebook(notebook.notebookId)),
            "and nothing else rides along with it")
    }

    /// A deletion is recorded durably the moment it happens, but its dirty mark used to travel
    /// only through an async Task — an app killed between the two held a tombstone nothing would
    /// ever push, because nothing re-read the deletions file at startup. Building the stack now
    /// seeds the outbox from it, so every launch heals that window.
    func testTheStackSeedsTheOutboxWithRecordedDeletions() async throws {
        FileCouchStore(rootURL: rootURL, deviceID: "ipad")
            .recordDeletion(CouchDocID.notebook("stranded"))
        let settings = CouchSettings(
            serverURL: "http://127.0.0.1:5984", database: "notes", username: "sync",
            password: "pw", deviceID: "ipad")

        let sink = StateSink()
        let stack = try XCTUnwrap(CouchSyncStack.make(
            settings: settings, rootURL: rootURL, onChange: {},
            onState: { state in sink.reported.append(state) }))

        XCTAssertTrue(
            sink.reported.first?.dirty.contains(CouchDocID.notebook("stranded")) ?? false,
            "the recorded deletion never re-entered the outbox")
        let engineState = await stack.engine.currentState
        XCTAssertTrue(engineState.dirty.contains(CouchDocID.notebook("stranded")))
    }

    /// While the backend is off (or WebDAV is selected) `didChangeDocuments` is nil, so a
    /// notebook created then was invisible to sync: nothing marked it dirty, and when CouchDB
    /// came up the engine loaded a state that knew nothing about it. Short of the manual
    /// "Upload everything" button it stayed on this iPad forever. Building the stack now scans
    /// for documents the server has never seen and seeds them into the outbox.
    func testTheStackSeedsTheOutboxWithDocumentsTheServerHasNeverSeen() async throws {
        // Created while no engine existed to hear about it.
        let notebook = try store.createNotebook(title: "written while sync was off")
        let pageId = try XCTUnwrap(notebook.pageIds.first)
        let settings = CouchSettings(
            serverURL: "http://127.0.0.1:5984", database: "notes", username: "sync",
            password: "pw", deviceID: "ipad")

        let stack = try XCTUnwrap(CouchSyncStack.make(
            settings: settings, rootURL: rootURL, onChange: {}))

        let state = await stack.engine.currentState
        XCTAssertTrue(
            state.dirty.contains(CouchDocID.notebook(notebook.notebookId)),
            "the notebook must be queued for the first flush")
        XCTAssertTrue(
            state.dirty.contains(CouchDocID.page(pageId)),
            "and its page with it")
    }

    /// The other half of the scan's contract: a document whose revision is recorded has been
    /// through the server already, and re-queueing it on every launch would 409-merge the whole
    /// library for nothing.
    func testTheUnsentScanLeavesDocumentsTheServerAlreadyHoldsAlone() async throws {
        let known = try store.createNotebook(title: "already synced")
        let knownPage = try XCTUnwrap(known.pageIds.first)
        let fresh = try store.createNotebook(title: "never sent")
        let settings = CouchSettings(
            serverURL: "http://127.0.0.1:5984", database: "notes", username: "sync",
            password: "pw", deviceID: "ipad")
        CouchSyncStack.save(
            CouchSyncState(
                lastSeq: "42",
                revs: [
                    CouchDocID.notebook(known.notebookId): "1-abc",
                    CouchDocID.page(knownPage): "1-def",
                ]),
            to: rootURL.appendingPathComponent(CouchSyncStack.stateFileName(for: settings)))

        let stack = try XCTUnwrap(CouchSyncStack.make(
            settings: settings, rootURL: rootURL, onChange: {}))

        let state = await stack.engine.currentState
        XCTAssertFalse(state.dirty.contains(CouchDocID.notebook(known.notebookId)),
                       "a document the server holds must not be re-pushed by the scan")
        XCTAssertFalse(state.dirty.contains(CouchDocID.page(knownPage)))
        XCTAssertTrue(state.dirty.contains(CouchDocID.notebook(fresh.notebookId)),
                      "while one it has never seen is")
    }

    /// A checkpoint describes one server's change feed and one server's revisions. Kept in a single
    /// file, it was handed to whichever endpoint the user pointed at next: a foreign `since` skips
    /// changes instead of failing loudly, and foreign revisions suppress real updates as echoes.
    func testEachServerAndDatabaseGetsItsOwnState() throws {
        let first = CouchSettings(
            serverURL: "http://127.0.0.1:5984", database: "notes", username: "sync",
            password: "pw", deviceID: "ipad")
        let otherDatabase = CouchSettings(
            serverURL: "http://127.0.0.1:5984", database: "archive", username: "sync",
            password: "pw", deviceID: "ipad")
        let otherServer = CouchSettings(
            serverURL: "http://couch.example:5984", database: "notes", username: "sync",
            password: "pw", deviceID: "ipad")

        let names = [first, otherDatabase, otherServer].map(CouchSyncStack.stateFileName(for:))
        XCTAssertEqual(Set(names).count, 3, "each endpoint needs its own file")

        // And the file is genuinely not read across the switch: the first server's checkpoint must
        // not become the second's starting point.
        CouchSyncStack.save(
            CouchSyncState(lastSeq: "42", revs: [CouchDocID.notebook("nb1"): "1-abc"]),
            to: rootURL.appendingPathComponent(CouchSyncStack.stateFileName(for: first)))

        let sink = StateSink()
        XCTAssertNotNil(CouchSyncStack.make(
            settings: otherDatabase, rootURL: rootURL, onChange: {},
            onState: { state in sink.reported.append(state) }))
        XCTAssertEqual(sink.reported.first?.lastSeq, "0", "a new database replays from the start")
        XCTAssertTrue(sink.reported.first?.revs.isEmpty ?? false)
    }

    /// The other half of the rule: only the *endpoint* names the file. Changing a password does not
    /// change what is on the server, and neither does spelling the same address differently — so
    /// none of it may throw away a checkpoint and replay the whole feed for nothing.
    func testCredentialsDeviceIdAndUrlSpellingDoNotChangeTheStateFile() throws {
        let settings = CouchSettings(
            serverURL: "http://127.0.0.1:5984", database: "notes", username: "sync",
            password: "pw", deviceID: "ipad")
        var changed = settings
        changed.password = "a new password"
        changed.username = "someone else"
        changed.deviceID = "ipad-mini"
        changed.serverURL = "HTTP://127.0.0.1:5984/"

        XCTAssertEqual(
            CouchSyncStack.stateFileName(for: settings),
            CouchSyncStack.stateFileName(for: changed))
    }

    // MARK: Clock skew (§7.1a)

    /// §6.4's liveness signal reads the page clocks, and the page clocks are stamped by the store.
    /// So a skewed device must not be able to inflate its own liveness: an hour-fast iPad that
    /// stamped ink an hour into the future would beat a deletion the peer made *after* the ink,
    /// which is the whole failure §7.1a exists to stop. This pins the chain
    /// `savePage` → `page.updatedAt` → `FileCouchStore.contentClock`.
    func testTheLivenessSignalIsStampedFromTheCorrectedClock() throws {
        let defaults = UserDefaults(suiteName: "NotebookStoreCouchTests.liveness")!
        defaults.removePersistentDomain(forName: "NotebookStoreCouchTests.liveness")
        let fixed = Date(timeIntervalSince1970: 1_770_000_000)
        let clock = SyncClock(defaults: defaults, base: { fixed })
        clock.note(ClockSkew(seconds: 3_600))

        let skewed = NotebookStore(rootURL: rootURL, clock: clock)
        skewed.deviceID = "ipad"
        let manifest = try skewed.createNotebook(title: "notes")
        let pageId = manifest.pageIds[0]
        var page = try skewed.loadPage(notebookId: manifest.notebookId, pageId: pageId)
        page.strokes = [stroke("s1")]
        _ = try skewed.savePage(page)

        let corrected = NotableDate.format(fixed.addingTimeInterval(-3_600))
        let store = FileCouchStore(rootURL: rootURL, deviceID: "ipad", clock: clock)
        XCTAssertEqual(
            store.contentClock(CouchDocID.notebook(manifest.notebookId)), corrected,
            "the liveness clock must be the corrected instant, not this device's own")

        // The tombstone side of the same comparison, so the two cannot drift apart: correcting one
        // without the other is worse than correcting neither. `SyncClockTests` covers the stamp
        // itself; this asserts the ledger the deletion actually lands in.
        store.recordDeletion(CouchDocID.notebook(manifest.notebookId))
        let ledger = rootURL.appendingPathComponent(".bopa-couch-deletions.json")
        let recorded = try JSONDecoder().decode(
            [String: String].self, from: Data(contentsOf: ledger))
        XCTAssertEqual(recorded[CouchDocID.notebook(manifest.notebookId)], corrected)
    }
}

/// Collects what the stack reports. A class because the callback is `@Sendable`, and the test
/// only ever reads it after the synchronous call that filled it.
private final class StateSink: @unchecked Sendable {
    var reported: [CouchSyncState] = []
}
