import Foundation
import XCTest
@testable import NotableKit

final class JournalOrganizationTests: XCTestCase {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testSharedNormalizationAndMergeVectors() throws {
        struct Normalization: Decodable { var input: String; var name: String; var key: String }
        struct Merge: Decodable { var name: String; var left: JournalOrganization; var right: JournalOrganization; var expected: JournalOrganization }
        struct Vectors: Decodable { var normalization: [Normalization]; var merges: [Merge] }
        let url = try XCTUnwrap(Bundle.module.url(forResource: "journal-sync-vectors", withExtension: "json"))
        let vectors = try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
        for item in vectors.normalization {
            XCTAssertEqual(journalTopicName(item.input), item.name)
            XCTAssertEqual(journalTopicKey(item.input), item.key)
        }
        for item in vectors.merges {
            XCTAssertEqual(try mergeJournalOrganization(item.left, item.right), item.expected, item.name)
            XCTAssertEqual(try mergeJournalOrganization(item.right, item.left), item.expected, item.name)
            XCTAssertEqual(try mergeJournalOrganization(item.expected, item.expected), item.expected, item.name)
        }
    }

    func testOfflineEditsReopenAndObservedRemovalDoesNotResurrect() throws {
        let directory = try root()
        let a = try JournalOrganizationStore(rootURL: directory)
        try a.capture(notebookID: "note", at: Date(timeIntervalSince1970: 1_794_427_200), timeZone: TimeZone(secondsFromGMT: 0)!)
        try a.setTopic(notebookID: "note", name: "Product", present: true, createdAt: 0)
        let stale = try XCTUnwrap(a.entries()["note"])
        try a.setTopic(notebookID: "note", name: "product", present: false, createdAt: 0)
        _ = try a.merge(stale)
        XCTAssertEqual(a.entries()["note"]?.visibleTopics, [])
        let b = try JournalOrganizationStore(rootURL: directory)
        XCTAssertEqual(b.entries(), a.entries())
        try b.setTopic(notebookID: "note", name: "Product", present: true, createdAt: 0)
        let updated = try XCTUnwrap(b.entries()["note"])
        XCTAssertEqual(updated.date, stale.date)
        XCTAssertGreaterThan(updated.topics["product"]!.counter, stale.topics["product"]!.counter)
        XCTAssertEqual(updated.topics["product"]!.writer, stale.topics["product"]!.writer)
        XCTAssertEqual(updated.visibleTopics, ["Product"])
    }

    func testCanonicalLeadingHashCanBeRemovedAndAddedAgain() throws {
        let store = try JournalOrganizationStore(rootURL: root())
        try store.setTopic(notebookID: "note", name: "##Idea", present: true, createdAt: 0)
        try store.setTopic(notebookID: "note", name: "#Idea", present: false, createdAt: 0)
        XCTAssertEqual(store.entries()["note"]?.topics["#idea"]?.present, false)
        XCTAssertNil(store.entries()["note"]?.topics["idea"])
        try XCTUnwrap(store.entries()["note"]).validate()
    }

    func testCorruptDiskStateIsNeverReplacedWithEmptyMetadata() throws {
        let directory = try root(), url = directory.appendingPathComponent(".bopa-organization.json")
        let corrupt = Data("broken journal".utf8)
        try corrupt.write(to: url)
        XCTAssertThrowsError(try JournalOrganizationStore(rootURL: directory))
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
    }

    func testSyncRetriesConflictsAndPreservesEditsMadeDuringRequest() async throws {
        let store = try JournalOrganizationStore(rootURL: root())
        try store.capture(notebookID: "note", at: Date(timeIntervalSince1970: 1_794_427_200))
        try store.setTopic(notebookID: "note", name: "Product", present: true, createdAt: 0)
        let server = JournalServer()
        await server.setBeforeConflict {
            try store.setTopic(notebookID: "note", name: "Alex", present: true, createdAt: 0)
        }
        let sync = JournalOrganizationSync(client: CouchDBClient(transport: server, database: "notes_organization"), store: store)
        try await sync.sync()
        let remote = await server.entry()
        XCTAssertEqual(remote?.visibleTopics, ["Alex", "Product"])
        XCTAssertEqual(store.entries()["note"]?.visibleTopics, ["Alex", "Product"])
    }

    func testFailedUploadKeepsDurableStateAndRetriesAfterRestart() async throws {
        let directory = try root(), store = try JournalOrganizationStore(rootURL: directory)
        try store.setTopic(notebookID: "note", name: "Product", present: true, createdAt: 0)
        let server = JournalServer(); await server.setFailure(true)
        let client = CouchDBClient(transport: server, database: "notes_organization")
        do { try await JournalOrganizationSync(client: client, store: store).sync(); XCTFail("Expected failure") }
        catch { }
        await server.setFailure(false)
        try await JournalOrganizationSync(client: client, store: JournalOrganizationStore(rootURL: directory)).sync()
        let remote = await server.entry()
        XCTAssertEqual(remote?.visibleTopics, ["Product"])
        XCTAssertNil(remote?.date)
    }

    func testTwoOfflineWritersConvergeThroughLiveCouchDB() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let address = env["BOPA_JOURNAL_TEST_URL"], let url = URL(string: address) else {
            throw XCTSkip("Set BOPA_JOURNAL_TEST_URL for isolated journal CouchDB integration")
        }
        let client = CouchDBClient(transport: URLSessionTransport(baseURL: url,
            username: env["BOPA_JOURNAL_TEST_USER"], password: env["BOPA_JOURNAL_TEST_PASSWORD"]),
            database: env["BOPA_JOURNAL_TEST_DATABASE"] ?? "test_journal_organization")
        let a = try JournalOrganizationStore(rootURL: root()), b = try JournalOrganizationStore(rootURL: root())
        let syncA = JournalOrganizationSync(client: client, store: a)
        let syncB = JournalOrganizationSync(client: client, store: b)
        let id = "swift-test-" + UUID().uuidString.lowercased()
        try a.capture(notebookID: id, at: Date(timeIntervalSince1970: 1_794_427_200), timeZone: TimeZone(secondsFromGMT: 0)!)
        try a.setTopic(notebookID: id, name: "Product", present: true, createdAt: 0)
        try await syncA.sync(); try await syncB.sync()
        let stale = try XCTUnwrap(a.entries()[id])
        try a.setTopic(notebookID: id, name: "Research", present: true, createdAt: 0)
        try b.setTopic(notebookID: id, name: "Alex", present: true, createdAt: 0)
        try await syncA.sync(); try await syncB.sync(); try await syncA.sync()
        XCTAssertEqual(a.entries()[id], b.entries()[id])
        XCTAssertEqual(a.entries()[id]?.visibleTopics, ["Alex", "Product", "Research"])
        try b.setTopic(notebookID: id, name: "Product", present: false, createdAt: 0)
        try await syncB.sync()
        _ = try a.merge(stale)
        try await syncA.sync(); try await syncB.sync()
        XCTAssertEqual(a.entries()[id], b.entries()[id])
        XCTAssertEqual(a.entries()[id]?.visibleTopics, ["Alex", "Research"])
        XCTAssertEqual(a.entries()[id]?.date, stale.date)
    }

    func testMalformedSnapshotsCannotChangeDurableMetadata() async throws {
        let store = try JournalOrganizationStore(rootURL: root())
        try store.setTopic(notebookID: "local", name: "Keep this", present: true, createdAt: 0)
        let before = store.entries()
        let valid = JournalOrganization(notebookId: "note", date: "2026-11-11", createdAt: 1,
            topics: ["product": JournalTopic(name: "Product", present: true, counter: 1, writer: "remote")])
        let original = try JSONSerialization.jsonObject(with: JSONEncoder().encode(valid)) as! [String: Any]
        var invalid: [[String: Any]] = []
        var object = original; object.removeValue(forKey: "date"); invalid.append(object)
        object = original; object["_id"] = "journal:other"; invalid.append(object)
        object = original; object["_deleted"] = true; invalid.append(object)
        for counter in [1.5, "1"] as [Any] {
            object = original
            var topics = object["topics"] as! [String: [String: Any]]
            topics["product"]!["counter"] = counter
            object["topics"] = topics; invalid.append(object)
        }
        let server = JournalServer()
        for item in invalid {
            let body = try JSONSerialization.data(withJSONObject: ["rows": [["id": "journal:note", "doc": item]]])
            await server.setSnapshot(body)
            let sync = JournalOrganizationSync(client: CouchDBClient(transport: server, database: "notes_organization"), store: store)
            do { try await sync.sync(); XCTFail("Expected malformed snapshot rejection") }
            catch { }
            XCTAssertEqual(store.entries(), before)
        }
    }
}

private actor JournalServer: HTTPTransport {
    private var doc: JournalOrganization?
    private var revision = 0
    private var fail = false
    private var beforeConflict: (@Sendable () throws -> Void)?
    private var snapshot: Data?
    func setFailure(_ value: Bool) { fail = value }
    func setBeforeConflict(_ block: @escaping @Sendable () throws -> Void) { beforeConflict = block }
    func setSnapshot(_ data: Data) { snapshot = data }
    func entry() -> JournalOrganization? { doc }
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        if request.path.hasSuffix("_all_docs") {
            if let snapshot { return HTTPResponse(status: 200, body: snapshot) }
            let rows: [[String: Any]] = try doc.map { entry in
                [["id": entry.documentID, "doc": try object(entry)]]
            } ?? []
            return HTTPResponse(status: 200, body: try JSONSerialization.data(withJSONObject: ["rows": rows]))
        }
        if request.method == "GET" {
            guard let doc else { return HTTPResponse(status: 404) }
            return HTTPResponse(status: 200, body: try JSONSerialization.data(withJSONObject: object(doc)))
        }
        if fail { return HTTPResponse(status: 503) }
        if let beforeConflict { self.beforeConflict = nil; try beforeConflict(); return HTTPResponse(status: 409) }
        let supplied = try JSONSerialization.jsonObject(with: request.body!) as! [String: Any]
        if revision > 0 && supplied["_rev"] as? String != "\(revision)-r" { return HTTPResponse(status: 409) }
        doc = try JSONDecoder().decode(JournalOrganization.self, from: request.body!)
        revision += 1
        return HTTPResponse(status: 201, body: Data("{\"rev\":\"\(revision)-r\"}".utf8))
    }
    private func object(_ entry: JournalOrganization) throws -> [String: Any] {
        var value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as! [String: Any]
        value["_id"] = entry.documentID; value["_rev"] = "\(revision)-r"
        return value
    }
}
