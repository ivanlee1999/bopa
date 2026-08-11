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
        /// Attachment bytes, held apart from the body exactly as CouchDB holds them: a document
        /// read never carries them, only a stub saying they exist.
        var attachments: [String: (contentType: String, data: Data)] = [:]
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
    private var changeBatchSizes: [Int] = []

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
            case "GET" where components.count > 2 && components.last == CouchAssetID.blobName:
                return attachment(components.dropLast().dropFirst().joined(separator: "/"))
            case "GET":
                let openRevs = request.query.contains { $0.name == "open_revs" }
                return openRevs ? openRevsAll(tail) : get(tail)
            case "PUT": return put(tail, request)
            default: return HTTPResponse(status: 405)
            }
        }
    }

    // MARK: Verbs

    /// A plain GET, which for a *deleted* document is a 404 — CouchDB does not hand back a
    /// tombstone's body here. Modelling that rather than smoothing it over is what catches a client
    /// that reads "deleted" as "never existed" and re-creates the document.
    private func get(_ documentID: String) -> HTTPResponse {
        guard let doc = docs[documentID] else { return HTTPResponse(status: 404) }
        guard !doc.deleted else {
            let body = #"{"error":"not_found","reason":"deleted"}"#.data(using: .utf8) ?? Data()
            return HTTPResponse(status: 404, body: body)
        }
        return HTTPResponse(status: 200, body: encode(materialize(documentID, doc)))
    }

    /// `?open_revs=all` with `Accept: application/json`: the leaf revisions, including deleted ones,
    /// wrapped one per element. This is the only way to read a tombstone's body back.
    private func openRevsAll(_ documentID: String) -> HTTPResponse {
        guard let doc = docs[documentID] else { return HTTPResponse(status: 404) }
        let leaves = [["ok": materialize(documentID, doc)]]
        let data = (try? JSONSerialization.data(withJSONObject: leaves)) ?? Data()
        return HTTPResponse(status: 200, body: data)
    }

    /// `GET /{db}/{docid}/blob` — the only way to get an attachment's bytes back, since every
    /// document read renders them as a stub.
    private func attachment(_ documentID: String) -> HTTPResponse {
        guard let blob = docs[documentID]?.attachments[CouchAssetID.blobName] else {
            return HTTPResponse(status: 404)
        }
        return HTTPResponse(
            status: 200, headers: ["Content-Type": blob.contentType], body: blob.data)
    }

    private func materialize(_ documentID: String, _ doc: Doc) -> [String: Any] {
        var json = doc.json
        json["_id"] = documentID
        json["_rev"] = doc.rev
        if doc.deleted { json["_deleted"] = true }
        return json
    }

    private func encode(_ json: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
    }

    private func put(_ documentID: String, _ request: HTTPRequest) -> HTTPResponse {
        guard let body = request.body,
              var json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        else { return HTTPResponse(status: 400) }

        let providedRev = json["_rev"] as? String
        let deleted = json["_deleted"] as? Bool ?? false

        if let existing = docs[documentID] {
            // Deleting what is already deleted is a 409 even when the revision is current — a
            // client that answers a peer's tombstone by writing the same tombstone back therefore
            // never converges, it just burns its retries.
            if existing.deleted && deleted { return conflict() }
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
        let attachments = extractAttachments(&json)
        docs[documentID] = Doc(
            rev: newRev, deleted: deleted, json: json, seq: seqCounter, attachments: attachments)

        let result: [String: Any] = ["ok": true, "id": documentID, "rev": newRev]
        // Real CouchDB answers 200 for a tombstone write and 201 for a live one. The mock said
        // 201 for both, which hid a client that rejected every deletion — hence this asymmetry
        // being modelled rather than smoothed over.
        return HTTPResponse(
            status: deleted ? 200 : 201,
            body: (try? JSONSerialization.data(withJSONObject: result)) ?? Data())
    }

    /// Takes inlined attachment bytes out of the body and leaves the stub CouchDB would leave.
    /// Modelled rather than smoothed over: a client that expected to read a blob straight out of
    /// the change feed would pass against a mock that kept the data and fail against a server.
    private func extractAttachments(
        _ json: inout [String: Any]
    ) -> [String: (contentType: String, data: Data)] {
        guard let inlined = json["_attachments"] as? [String: [String: Any]] else { return [:] }
        var stored: [String: (contentType: String, data: Data)] = [:]
        var stubs: [String: [String: Any]] = [:]
        for (name, blob) in inlined {
            let contentType = blob["content_type"] as? String ?? "application/octet-stream"
            let data = (blob["data"] as? String).flatMap { Data(base64Encoded: $0) } ?? Data()
            stored[name] = (contentType, data)
            stubs[name] = ["content_type": contentType, "stub": true, "length": data.count]
        }
        json["_attachments"] = stubs
        return stored
    }

    private func conflict() -> HTTPResponse {
        let body: [String: Any] = ["error": "conflict", "reason": "Document update conflict."]
        return HTTPResponse(
            status: 409, body: (try? JSONSerialization.data(withJSONObject: body)) ?? Data())
    }

    private func changes(_ request: HTTPRequest) -> HTTPResponse {
        let since = Int(request.query.first { $0.name == "since" }?.value ?? "0") ?? 0
        let limit = (request.query.first { $0.name == "limit" }?.value).flatMap(Int.init)
        var rows = docs
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
        // `limit` is honoured, and `last_seq` is then the sequence of the last row actually
        // returned — not the server's newest. A mock that ignored the limit and reported the end of
        // the feed would let a client "page" by asking once and being handed everything, which is
        // exactly the behaviour paging exists to avoid.
        var lastSeq = seqCounter
        if let limit, rows.count > limit {
            rows = Array(rows.prefix(limit))
            lastSeq = (rows.last?["seq"] as? Int) ?? seqCounter
        }
        changeBatchSizes.append(rows.count)
        let result: [String: Any] = ["results": rows, "last_seq": String(lastSeq)]
        return HTTPResponse(
            status: 200, body: (try? JSONSerialization.data(withJSONObject: result)) ?? Data())
    }

    // MARK: Test helpers

    /// How many times the change feed has been read — the way a test tells one request handing
    /// back everything from a genuine walk through the feed.
    func changeRequestCount() -> Int {
        lock.withLock { requestLog.filter { $0.path.hasSuffix("_changes") }.count }
    }

    /// The most rows any single `_changes` response carried. Request *count* cannot tell paging
    /// from its absence — an unpaged read is one big response followed by an empty one, which is
    /// two requests either way — but the size of the largest response can.
    func largestChangeBatch() -> Int {
        lock.withLock { changeBatchSizes.max() ?? 0 }
    }

    /// Forgets what has been asked for so far, for tests that assert about the requests a
    /// *later* step makes.
    func forgetRequests() {
        lock.withLock { requestLog.removeAll() }
    }

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

    /// Runs on the next `load`, to model the editor writing while a merge is in flight.
    var onLoad: (@Sendable () -> Void)?

    func load(_ documentID: String) throws -> CouchDocBody? {
        // The snapshot is taken first, *then* the hook runs: the engine is modelled as having read
        // the document and gone off to the network, with the editor saving while it is away.
        let snapshot = lock.withLock { documents[documentID] }
        onLoad?()
        return snapshot
    }

    /// Honours `CouchLocalStore.apply`'s contract the way a real store must: content that arrived
    /// after the merge took its snapshot is left alone, because the merge never saw it and so
    /// cannot have decided against it. A double that simply overwrote with the merged body would
    /// silently drop ink saved during the round trip — and would hide that bug from these tests.
    func apply(_ documentID: String, _ body: CouchDocBody, basedOn: CouchDocBody?) throws {
        lock.withLock {
            if case .page(let merged) = body, case .page(let current) = documents[documentID],
               case .page(let snapshot)? = basedOn {
                let seen = Set(snapshot.strokes.map(\.id))
                let kept = Set(merged.strokes.map(\.id))
                let tombstoned = Set(merged.deletedStrokes.map(\.id))
                let surviving = current.strokes.filter {
                    !seen.contains($0.id) && !kept.contains($0.id) && !tombstoned.contains($0.id)
                }
                var reconciled = merged
                reconciled.strokes += surviving
                documents[documentID] = .page(reconciled)
            } else {
                documents[documentID] = body
            }
        }
    }

    func applyConflictCopy(_ documentID: String, json: Data) throws {
        lock.withLock { conflictCopies.append(documentID) }
    }

    func allDocumentIDs() throws -> [String] {
        lock.withLock { documents.keys.sorted() }
    }

    /// Every asset a held page places whose bytes are not here — the same question the real store
    /// answers from disk.
    func missingAssetIDs() throws -> [String] {
        lock.withLock {
            Set(documents.values.flatMap(\.referencedAssetIDs))
                .filter { documents[$0] == nil }
                .sorted()
        }
    }

    // MARK: Test helpers

    func set(_ documentID: String, _ body: CouchDocBody) {
        lock.withLock { documents[documentID] = body }
    }

    /// Drops a document without tombstoning it — a notebook this device no longer holds, the way
    /// one looks after its deletion was applied and reaped.
    func remove(_ documentID: String) {
        lock.withLock { documents[documentID] = nil }
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
