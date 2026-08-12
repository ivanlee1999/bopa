import NotableKit
import XCTest

@testable import Bopa

/// The app layer against a real CouchDB, driven through the wiring the app itself builds.
///
/// `CouchEndToEndTests` hand-wires a store to an engine, which is enough to prove the save path
/// produces syncable documents. This file deliberately does not: it stands up `SyncBackendHost`
/// and lets *it* connect `NotebookStore` to `FileCouchStore` and `CouchSyncEngine`, because the
/// defects this branch fixed all lived in that connection rather than in either end of it. A
/// folder deletion that never reached the outbox was invisible to every engine test — including
/// the 22 shared scenarios, whose scenario stores call `markDirty` directly and so cannot notice a
/// mutation hook that was never called. This is review item 11.
///
/// Self-skipping on an unreachable server, like the tests above it: a machine with no CouchDB
/// still gets a green suite, because a test that fails when the server is absent is worse than no
/// test at all.
///
/// Every document is namespaced by a per-run id, so repeated runs and parallel work share the
/// database without colliding — the same approach `scripts/couch-interop.sh` takes.
///
/// Namespacing prevents collisions but not accumulation, and the two are different problems. The
/// sync account is a database *member*, not a server admin, so these tests cannot create a database
/// of their own the way `scripts/couch-scenarios.sh` does; they share the configured one and leave
/// their documents in it. Every device here starts from an empty checkpoint, so each one replays
/// the whole feed — which means the suite's cost grows with everything every previous run left
/// behind, and a long-lived development database will eventually make it slow and then flaky.
/// Recreating that database is the remedy, and it is safe: nothing here depends on prior contents.
/// Prefer `pushNow()` over `sync()` in a new test unless the pull is the thing being tested.
@MainActor
final class CouchAppLayerEndToEndTests: XCTestCase {
    private let serverURL = "http://127.0.0.1:5984"
    /// The same server reached by another spelling of its address. Used only by the checkpoint
    /// test, which needs two endpoint identities without needing a second database — the sync
    /// account is a member, not an admin, so it cannot create one.
    private let alternateServerURL = "http://localhost:5984"
    private let database = "notes"
    private let username = "sync"
    private let password = "testsyncpw"

    private var rootURL: URL!
    private var namespace = ""

    override func setUp() async throws {
        try await requireServer()
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("bopa-applayer-\(UUID().uuidString)")
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

    // MARK: Devices

    /// One device, assembled the way `BopaApp` assembles it: a store on its own directory, and a
    /// `SyncBackendHost` that wires the mutation hooks. Nothing here reaches past the host to the
    /// engine — that is the point, since a test that queued documents itself would pass whether or
    /// not the app ever queues them.
    @MainActor
    private struct Device {
        let store: NotebookStore
        let host: SyncBackendHost
        let coordinator: SyncCoordinator

        var couch: CouchSyncController { host.couch! }

        /// Pull, then push — "Sync now", and the only sync verb these tests use.
        func sync() async { await couch.syncNow() }
    }

    private func makeDevice(
        _ name: String, serverURL: String? = nil, database: String? = nil, password: String? = nil
    ) throws -> Device {
        let deviceID = "\(name)-\(namespace)"
        // Both the settings and the backend selection are handed to the host rather than written
        // to the real ones. `CouchSettings.save` puts the password in the Keychain, which a test
        // host does not have — the write is refused and the read comes back nil, so a stack built
        // from `CouchSettings.load()` would carry no password and take a 401 on every request. And
        // writing the backend setting would leave the simulator pointed at CouchDB after the run,
        // which is a change to a real user-facing setting that no test should be making.
        let settings = CouchSettings(
            serverURL: serverURL ?? self.serverURL, database: database ?? self.database,
            username: username, password: password ?? self.password, deviceID: deviceID)

        let deviceRoot = rootURL.appendingPathComponent(deviceID, isDirectory: true)
        try FileManager.default.createDirectory(at: deviceRoot, withIntermediateDirectories: true)
        let store = NotebookStore(rootURL: deviceRoot)
        let coordinator = SyncCoordinator()
        let host = SyncBackendHost(loadSettings: { settings }, loadBackend: { .couchdb })
        host.attach(store: store, coordinator: coordinator)
        guard host.couch != nil else { throw XCTSkip("the CouchDB stack did not build") }
        return Device(store: store, host: host, coordinator: coordinator)
    }

    /// A client of our own, to ask the server what it actually holds rather than believing a device.
    private func serverClient(database: String? = nil) -> CouchDBClient {
        CouchDBClient(
            transport: URLSessionTransport(
                baseURL: URL(string: serverURL)!, username: username, password: password),
            database: database ?? self.database)
    }

    /// Whether the server holds this document as a live document, a tombstone, or not at all.
    private enum ServerState: Equatable { case live, deleted, absent }

    private func serverState(_ documentID: String, database: String? = nil) async throws -> ServerState {
        guard let raw = try await serverClient(database: database).getRaw(documentID) else {
            return .absent
        }
        return raw.deleted ? .deleted : .live
    }

    /// The mutation hooks fire into detached tasks, so a test that asserts immediately races them.
    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(300))
    }

    /// Pushes until the server agrees, or gives up and reports what it last saw.
    ///
    /// A single sleep-then-push is a race that a loaded machine loses: `didChangeDocuments` queues
    /// the document from a detached task, and a push that runs before it finds an empty outbox and
    /// sends nothing. Retrying the *push* is what makes this deterministic — polling the server
    /// alone would not, because the missing step is on this side. A document that never reaches
    /// the outbox at all still fails, which is the defect these tests are for.
    private func waitForServerState(
        _ documentID: String, _ expected: ServerState, on device: Device,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        var seen = ServerState.absent
        for _ in 0..<10 {
            seen = try await serverState(documentID)
            if seen == expected { return }
            try await Task.sleep(for: .milliseconds(200))
            await device.couch.pushNow()
        }
        XCTFail(
            "\(documentID) is \(seen) on the server, expected \(expected)", file: file, line: line)
    }

    // MARK: Deletions made through the store

    /// The defect that shipped broken: deleting a folder persisted the tombstone locally but never
    /// queued it, so the folder stayed on the server and came back on the next pull. Every layer
    /// below this was correct and every engine test passed.
    func testAFolderDeletedInTheAppIsDeletedOnTheServerAndStaysGone() async throws {
        let ipad = try makeDevice("folder-ipad")
        let folder = try ipad.store.createFolder(title: "doomed \(namespace)")
        let documentID = CouchDocID.folder(folder.id)
        try await settle()
        try await waitForServerState(documentID, .live, on: ipad)

        try ipad.store.purgeFolder(id: folder.id)
        try await settle()
        try await waitForServerState(documentID, .deleted, on: ipad)

        // And it must not come back: a pull that re-applied the live copy is precisely how the
        // original defect showed itself to the user.
        await ipad.sync()
        ipad.store.refresh()
        XCTAssertFalse(
            ipad.store.folders.contains { $0.id == folder.id },
            "the deleted folder came back on the next sync")
    }

    /// The same question for a notebook, whose deletion travels a different path in the store —
    /// its files are removed and its pages have to stop being tracked with it.
    func testANotebookDeletedInTheAppIsDeletedOnTheServerAndStaysGone() async throws {
        let ipad = try makeDevice("nb-ipad")
        let manifest = try ipad.store.createNotebook(title: "doomed \(namespace)")
        let documentID = CouchDocID.notebook(manifest.notebookId)
        try await settle()
        try await waitForServerState(documentID, .live, on: ipad)

        try ipad.store.purgeNotebook(id: manifest.notebookId)
        try await settle()
        try await waitForServerState(documentID, .deleted, on: ipad)

        await ipad.sync()
        ipad.store.refresh()
        XCTAssertFalse(
            ipad.store.notebooks.contains { $0.notebookId == manifest.notebookId },
            "the deleted notebook came back on the next sync")
    }

    /// Two devices, one database, both deleting the same notebook without knowing about each
    /// other. The second deletion finds the document already deleted on the server; CouchDB
    /// answers a delete of an already-deleted document with `409` however fresh the revision, so
    /// before the convergence rule landed the document stayed queued on that device forever.
    func testTwoDevicesDeletingTheSameNotebookBothSettle() async throws {
        let ipad = try makeDevice("both-ipad")
        let manifest = try ipad.store.createNotebook(title: "contested \(namespace)")
        let documentID = CouchDocID.notebook(manifest.notebookId)
        try await settle()
        try await waitForServerState(documentID, .live, on: ipad)

        let boox = try makeDevice("both-boox")
        await boox.sync()
        boox.store.refresh()
        XCTAssertTrue(
            boox.store.notebooks.contains { $0.notebookId == manifest.notebookId },
            "the second device never received the notebook")

        // Neither device syncs while both delete it.
        try ipad.store.purgeNotebook(id: manifest.notebookId)
        try boox.store.purgeNotebook(id: manifest.notebookId)
        try await settle()

        // Pushed without pulling first, which is the case that used to stick. A pull would hand the
        // second device the server's tombstone and let it discover the deletion had already
        // happened; pushing blind is what makes it PUT a deletion over a deleted document and take
        // the `409` that no revision can satisfy.
        await ipad.couch.pushNow()
        await boox.couch.pushNow()
        // A second round, because "stuck forever" is a claim about what happens next.
        await ipad.couch.pushNow()
        await boox.couch.pushNow()

        let settled = try await serverState(documentID)
        XCTAssertEqual(settled, .deleted)
        XCTAssertEqual(
            ipad.couch.pendingCount, 0, "the first device is still trying to send its deletion")
        XCTAssertEqual(
            boox.couch.pendingCount, 0, "the second device is still trying to send its deletion")
    }

    // MARK: State namespacing

    /// `lastSeq` and the recorded revisions describe one endpoint's change feed and one endpoint's
    /// revisions. They used to live in a single file under the notebook root, so pointing the app
    /// somewhere else handed the new endpoint the old one's checkpoint: a foreign `since` skips
    /// changes silently, and foreign revisions suppress real updates as though they were this
    /// device's own echoes.
    ///
    /// Staged with two spellings of one server's address rather than two databases, because the
    /// sync account is a member and cannot create a second database. It is the same identity that
    /// is under test — the state file is named after the endpoint *and* the database, asserted
    /// directly below — and this half of it can be driven against a real server.
    func testPointingAtAnotherEndpointStartsFromAnIndependentCheckpoint() async throws {
        let first = try makeDevice("checkpoint")
        let manifest = try first.store.createNotebook(title: "checkpoint \(namespace)")
        try await settle()
        await first.sync()
        // Caught up: this device has seen its own write go by and moved its checkpoint past it.
        await first.sync()

        // The same directory, the same device id, the same database — only the address is spelled
        // differently. If the checkpoint were shared, this stack would start from the first one's
        // `lastSeq` and never be told about a notebook written before it.
        let second = try makeDevice(
            "checkpoint", serverURL: alternateServerURL)
        await second.sync()
        second.store.refresh()

        XCTAssertTrue(
            second.store.notebooks.contains { $0.notebookId == manifest.notebookId },
            "the second endpoint reused the first one's checkpoint and skipped the notebook")
    }

    // MARK: Reporting

    /// A flush that stops early still has to say how much is waiting. It breaks on the first
    /// transport, server or auth error rather than firing one doomed request per queued document,
    /// and it used to report only the document it had actually attempted — so the badge read "1"
    /// while the outbox held a dozen.
    ///
    /// Staged with a password the server will refuse, which is a real early break against a real
    /// server rather than a simulated one.
    func testAFlushThatStopsEarlyReportsEverythingStillWaiting() async throws {
        let ipad = try makeDevice("earlybreak", password: "definitely-not-the-password")
        for index in 0..<4 {
            _ = try ipad.store.createNotebook(title: "queued \(index) \(namespace)")
        }
        try await settle()

        await ipad.couch.pushNow()

        // Four notebooks and their four pages; the exact figure matters less than that it counts
        // the documents never attempted rather than only the one that failed.
        XCTAssertGreaterThanOrEqual(
            ipad.couch.pendingCount, 8,
            "the pending count omitted the documents the flush never got to")
    }

    // MARK: The mass-deletion guard

    /// The whole guard, end to end and through the real store: a library that disappears is held
    /// back, "keep them on the server" drops the tombstones, and the notebooks come back.
    ///
    /// The last part is the one that was quietly untrue. Dropping the tombstones stopped the
    /// deletion being published but brought nothing back, because `_changes` never re-announces a
    /// document that has not changed — so the notebooks sat on the server, absent here, with no
    /// path between. The discard now rewinds the checkpoint and forgets those revisions.
    func testDiscardingHeldDeletionsBringsTheNotebooksBackThroughTheApp() async throws {
        let ipad = try makeDevice("guard-ipad")
        var ids: [String] = []
        for index in 0..<12 {
            ids.append(try ipad.store.createNotebook(title: "held \(index) \(namespace)").notebookId)
        }
        try await settle()
        // Push without pulling. The guard asks whether the deletions are most of what this device
        // holds, and a pull from a database shared with every previous run would fill the store
        // with hundreds of other runs' notebooks — a denominator that no twelve deletions could
        // ever be a majority of, so the guard could not trip and the test would silently stop
        // testing it. Nothing here needs the feed until the recovery at the end.
        await ipad.couch.pushNow()
        for id in ids {
            try await waitForServerState(CouchDocID.notebook(id), .live, on: ipad)
        }

        // The library disappears — a wiped database, as far as sync can tell.
        for id in ids { try ipad.store.purgeNotebook(id: id) }
        try await settle()
        await ipad.couch.pushNow()

        XCTAssertEqual(
            ipad.couch.heldDeletions.count, 12,
            "the guard did not hold back a deletion of the whole library")

        await ipad.couch.discardHeldDeletions()
        // Still on the server: declining to publish a deletion must not delete anything.
        for id in ids {
            let kept = try await serverState(CouchDocID.notebook(id))
            XCTAssertEqual(kept, .live, "keeping them on the server deleted one anyway")
        }

        await ipad.sync()
        ipad.store.refresh()
        let recovered = Set(ipad.store.notebooks.map(\.notebookId))
        for id in ids {
            XCTAssertTrue(recovered.contains(id), "notebook \(id) never came back after the discard")
        }
    }
}

/// The half of the state-namespacing rule that is pure computation. Deliberately outside the
/// class above, whose `setUp` skips the whole test when no CouchDB answers — this one needs no
/// server, and gating it would mean the rule went unchecked on exactly the machines that run the
/// suite without one.
final class CouchSyncStateNamingTests: XCTestCase {
    private let serverURL = "http://127.0.0.1:5984"
    private let username = "sync"
    private let password = "testsyncpw"

    /// The other half of that identity, which needs no server: two databases on one address must
    /// not share a state file.
    func testTheStateFileIsNamedAfterBothTheEndpointAndTheDatabase() {
        let base = CouchSettings(
            serverURL: serverURL, database: "notes", username: username, password: password,
            deviceID: "ipad")
        var otherDatabase = base
        otherDatabase.database = "notes-two"
        var otherServer = base
        otherServer.serverURL = "http://couch.example:5984"
        // A password change is not a change of place, and discarding the checkpoint for one would
        // mean replaying the whole feed for nothing.
        var otherPassword = base
        otherPassword.password = "rotated"

        XCTAssertNotEqual(
            CouchSyncStack.stateFileName(for: base),
            CouchSyncStack.stateFileName(for: otherDatabase),
            "two databases on one server shared a checkpoint")
        XCTAssertNotEqual(
            CouchSyncStack.stateFileName(for: base),
            CouchSyncStack.stateFileName(for: otherServer),
            "two servers shared a checkpoint")
        XCTAssertEqual(
            CouchSyncStack.stateFileName(for: base),
            CouchSyncStack.stateFileName(for: otherPassword),
            "changing the password threw the checkpoint away")
    }
}
