import XCTest
@testable import NotableKit

/// The engine against a real CouchDB, rather than `MockCouchServer`.
///
/// The mock encodes what I believe CouchDB does; these tests check that belief — revision
/// handling, the exact 409 conditions, the shape of `_changes` and `last_seq`, and whether a
/// tombstone really comes back on the feed with its body intact.
///
/// Skipped unless `BOPA_COUCH_URL` is set, so the normal `kit` tier stays hermetic:
///
///     docker compose -f docs/deploy/couchdb/docker-compose.yml up -d
///     BOPA_COUCH_URL=http://127.0.0.1:5984 BOPA_COUCH_USER=sync \
///       BOPA_COUCH_PASSWORD=… swift test --filter CouchIntegration
final class CouchIntegrationTests: XCTestCase {

    private var client: CouchDBClient!
    private var namespace = ""

    override func setUpWithError() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let urlString = environment["BOPA_COUCH_URL"], let url = URL(string: urlString) else {
            throw XCTSkip("set BOPA_COUCH_URL to run the integration tests")
        }
        let transport = URLSessionTransport(
            baseURL: url,
            username: environment["BOPA_COUCH_USER"] ?? "sync",
            password: environment["BOPA_COUCH_PASSWORD"] ?? "")
        client = CouchDBClient(
            transport: transport, database: environment["BOPA_COUCH_DATABASE"] ?? "notes")
        // Fresh ids per run so repeated runs against the same database cannot collide.
        namespace = UUID().uuidString.lowercased().prefix(8).description
    }

    private func pageID(_ name: String) -> String { CouchDocID.page("\(namespace)-\(name)") }
    private func notebookID(_ name: String) -> String { CouchDocID.notebook("\(namespace)-\(name)") }

    private func stamp(_ second: Int) -> String {
        NotableDate.format(Date(timeIntervalSince1970: 1_770_000_000 + Double(second)))
    }

    private func stroke(_ id: String, at second: Int, device: String) -> CouchStroke {
        CouchStroke(
            id: id, createdAt: stamp(second), updatedAt: stamp(second), deviceId: device,
            pen: "BALLPEN", color: -16_777_216, size: 3.5,
            top: 0, bottom: 1, left: 0, right: 1, pointsData: "U0ICD10AAAAA")
    }

    private func page(_ strokes: [CouchStroke], updatedAt: Int, by device: String) -> CouchPage {
        CouchPage(
            notebookId: "\(namespace)-nb", strokes: strokes,
            createdAt: stamp(0), updatedAt: stamp(updatedAt), updatedBy: device)
    }

    // MARK: Client

    func testPutThenGetRoundTripsAPageThroughCouchDB() async throws {
        let id = pageID("roundtrip")
        let original = page([stroke("s1", at: 1, device: "ipad")], updatedAt: 5, by: "ipad")

        let rev = try await client.put(id, rev: nil, body: original)
        XCTAssertTrue(rev.hasPrefix("1-"), "first write should be revision 1, got \(rev)")

        let stored = try await client.get(id, as: CouchPage.self)
        XCTAssertEqual(stored?.rev, rev)
        XCTAssertEqual(stored?.body, original, "the page must survive CouchDB byte-for-byte")
        XCTAssertEqual(stored?.body.strokes.first?.pointsData, "U0ICD10AAAAA")
    }

    func testGetOfAnAbsentDocumentIsNilRatherThanAnError() async throws {
        let absent = try await client.get(pageID("never-written"), as: CouchPage.self)
        XCTAssertNil(absent)
    }

    /// The condition the whole push loop is built on: a stale revision must be a 409.
    func testWritingWithAStaleRevisionConflicts() async throws {
        let id = pageID("stale")
        let first = try await client.put(id, rev: nil, body: page([], updatedAt: 1, by: "ipad"))
        _ = try await client.put(id, rev: first, body: page([], updatedAt: 2, by: "ipad"))

        do {
            _ = try await client.put(id, rev: first, body: page([], updatedAt: 3, by: "boox"))
            XCTFail("expected a conflict when writing against a superseded revision")
        } catch CouchError.conflict {
            // expected
        }
    }

    func testCreatingWithoutARevisionOverAnExistingDocumentConflicts() async throws {
        let id = pageID("exists")
        _ = try await client.put(id, rev: nil, body: page([], updatedAt: 1, by: "ipad"))
        do {
            _ = try await client.put(id, rev: nil, body: page([], updatedAt: 2, by: "boox"))
            XCTFail("expected a conflict creating over an existing document")
        } catch CouchError.conflict {
            // expected
        }
    }

    func testChangesFeedReportsWritesAndCarriesTheDocument() async throws {
        let before = try await client.changes(since: "0", longpoll: false)
        let id = pageID("feed")
        let rev = try await client.put(
            id, rev: nil, body: page([stroke("s9", at: 2, device: "boox")], updatedAt: 7, by: "boox"))

        let after = try await client.changes(since: before.lastSeq, longpoll: false)
        let row = after.rows.first { $0.id == id }
        XCTAssertNotNil(row, "the write should appear on the feed")
        XCTAssertEqual(row?.rev, rev)
        XCTAssertNotNil(row?.json, "include_docs should have carried the body")
        XCTAssertNotEqual(after.lastSeq, "0")

        let decoded = try JSONDecoder().decode(CouchPage.self, from: row!.json!)
        XCTAssertEqual(decoded.strokes.map(\.id), ["s9"])
    }

    /// Deletions must arrive as tombstones that still carry a body, or the peer cannot tell a
    /// delete from a document it simply has not seen.
    func testDeletedDocumentsComeBackAsTombstonesWithTheirBody() async throws {
        let id = notebookID("deleted")
        let rev = try await client.put(
            id, rev: nil,
            body: CouchNotebook(
                title: "doomed", pageIds: [], createdAt: stamp(0), updatedAt: stamp(1),
                updatedBy: "ipad"))
        let before = try await client.changes(since: "0", longpoll: false)

        _ = try await client.put(
            id, rev: rev,
            body: CouchDeletedDoc(
                type: CouchDocType.notebook, deletedAt: stamp(10), updatedBy: "ipad"),
            deleted: true)

        let after = try await client.changes(since: before.lastSeq, longpoll: false)
        let row = after.rows.first { $0.id == id }
        XCTAssertEqual(row?.deleted, true)
        let body = try JSONDecoder().decode(CouchDeletedDoc.self, from: row!.json!)
        XCTAssertEqual(body.deletedAt, stamp(10), "the tombstone must keep the time of death")
    }

    /// The near-real-time path: a longpoll held open should return as soon as a write lands.
    func testLongpollReturnsAsSoonAsAWriteArrives() async throws {
        let start = try await client.changes(since: "0", longpoll: false)
        let id = pageID("longpoll")
        // Captured as locals so the detached task does not have to carry `self`.
        let client = self.client!
        let since = start.lastSeq
        let body = page([], updatedAt: 3, by: "boox")

        let waiting = Task {
            try await client.changes(since: since, longpoll: true, timeoutMs: 20_000)
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        _ = try await client.put(id, rev: nil, body: body)

        let began = Date()
        let result = try await waiting.value
        XCTAssertLessThan(
            Date().timeIntervalSince(began), 15,
            "longpoll should return on the write, not sit until the timeout")
        XCTAssertTrue(result.rows.contains { $0.id == id })
    }

    // MARK: Engine

    /// Two engines, one real server: the scenario that fails over WebDAV today.
    func testTwoDevicesEditingOfflineConvergeThroughRealCouchDB() async throws {
        let id = pageID("converge")
        let ipadStore = FakeLocalStore()
        let booxStore = FakeLocalStore()
        let ipad = CouchSyncEngine(client: client, store: ipadStore, deviceID: "ipad")
        let boox = CouchSyncEngine(client: client, store: booxStore, deviceID: "boox")

        ipadStore.set(id, .page(page([stroke("s0", at: 0, device: "ipad")], updatedAt: 1, by: "ipad")))
        await ipad.markDirty([id])
        let firstPush = await ipad.flush()
        XCTAssertEqual(firstPush.pushed, [id])
        _ = try await boox.pull()
        XCTAssertEqual(booxStore.page(id)?.strokes.map(\.id), ["s0"])

        // Both devices go offline and draw.
        var ipadPage = ipadStore.page(id)!
        ipadPage.strokes.append(stroke("s-ipad", at: 10, device: "ipad"))
        ipadPage.updatedAt = stamp(10)
        ipadStore.set(id, .page(ipadPage))
        await ipad.markDirty([id])

        var booxPage = booxStore.page(id)!
        booxPage.strokes.append(stroke("s-boox", at: 11, device: "boox"))
        booxPage.updatedAt = stamp(11)
        booxPage.updatedBy = "boox"
        booxStore.set(id, .page(booxPage))
        await boox.markDirty([id])

        // iPad wins the race; the BOOX must merge rather than clobber.
        _ = await ipad.flush()
        let booxFlush = await boox.flush()
        XCTAssertEqual(booxFlush.merged, [id])
        _ = try await ipad.pull()

        let expected = ["s-boox", "s-ipad", "s0"]
        XCTAssertEqual(ipadStore.page(id)?.strokes.map(\.id).sorted(), expected)
        XCTAssertEqual(booxStore.page(id)?.strokes.map(\.id).sorted(), expected)

        // And the server holds the union, not one device's view of it.
        let onServer = try await client.get(id, as: CouchPage.self)
        XCTAssertEqual(onServer?.body.strokes.map(\.id).sorted(), expected)
    }

    func testErasureSurvivesARoundTripThroughRealCouchDB() async throws {
        let id = pageID("erase")
        let ipadStore = FakeLocalStore()
        let booxStore = FakeLocalStore()
        let ipad = CouchSyncEngine(client: client, store: ipadStore, deviceID: "ipad")
        let boox = CouchSyncEngine(client: client, store: booxStore, deviceID: "boox")

        ipadStore.set(id, .page(page(
            [stroke("keep", at: 1, device: "ipad"), stroke("rub-out", at: 2, device: "ipad")],
            updatedAt: 3, by: "ipad")))
        await ipad.markDirty([id])
        _ = await ipad.flush()
        _ = try await boox.pull()

        var erased = booxStore.page(id)!
        erased.strokes.removeAll { $0.id == "rub-out" }
        erased.deletedStrokes = [CouchTombstone(id: "rub-out", deletedAt: stamp(20))]
        erased.updatedAt = stamp(20)
        erased.updatedBy = "boox"
        booxStore.set(id, .page(erased))
        await boox.markDirty([id])
        _ = await boox.flush()

        _ = try await ipad.pull()
        XCTAssertEqual(ipadStore.page(id)?.strokes.map(\.id), ["keep"])

        // The iPad still had the stroke moments ago; re-pushing must not bring it back.
        await ipad.markDirty([id])
        _ = await ipad.flush()
        let onServer = try await client.get(id, as: CouchPage.self)
        XCTAssertEqual(onServer?.body.strokes.map(\.id), ["keep"])
    }
}
