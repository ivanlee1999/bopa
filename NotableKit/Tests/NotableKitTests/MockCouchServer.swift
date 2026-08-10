import Foundation
@testable import NotableKit

/// In-memory CouchDB implementing the subset the engine speaks, with real revision checking and a
/// real sequence-ordered change feed — so tests exercise the actual 409-merge loop and checkpoint
/// handling rather than a simplified stand-in.
final class MockCouchServer: HTTPTransport, @unchecked Sendable {
    struct Doc {
        var rev: String
        var deleted: Bool
        var json: [String: Any]
        var seq: Int
    }

    private let lock = NSLock()
    private var docs: [String: Doc] = [:]
    private var seqCounter = 0
    private var revCounter = 0

    /// When set, every request throws — the offline case.
    var isOffline = false
    /// Forces a status for documents whose id is listed, for failure injection.
    var failingDocumentIDs: [String: Int] = [:]
    private(set) var requestLog: [(method: String, path: String)] = []

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        try lock.withLock {
            if isOffline { throw URLError(.notConnectedToInternet) }
            requestLog.append((request.method, request.path))

            let components = request.path.split(separator: "/").map(String.init)
            guard components.count >= 2 else { return HTTPResponse(status: 404) }
            let tail = components.dropFirst().joined(separator: "/")

            if tail == "_changes" { return changes(request) }
            if let status = failingDocumentIDs[tail] { return HTTPResponse(status: status) }

            switch request.method {
            case "GET": return get(tail)
            case "PUT": return put(tail, request)
            default: return HTTPResponse(status: 405)
            }
        }
    }

    // MARK: Verbs

    private func get(_ documentID: String) -> HTTPResponse {
        guard let doc = docs[documentID] else { return HTTPResponse(status: 404) }
        var json = doc.json
        json["_id"] = documentID
        json["_rev"] = doc.rev
        if doc.deleted { json["_deleted"] = true }
        let data = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
        return HTTPResponse(status: 200, body: data)
    }

    private func put(_ documentID: String, _ request: HTTPRequest) -> HTTPResponse {
        guard let body = request.body,
              var json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        else { return HTTPResponse(status: 400) }

        let providedRev = json["_rev"] as? String
        let deleted = json["_deleted"] as? Bool ?? false

        if let existing = docs[documentID] {
            // A stale revision is the whole point of the conflict path; a tombstone may be
            // overwritten without one, which is how a deleted document gets resurrected.
            if !existing.deleted || providedRev != nil {
                guard providedRev == existing.rev else { return conflict() }
            }
        } else if providedRev != nil {
            return conflict()
        }

        revCounter += 1
        seqCounter += 1
        let generation = (docs[documentID]?.rev.split(separator: "-").first).flatMap { Int($0) } ?? 0
        let newRev = "\(generation + 1)-r\(revCounter)"
        json.removeValue(forKey: "_rev")
        json.removeValue(forKey: "_id")
        json.removeValue(forKey: "_deleted")
        docs[documentID] = Doc(rev: newRev, deleted: deleted, json: json, seq: seqCounter)

        let result: [String: Any] = ["ok": true, "id": documentID, "rev": newRev]
        return HTTPResponse(
            status: 201, body: (try? JSONSerialization.data(withJSONObject: result)) ?? Data())
    }

    private func conflict() -> HTTPResponse {
        let body: [String: Any] = ["error": "conflict", "reason": "Document update conflict."]
        return HTTPResponse(
            status: 409, body: (try? JSONSerialization.data(withJSONObject: body)) ?? Data())
    }

    private func changes(_ request: HTTPRequest) -> HTTPResponse {
        let since = Int(request.query.first { $0.name == "since" }?.value ?? "0") ?? 0
        let rows = docs
            .filter { $0.value.seq > since }
            .sorted { $0.value.seq < $1.value.seq }
            .map { id, doc -> [String: Any] in
                var json = doc.json
                json["_id"] = id
                json["_rev"] = doc.rev
                if doc.deleted { json["_deleted"] = true }
                var row: [String: Any] = [
                    "id": id, "seq": doc.seq, "changes": [["rev": doc.rev]], "doc": json,
                ]
                if doc.deleted { row["deleted"] = true }
                return row
            }
        let result: [String: Any] = ["results": rows, "last_seq": String(seqCounter)]
        return HTTPResponse(
            status: 200, body: (try? JSONSerialization.data(withJSONObject: result)) ?? Data())
    }

    // MARK: Test helpers

    func rawDocument(_ documentID: String) -> [String: Any]? {
        lock.withLock { docs[documentID]?.json }
    }

    func revision(_ documentID: String) -> String? {
        lock.withLock { docs[documentID]?.rev }
    }

    func isDeleted(_ documentID: String) -> Bool {
        lock.withLock { docs[documentID]?.deleted ?? false }
    }

    func documentIDs() -> [String] {
        lock.withLock { docs.keys.sorted() }
    }

    /// Writes a document as if another device had pushed it.
    func seed<T: Encodable>(_ documentID: String, _ body: T, deleted: Bool = false) {
        lock.withLock {
            let data = (try? JSONEncoder().encode(body)) ?? Data()
            let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            revCounter += 1
            seqCounter += 1
            let generation = (docs[documentID]?.rev.split(separator: "-").first)
                .flatMap { Int($0) } ?? 0
            docs[documentID] = Doc(
                rev: "\(generation + 1)-r\(revCounter)", deleted: deleted,
                json: json ?? [:], seq: seqCounter)
        }
    }

    /// Writes arbitrary JSON, for documents the engine is meant to fail to understand.
    func seedRaw(_ documentID: String, _ json: [String: Any]) {
        lock.withLock {
            revCounter += 1
            seqCounter += 1
            docs[documentID] = Doc(rev: "1-r\(revCounter)", deleted: false, json: json, seq: seqCounter)
        }
    }
}

/// Dictionary-backed `CouchLocalStore`, standing in for a device's own storage.
final class FakeLocalStore: CouchLocalStore, @unchecked Sendable {
    private let lock = NSLock()
    private var documents: [String: CouchDocBody] = [:]
    private(set) var conflictCopies: [String] = []

    func load(_ documentID: String) throws -> CouchDocBody? {
        lock.withLock { documents[documentID] }
    }

    func apply(_ documentID: String, _ body: CouchDocBody) throws {
        lock.withLock { documents[documentID] = body }
    }

    func applyConflictCopy(_ documentID: String, json: Data) throws {
        lock.withLock { conflictCopies.append(documentID) }
    }

    // MARK: Test helpers

    func set(_ documentID: String, _ body: CouchDocBody) {
        lock.withLock { documents[documentID] = body }
    }

    func page(_ documentID: String) -> CouchPage? {
        lock.withLock {
            if case .page(let page) = documents[documentID] { return page }
            return nil
        }
    }

    func notebook(_ documentID: String) -> CouchNotebook? {
        lock.withLock {
            if case .notebook(let notebook) = documents[documentID] { return notebook }
            return nil
        }
    }

    func body(_ documentID: String) -> CouchDocBody? {
        lock.withLock { documents[documentID] }
    }

    func documentIDs() -> [String] {
        lock.withLock { documents.keys.sorted() }
    }
}
