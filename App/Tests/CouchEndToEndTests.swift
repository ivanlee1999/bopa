import NotableKit
import XCTest

@testable import Bopa

/// The whole bopa chain against a real CouchDB: `NotebookStore` writes a page the way the editor
/// does, the store's per-document signal queues it, the engine pushes it, and a second store on
/// its own directory receives it.
///
/// Everything below the store is already covered in the kit; what this adds is that the app's own
/// save path produces documents the engine can sync — including the tombstone derivation, which
/// only happens in `savePage`.
///
/// Self-skipping: if nothing answers on the CouchDB port, the test skips rather than fails, so
/// this costs nothing in CI.
@MainActor
final class CouchEndToEndTests: XCTestCase {
    private let serverURL = ProcessInfo.processInfo.environment["BOPA_COUCH_URL"] ?? "http://127.0.0.1:5984"
    private let database = ProcessInfo.processInfo.environment["BOPA_COUCH_DATABASE"] ?? "notes"
    private let username = ProcessInfo.processInfo.environment["BOPA_COUCH_USER"] ?? "sync"
    private let password = ProcessInfo.processInfo.environment["BOPA_COUCH_PASSWORD"] ?? "testsyncpw"

    private var rootURL: URL!
    private var namespace = ""

    override func setUp() async throws {
        try await requireServer()
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("bopa-e2e-\(UUID().uuidString)")
        namespace = UUID().uuidString.lowercased().prefix(8).description
    }

    override func tearDown() async throws {
        if let rootURL { try? FileManager.default.removeItem(at: rootURL) }
    }

    private func requireServer() async throws {
        var request = URLRequest(url: URL(string: "\(serverURL)/\(database)")!)
        request.timeoutInterval = 2
        let token = Data("\(username):\(password)".utf8).base64EncodedString()
        request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw XCTSkip("CouchDB at \(serverURL) did not accept the test credentials")
            }
        } catch is XCTSkip {
            throw XCTSkip("CouchDB at \(serverURL) is not reachable")
        } catch {
            throw XCTSkip("CouchDB at \(serverURL) is not reachable: \(error.localizedDescription)")
        }
    }

    private func settings(deviceID: String) -> CouchSettings {
        CouchSettings(
            serverURL: serverURL, database: database, username: username,
            password: password, deviceID: deviceID)
    }

    private func stroke(_ id: String) -> StrokeDTO {
        StrokeDTO(
            id: "\(namespace)-\(id)", size: 3, pen: .ballpen, color: -16_777_216, maxPressure: 1,
            top: 0, bottom: 1, left: 0, right: 1, pointsData: "AAA=",
            createdAt: NotableDate.format(Date()), updatedAt: NotableDate.format(Date()))
    }

    /// Builds a device: its own directory, store, and sync stack, wired the way the app wires them.
    private func makeDevice(
        deviceID: String
    ) throws -> (store: NotebookStore, engine: CouchSyncEngine) {
        let deviceRoot = rootURL.appendingPathComponent(deviceID, isDirectory: true)
        try FileManager.default.createDirectory(at: deviceRoot, withIntermediateDirectories: true)

        let store = NotebookStore(rootURL: deviceRoot)
        store.deviceID = deviceID
        guard let stack = CouchSyncStack.make(
            settings: settings(deviceID: deviceID), rootURL: deviceRoot, onChange: {})
        else {
            throw XCTSkip("could not build the sync stack")
        }
        let engine = stack.engine
        store.didChangeDocuments = { ids in
            Task { await engine.markDirty(ids) }
        }
        return (store, engine)
    }

    /// Native typing reaches another device and edits return through the same real save path.
    func testFlowEditorSourceAndParagraphIDsRoundTripBetweenDevices() async throws {
        let first = try makeDevice(deviceID: "typed-a-\(namespace)")
        let second = try makeDevice(deviceID: "typed-b-\(namespace)")
        let notebook = try first.store.createJournalEntry(topic: "Product")
        let pageID = notebook.pageIds[0]
        let editor = FlowPageModel()
        XCTAssertTrue(editor.attach(store: first.store, notebookID: notebook.notebookId, pageID: pageID))
        editor.update("A typed thought 👋\n\nSecond paragraph", id: try XCTUnwrap(editor.parts.first?.id))
        XCTAssertTrue(editor.flush())
        let original = try first.store.loadPage(notebookId: notebook.notebookId, pageId: pageID)
        try await Task.sleep(for: .milliseconds(200))
        let uploaded = await first.engine.flush()
        XCTAssertTrue(uploaded.failures.isEmpty)
        _ = try await second.engine.pull(); second.store.refresh()
        let remote = FlowPageModel()
        XCTAssertTrue(remote.attach(store: second.store, notebookID: notebook.notebookId, pageID: pageID))
        XCTAssertEqual(remote.parts.first?.source, "A typed thought 👋\n\nSecond paragraph")
        remote.update("A typed thought 👋\n\nEdited on another device", id: try XCTUnwrap(remote.parts.first?.id))
        XCTAssertTrue(remote.flush())
        try await Task.sleep(for: .milliseconds(200))
        let returned = await second.engine.flush()
        XCTAssertTrue(returned.failures.isEmpty)
        _ = try await first.engine.pull(); first.store.refresh()
        let result = try first.store.loadPage(notebookId: notebook.notebookId, pageId: pageID)
        XCTAssertEqual(FlowText.markdown(in: result.blocks), "A typed thought 👋\n\nEdited on another device")
        XCTAssertEqual(Set(result.blocks.filter { $0.kind == "md" }.map(\.id)), Set(original.blocks.filter { $0.kind == "md" }.map(\.id)))
        XCTAssertEqual(first.store.journalEntries[notebook.notebookId]?.visibleTopics, ["Product"])
    }

    /// A page drawn on one device, through its real save path, arriving on another.
    func testAPageDrawnOnOneDeviceReachesTheOther() async throws {
        let ipad = try makeDevice(deviceID: "e2e-ipad-\(namespace)")
        let boox = try makeDevice(deviceID: "e2e-boox-\(namespace)")

        let manifest = try ipad.store.createNotebook(title: "e2e \(namespace)")
        var page = try ipad.store.loadPage(
            notebookId: manifest.notebookId, pageId: manifest.pageIds[0])
        page.strokes = [stroke("a"), stroke("b")]
        try ipad.store.savePage(page)

        // Let the didChangeDocuments tasks land, then push.
        try await Task.sleep(for: .milliseconds(200))
        let flush = await ipad.engine.flush()
        XCTAssertTrue(flush.failures.isEmpty, "push failed: \(flush.failures)")

        _ = try await boox.engine.pull()
        boox.store.refresh()

        let received = boox.store.notebooks.first { $0.notebookId == manifest.notebookId }
        XCTAssertNotNil(received, "the notebook did not arrive")
        let receivedPage = try boox.store.loadPage(
            notebookId: manifest.notebookId, pageId: manifest.pageIds[0])
        XCTAssertEqual(
            receivedPage.strokes.map(\.id).sorted(),
            ["\(namespace)-a", "\(namespace)-b"])
    }

    /// The bug this whole migration is for: erase on one device, and it stays erased on the other
    /// even after that device re-saves the copy it still had.
    func testAnErasureMadeInTheAppSticksOnTheOtherDevice() async throws {
        let ipad = try makeDevice(deviceID: "e2e-ipad-\(namespace)")
        let boox = try makeDevice(deviceID: "e2e-boox-\(namespace)")

        let manifest = try ipad.store.createNotebook(title: "erase \(namespace)")
        let pageId = manifest.pageIds[0]
        var page = try ipad.store.loadPage(notebookId: manifest.notebookId, pageId: pageId)
        page.strokes = [stroke("keep"), stroke("rubout")]
        try ipad.store.savePage(page)
        try await Task.sleep(for: .milliseconds(200))
        _ = await ipad.engine.flush()

        _ = try await boox.engine.pull()
        let onBoox = try boox.store.loadPage(notebookId: manifest.notebookId, pageId: pageId)
        XCTAssertEqual(onBoox.strokes.count, 2)

        // Erase on the iPad, through the real save path — this is where tombstones are derived.
        var erased = try ipad.store.loadPage(notebookId: manifest.notebookId, pageId: pageId)
        erased.strokes.removeAll { $0.id == "\(namespace)-rubout" }
        try ipad.store.savePage(erased)
        try await Task.sleep(for: .milliseconds(200))
        _ = await ipad.engine.flush()

        _ = try await boox.engine.pull()
        let afterErase = try boox.store.loadPage(notebookId: manifest.notebookId, pageId: pageId)
        XCTAssertEqual(
            afterErase.strokes.map(\.id), ["\(namespace)-keep"],
            "the erasure did not reach the other device")

        // The other device still held the erased stroke a moment ago. Saving and pushing its copy
        // must not bring it back — without tombstones, this is exactly where it would.
        var resave = afterErase
        resave.scroll += 1
        try boox.store.savePage(resave)
        try await Task.sleep(for: .milliseconds(200))
        _ = await boox.engine.flush()
        _ = try await ipad.engine.pull()

        let finalPage = try ipad.store.loadPage(notebookId: manifest.notebookId, pageId: pageId)
        XCTAssertEqual(
            finalPage.strokes.map(\.id), ["\(namespace)-keep"],
            "the erased stroke came back")
    }

    /// Both devices draw on the same page with no contact, then sync: nobody loses work.
    func testConcurrentOfflineDrawingOnOnePageKeepsBothDevicesWork() async throws {
        let ipad = try makeDevice(deviceID: "e2e-ipad-\(namespace)")
        let boox = try makeDevice(deviceID: "e2e-boox-\(namespace)")

        let manifest = try ipad.store.createNotebook(title: "both \(namespace)")
        let pageId = manifest.pageIds[0]
        var seed = try ipad.store.loadPage(notebookId: manifest.notebookId, pageId: pageId)
        seed.strokes = [stroke("shared")]
        try ipad.store.savePage(seed)
        try await Task.sleep(for: .milliseconds(200))
        _ = await ipad.engine.flush()
        _ = try await boox.engine.pull()

        // Neither device talks to the server while both draw.
        var ipadPage = try ipad.store.loadPage(notebookId: manifest.notebookId, pageId: pageId)
        ipadPage.strokes.append(stroke("from-ipad"))
        try ipad.store.savePage(ipadPage)

        var booxPage = try boox.store.loadPage(notebookId: manifest.notebookId, pageId: pageId)
        booxPage.strokes.append(stroke("from-boox"))
        try boox.store.savePage(booxPage)
        try await Task.sleep(for: .milliseconds(200))

        _ = await ipad.engine.flush()
        _ = await boox.engine.flush()   // this one hits a 409 and has to merge
        _ = try await ipad.engine.pull()

        let expected = ["\(namespace)-from-boox", "\(namespace)-from-ipad", "\(namespace)-shared"]
        let onIpad = try ipad.store.loadPage(notebookId: manifest.notebookId, pageId: pageId)
        let onBoox = try boox.store.loadPage(notebookId: manifest.notebookId, pageId: pageId)
        XCTAssertEqual(onIpad.strokes.map(\.id).sorted(), expected)
        XCTAssertEqual(onBoox.strokes.map(\.id).sorted(), expected)
    }
}
