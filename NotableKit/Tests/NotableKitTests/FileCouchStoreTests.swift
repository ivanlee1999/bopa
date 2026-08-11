import XCTest
@testable import NotableKit

/// The adapter over the real notebook directory, plus a round trip through the engine and a
/// real-shaped server so the storage layer is exercised the way sync will use it.
final class FileCouchStoreTests: XCTestCase {

    private var root: URL!
    private var store: FileCouchStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bopa-couch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = FileCouchStore(rootURL: root, deviceID: "ipad")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func stamp(_ second: Int) -> String {
        NotableDate.format(Date(timeIntervalSince1970: 1_770_000_000 + Double(second)))
    }

    private func stroke(_ id: String, at second: Int) -> CouchStroke {
        CouchStroke(
            id: id, createdAt: stamp(second), updatedAt: stamp(second), deviceId: "ipad",
            pen: "BALLPEN", color: -16_777_216, size: 3,
            top: 0, bottom: 1, left: 0, right: 1, pointsData: "AAA=")
    }

    private func page(_ strokes: [CouchStroke], notebookId: String, updatedAt: Int) -> CouchPage {
        CouchPage(
            notebookId: notebookId, strokes: strokes,
            createdAt: stamp(0), updatedAt: stamp(updatedAt), updatedBy: "ipad")
    }

    // MARK: Round trips

    func testNotebookRoundTripsThroughTheDirectory() throws {
        let id = CouchDocID.notebook("nb1")
        let notebook = CouchNotebook(
            title: "notes", pageIds: ["p1"], createdAt: stamp(0), updatedAt: stamp(5),
            updatedBy: "ipad")

        try store.apply(id, .notebook(notebook))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("notebooks/nb1/manifest.json").path))

        guard case .notebook(let loaded)? = try store.load(id) else {
            return XCTFail("notebook did not load back")
        }
        XCTAssertEqual(loaded, notebook)
    }

    func testPageRoundTripsAndIsFoundByPageIdAlone() throws {
        let pageID = CouchDocID.page("p1")
        let written = page([stroke("s1", at: 1)], notebookId: "nb1", updatedAt: 5)
        try store.apply(pageID, .page(written))

        // The document names only the page; the adapter has to work out which notebook owns it.
        guard case .page(let loaded)? = try store.load(pageID) else {
            return XCTFail("page did not load back")
        }
        XCTAssertEqual(loaded, written)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("notebooks/nb1/pages/p1.json").path))
    }

    /// The index is a cache; a page written by something else (the editor, another sync run)
    /// still has to be found.
    func testPageWrittenOutsideTheStoreIsStillFound() throws {
        let pageID = CouchDocID.page("p9")
        let file = PageFile(
            id: "p9", notebookId: "nb7", createdAt: stamp(0), updatedAt: stamp(1),
            updatedBy: "ipad")
        let url = root.appendingPathComponent("notebooks/nb7/pages/p9.json")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // A manifest has to exist too, since that is what marks a directory as a notebook.
        let manifest = NotebookManifest(
            notebookId: "nb7", title: "x", pageIds: ["p9"], createdAt: stamp(0),
            updatedAt: stamp(1), serverTimestamp: stamp(1))
        try JSONEncoder().encode(manifest).write(
            to: root.appendingPathComponent("notebooks/nb7/manifest.json"))
        try JSONEncoder().encode(file).write(to: url)

        let fresh = FileCouchStore(rootURL: root, deviceID: "ipad")
        guard case .page(let loaded)? = try fresh.load(pageID) else {
            return XCTFail("a page written outside the store was not found")
        }
        XCTAssertEqual(loaded.notebookId, "nb7")
    }

    func testFolderRoundTripsThroughFoldersFile() throws {
        let id = CouchDocID.folder("f1")
        let folder = CouchFolder(
            title: "study", createdAt: stamp(0), updatedAt: stamp(1), updatedBy: "ipad")
        try store.apply(id, .folder(folder))

        guard case .folder(let loaded)? = try store.load(id) else {
            return XCTFail("folder did not load back")
        }
        XCTAssertEqual(loaded.title, "study")
    }

    func testAbsentDocumentsLoadAsNil() throws {
        XCTAssertNil(try store.load(CouchDocID.notebook("missing")))
        XCTAssertNil(try store.load(CouchDocID.page("missing")))
        XCTAssertNil(try store.load(CouchDocID.folder("missing")))
    }

    // MARK: Deletion

    /// Deleting offline has to survive a restart, or the deletion silently never syncs.
    func testALocalDeletionIsRecordedAndOutranksWhatIsStillOnDisk() throws {
        let id = CouchDocID.notebook("nb1")
        try store.apply(id, .notebook(CouchNotebook(
            title: "doomed", pageIds: [], createdAt: stamp(0), updatedAt: stamp(1),
            updatedBy: "ipad")))

        store.recordDeletion(id, deletedAt: stamp(9))

        let reopened = FileCouchStore(rootURL: root, deviceID: "ipad")
        guard case .deleted(let tombstone)? = try reopened.load(id) else {
            return XCTFail("the deletion did not survive")
        }
        XCTAssertEqual(tombstone.deletedAt, stamp(9))
        XCTAssertEqual(reopened.pendingDeletionIDs(), [id])
    }

    func testApplyingARemoteDeletionRemovesTheNotebookAndLeavesNothingToPush() throws {
        let id = CouchDocID.notebook("nb1")
        try store.apply(id, .notebook(CouchNotebook(
            title: "gone", pageIds: [], createdAt: stamp(0), updatedAt: stamp(1),
            updatedBy: "boox")))
        try store.apply(id, .deleted(CouchDeletedDoc(
            type: CouchDocType.notebook, deletedAt: stamp(9), updatedBy: "boox")))

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("notebooks/nb1").path))
        // The tombstone came from the server, so re-pushing it would be pointless traffic.
        XCTAssertTrue(store.pendingDeletionIDs().isEmpty)
    }

    /// Delete-vs-edit resurrection reaches the store as a plain notebook write; it has to undo
    /// the local tombstone or the notebook would be deleted again on the next flush.
    func testWritingANotebookClearsItsPendingDeletion() throws {
        let id = CouchDocID.notebook("nb1")
        store.recordDeletion(id, deletedAt: stamp(5))
        try store.apply(id, .notebook(CouchNotebook(
            title: "back", pageIds: [], createdAt: stamp(0), updatedAt: stamp(9),
            updatedBy: "ipad")))

        XCTAssertTrue(store.pendingDeletionIDs().isEmpty)
        guard case .notebook? = try store.load(id) else {
            return XCTFail("the resurrected notebook should load as a notebook")
        }
    }

    // MARK: Enumeration and conflict copies

    func testAllDocumentIDsCoversFoldersNotebooksPagesAndDeletions() throws {
        try store.apply(CouchDocID.folder("f1"), .folder(CouchFolder(
            title: "school", createdAt: stamp(0), updatedAt: stamp(1), updatedBy: "ipad")))
        try store.apply(CouchDocID.notebook("nb1"), .notebook(CouchNotebook(
            title: "notes", pageIds: ["p1", "p2"], createdAt: stamp(0), updatedAt: stamp(1),
            updatedBy: "ipad")))
        store.recordDeletion(CouchDocID.notebook("nb-old"))

        XCTAssertEqual(store.allDocumentIDs(), [
            "folder:f1", "notebook:nb-old", "notebook:nb1", "page:p1", "page:p2",
        ])
    }

    func testAConflictCopyKeepsTheLocalCopyAndPreservesTheRawDocument() throws {
        let id = CouchDocID.page("p1")
        let mine = page([stroke("mine", at: 1)], notebookId: "nb1", updatedAt: 5)
        try store.apply(id, .page(mine))

        let raw = Data(#"{"type":"page","schema":99,"somethingNew":true}"#.utf8)
        try store.applyConflictCopy(id, json: raw)

        // The local page is untouched — that is the whole promise of this path.
        guard case .page(let stillMine)? = try store.load(id) else {
            return XCTFail("the local page was disturbed")
        }
        XCTAssertEqual(stillMine.strokes.map(\.id), ["mine"])

        // And the unreadable document is kept verbatim rather than reinterpreted.
        let copies = store.allDocumentIDs().filter { $0.hasPrefix("notebook:") && $0 != "notebook:nb1" }
        XCTAssertEqual(copies.count, 1, "a conflict copy notebook should exist")
    }

    // MARK: Images

    private let pictureBytes = Data("PNG-ish bytes, hashed exactly as they are".utf8)
    private var pictureAssetID: String { CouchAssetID.forBytes(pictureBytes) }

    /// Writes a page that places `images/<name>`, the way the editor and the WebDAV engine leave
    /// one behind — file first, page file naming it by path.
    private func placeImage(
        named name: String, in notebookId: String, on pageId: String, bytes: Data? = nil
    ) throws {
        let dir = root.appendingPathComponent("notebooks/\(notebookId)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: NotableImageFiles.directory(in: dir), withIntermediateDirectories: true)
        try (bytes ?? pictureBytes).write(
            to: NotableImageFiles.directory(in: dir).appendingPathComponent(name))
        let manifest = NotebookManifest(
            notebookId: notebookId, title: "album", pageIds: [pageId], createdAt: stamp(0),
            updatedAt: stamp(1), serverTimestamp: stamp(1))
        try JSONEncoder().encode(manifest).write(to: dir.appendingPathComponent("manifest.json"))
        let file = PageFile(
            id: pageId, notebookId: notebookId, createdAt: stamp(0), updatedAt: stamp(1),
            images: [ImageDTO(
                id: "i1", x: 10, y: 20, width: 30, height: 40, uri: "images/\(name)",
                createdAt: stamp(1), updatedAt: stamp(1))],
            updatedBy: "ipad")
        let url = dir.appendingPathComponent("pages/\(pageId).json")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(file).write(to: url)
    }

    /// What a placed image looks like on the wire: a reference to the hash of its bytes, not to
    /// wherever this device happens to keep the file.
    func testAPlacedImageTravelsAsTheHashOfItsBytes() throws {
        try placeImage(named: "holiday.png", in: "nb1", on: "p1")

        guard case .page(let loaded)? = try store.load(CouchDocID.page("p1")) else {
            return XCTFail("the page did not load")
        }
        XCTAssertEqual(loaded.images.map(\.assetId), [pictureAssetID])

        guard case .asset(let asset)? = try store.load(pictureAssetID) else {
            return XCTFail("the bytes behind the reference were not found")
        }
        XCTAssertEqual(asset.data, pictureBytes)
    }

    /// The window this whole mechanism exists for: the page has arrived, the picture has not.
    func testAnIncomingImageIsOwedUntilItsBytesArrive() throws {
        let pageID = CouchDocID.page("p1")
        try store.apply(CouchDocID.notebook("nb1"), .notebook(CouchNotebook(
            title: "album", pageIds: ["p1"], createdAt: stamp(0), updatedAt: stamp(1),
            updatedBy: "boox")))
        try store.apply(pageID, .page(CouchPage(
            notebookId: "nb1",
            images: [CouchImage(
                id: "i1", assetId: pictureAssetID, x: 0, y: 0, width: 4, height: 4,
                createdAt: stamp(1), updatedAt: stamp(1))],
            createdAt: stamp(0), updatedAt: stamp(1), updatedBy: "boox")))

        XCTAssertEqual(try store.missingAssetIDs(), [pictureAssetID])
        XCTAssertNil(try store.load(pictureAssetID), "nothing should claim to hold the bytes yet")

        // Owed across a restart: the page can arrive in one session and the bytes in the next.
        let reopened = FileCouchStore(rootURL: root, deviceID: "ipad")
        XCTAssertEqual(try reopened.missingAssetIDs(), [pictureAssetID])

        try reopened.apply(pictureAssetID, .asset(CouchAsset(
            data: pictureBytes, at: stamp(2), updatedBy: "ipad")))

        XCTAssertTrue(try reopened.missingAssetIDs().isEmpty)
        // And it landed where the page says to look for it, so the renderer finds it.
        guard case .page(let page)? = try reopened.load(pageID) else {
            return XCTFail("the page did not load")
        }
        let notebookDir = root.appendingPathComponent("notebooks/nb1", isDirectory: true)
        let file = try XCTUnwrap(NotableImageFiles.url(
            uri: try XCTUnwrap(readPageFile("nb1", "p1")).images.first?.uri,
            notebookDir: notebookDir))
        XCTAssertEqual(try Data(contentsOf: file), pictureBytes)
        XCTAssertEqual(page.images.map(\.assetId), [pictureAssetID])
    }

    /// An image this device already holds under its own name keeps that name: renaming it to the
    /// hash would orphan the copy the WebDAV backend syncs by filename.
    func testBytesAlreadyHeldKeepTheNameTheyArrivedUnder() throws {
        try placeImage(named: "holiday.png", in: "nb1", on: "p1")

        guard case .page(let loaded)? = try store.load(CouchDocID.page("p1")) else {
            return XCTFail("the page did not load")
        }
        try store.apply(CouchDocID.page("p1"), .page(loaded))

        XCTAssertEqual(readPageFile("nb1", "p1")?.images.first?.uri, "images/holiday.png")
        XCTAssertTrue(try store.missingAssetIDs().isEmpty)
    }

    /// The same picture on two notebooks is one asset document and two files: a notebook's images
    /// live with it, so the download has to land in both places or one of them stays blank.
    func testOnePictureWantedByTwoNotebooksLandsInBoth() throws {
        for notebook in ["nb1", "nb2"] {
            try store.apply(CouchDocID.notebook(notebook), .notebook(CouchNotebook(
                title: notebook, pageIds: ["p-\(notebook)"], createdAt: stamp(0),
                updatedAt: stamp(1), updatedBy: "boox")))
            try store.apply(CouchDocID.page("p-\(notebook)"), .page(CouchPage(
                notebookId: notebook,
                images: [CouchImage(
                    id: "i1", assetId: pictureAssetID, x: 0, y: 0, width: 4, height: 4,
                    createdAt: stamp(1), updatedAt: stamp(1))],
                createdAt: stamp(0), updatedAt: stamp(1), updatedBy: "boox")))
        }

        XCTAssertEqual(try store.missingAssetIDs(), [pictureAssetID])
        try store.apply(pictureAssetID, .asset(CouchAsset(
            data: pictureBytes, at: stamp(2), updatedBy: "ipad")))

        XCTAssertTrue(try store.missingAssetIDs().isEmpty)
        for notebook in ["nb1", "nb2"] {
            let dir = root.appendingPathComponent("notebooks/\(notebook)", isDirectory: true)
            let uri = try XCTUnwrap(readPageFile(notebook, "p-\(notebook)")?.images.first?.uri)
            let file = try XCTUnwrap(NotableImageFiles.url(uri: uri, notebookDir: dir))
            XCTAssertEqual(try Data(contentsOf: file), pictureBytes, "missing in \(notebook)")
        }
    }

    private func readPageFile(_ notebookId: String, _ pageId: String) -> PageFile? {
        let url = root.appendingPathComponent("notebooks/\(notebookId)/pages/\(pageId).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PageFile.self, from: data)
    }

    // MARK: Through the engine

    /// The scenario the adapter exists for: two devices, two directories, one server.
    func testTwoDirectoriesConvergeThroughTheEngine() async throws {
        let server = MockCouchServer()
        let client = CouchDBClient(transport: server, database: "notes")

        let otherRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("bopa-couch-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: otherRoot) }
        let booxStore = FileCouchStore(rootURL: otherRoot, deviceID: "boox")

        let ipad = CouchSyncEngine(client: client, store: store, deviceID: "ipad")
        let boox = CouchSyncEngine(client: client, store: booxStore, deviceID: "boox")

        let pageID = CouchDocID.page("p1")
        try store.apply(pageID, .page(page([stroke("s-ipad", at: 1)], notebookId: "nb1", updatedAt: 5)))
        await ipad.markDirty([pageID])
        _ = await ipad.flush()
        _ = try await boox.pull()

        // The BOOX now has the page as a real file on its own disk.
        guard case .page(let received)? = try booxStore.load(pageID) else {
            return XCTFail("the page did not reach the other directory")
        }
        XCTAssertEqual(received.strokes.map(\.id), ["s-ipad"])

        // It draws, pushes, and the iPad picks the change up.
        var edited = received
        edited.strokes.append(CouchStroke(
            id: "s-boox", createdAt: stamp(9), updatedAt: stamp(9), deviceId: "boox",
            pen: "BALLPEN", color: -16_777_216, size: 3,
            top: 0, bottom: 1, left: 0, right: 1, pointsData: "BBB="))
        edited.updatedAt = stamp(9)
        edited.updatedBy = "boox"
        try booxStore.apply(pageID, .page(edited))
        await boox.markDirty([pageID])
        _ = await boox.flush()
        _ = try await ipad.pull()

        guard case .page(let merged)? = try store.load(pageID) else {
            return XCTFail("the merged page did not land on disk")
        }
        XCTAssertEqual(merged.strokes.map(\.id).sorted(), ["s-boox", "s-ipad"])
    }

    /// The bug this feature fixes: the page travelled, the picture did not. An image placed on one
    /// device must end up as bytes on the other's disk, where its renderer looks for them.
    func testAnImageReachesTheOtherDirectoryAsBytes() async throws {
        let server = MockCouchServer()
        let client = CouchDBClient(transport: server, database: "notes")

        let otherRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("bopa-couch-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: otherRoot) }
        let booxStore = FileCouchStore(rootURL: otherRoot, deviceID: "boox")

        let ipad = CouchSyncEngine(client: client, store: store, deviceID: "ipad")
        let boox = CouchSyncEngine(client: client, store: booxStore, deviceID: "boox")

        try placeImage(named: "holiday.png", in: "nb1", on: "p1")
        await ipad.markDirty(store.allDocumentIDs())
        let pushed = await ipad.flush()
        XCTAssertTrue(pushed.failures.isEmpty, "push failed: \(pushed.failures)")
        // The bytes go first, so the peer never reads a page naming an asset that is not there.
        XCTAssertEqual(pushed.pushed.first, pictureAssetID)

        let pulled = try await boox.pull()
        XCTAssertEqual(pulled.fetchedAssets, [pictureAssetID])

        let file = try XCTUnwrap(NotableImageFiles.url(
            uri: try XCTUnwrap(
                pageFile(in: otherRoot, notebook: "nb1", page: "p1")?.images.first?.uri),
            notebookDir: otherRoot.appendingPathComponent("notebooks/nb1", isDirectory: true)))
        XCTAssertEqual(try Data(contentsOf: file), pictureBytes)

        // Sending the same picture again is not a conflict, it is a no-op: the id is the content.
        await ipad.markDirty([CouchDocID.page("p1")])
        let again = await ipad.flush()
        XCTAssertTrue(again.failures.isEmpty, "re-push failed: \(again.failures)")
    }

    private func pageFile(in root: URL, notebook: String, page: String) -> PageFile? {
        let url = root.appendingPathComponent("notebooks/\(notebook)/pages/\(page).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PageFile.self, from: data)
    }

    func testDidApplyChangesFiresOnWritesButNotReads() throws {
        final class Counter: @unchecked Sendable { var value = 0 }
        let counter = Counter()
        store.didApplyChanges = { counter.value += 1 }

        _ = try store.load(CouchDocID.notebook("missing"))
        XCTAssertEqual(counter.value, 0, "a read should not ask the UI to reload")

        try store.apply(CouchDocID.notebook("nb1"), .notebook(CouchNotebook(
            title: "n", pageIds: [], createdAt: stamp(0), updatedAt: stamp(1), updatedBy: "ipad")))
        XCTAssertEqual(counter.value, 1)
    }
}
