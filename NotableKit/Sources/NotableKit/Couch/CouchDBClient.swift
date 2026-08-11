import Foundation

/// The slice of CouchDB's HTTP API the sync engine uses: read a document, write a document,
/// and follow the change feed. Deliberately not a general client — see
/// `docs/couch-sync-protocol.md` §7 for the full list.
///
/// Full CouchDB replication (`_revs_diff`, `_bulk_docs` with `new_edits:false`, conflict leaves)
/// is not implemented: with a merge that never needs a common ancestor, pushing with the last
/// known `_rev` and merging on 409 keeps the revision tree linear, which removes the whole class
/// of accumulating conflict branches.
public struct CouchDBClient: Sendable {
    public let transport: HTTPTransport
    public let database: String

    public init(transport: HTTPTransport, database: String = "notes") {
        self.transport = transport
        self.database = database
    }

    private func path(_ suffix: String) -> String { "/\(database)/\(suffix)" }

    // MARK: - Documents

    /// A stored document: its revision plus the decoded body. `deleted` marks a tombstone, which
    /// CouchDB still returns a revision for and which the merge treats as a real fact.
    public struct Stored<Body: Sendable>: Sendable {
        public var id: String
        public var rev: String
        public var deleted: Bool
        public var body: Body

        public init(id: String, rev: String, deleted: Bool, body: Body) {
            self.id = id
            self.rev = rev
            self.deleted = deleted
            self.body = body
        }
    }

    /// Fetches a document, or nil when the server has never held one. A tombstone is *not* nil:
    /// it comes back with `deleted == true` so the caller can apply delete-vs-edit.
    public func get<Body: Decodable & Sendable>(
        _ documentID: String, as type: Body.Type
    ) async throws -> Stored<Body>? {
        guard let raw = try await getRaw(documentID) else { return nil }
        let body = try JSONDecoder().decode(Body.self, from: raw.json)
        return Stored(id: documentID, rev: raw.rev, deleted: raw.deleted, body: body)
    }

    /// Raw fetch used when a document must be inspected before its type is known — the
    /// conflict-copy path needs the bytes even when they will not decode.
    public func getRaw(_ documentID: String) async throws -> (rev: String, deleted: Bool, json: Data)? {
        let response = try await send(HTTPRequest(method: "GET", path: path(documentID)))
        switch response.status {
        case 200:
            let meta = try metadata(from: response.body, documentID: documentID)
            return (meta.rev, meta.deleted, response.body)
        case 404:
            // A plain GET of a deleted document is a 404 (`{"error":"not_found","reason":"deleted"}`),
            // not a 200 carrying `_deleted`. Telling "tombstoned" apart from "never existed" needs a
            // second request — and it matters: a caller that reads a tombstone as absent re-creates
            // the document, which silently undoes the peer's deletion.
            return try await getDeleted(documentID)
        default:
            throw error(for: response, path: path(documentID))
        }
    }

    /// The winning leaf via `?open_revs=all`, which — unlike a plain GET — returns deleted
    /// revisions, body and all. 404 here means the document genuinely never existed.
    private func getDeleted(
        _ documentID: String
    ) async throws -> (rev: String, deleted: Bool, json: Data)? {
        let response = try await send(HTTPRequest(
            method: "GET", path: path(documentID),
            query: [HTTPQueryItem("open_revs", "all")],
            // Without this CouchDB answers multipart/mixed, which nothing here can parse.
            headers: ["Accept": "application/json"]))
        guard response.status == 200 else {
            if response.status == 404 { return nil }
            throw error(for: response, path: path(documentID))
        }
        // `[{"ok": {…}}, {"missing": "…"}]` — only the readable leaves carry `ok`.
        //
        // Anything else from a 200 is reported, never read as "absent": absent is what sends the
        // pusher back round as a create, and a create over a tombstone is exactly the resurrection
        // this method exists to prevent. A document the server would not describe has to stay dirty
        // and be retried, not be overwritten on a guess.
        guard let leaves = try? JSONSerialization.jsonObject(with: response.body) as? [[String: Any]]
        else {
            throw CouchError.malformedResponse(
                "GET \(documentID)?open_revs=all did not return a list of revisions")
        }
        guard let document = leaves.compactMap({ $0["ok"] as? [String: Any] }).first,
              let json = try? JSONSerialization.data(withJSONObject: document)
        else {
            throw CouchError.malformedResponse(
                "GET \(documentID)?open_revs=all returned no readable revision")
        }
        let meta = try metadata(from: json, documentID: documentID)
        return (meta.rev, meta.deleted, json)
    }

    /// Writes a document, returning the new revision. `rev` must be the revision this device last
    /// saw; passing nil creates. A `409` surfaces as `CouchError.conflict` for the caller's merge
    /// loop rather than being retried blindly here — the retry needs the merged body.
    @discardableResult
    public func put<Body: Encodable>(
        _ documentID: String, rev: String?, body: Body, deleted: Bool = false
    ) async throws -> String {
        var object = try jsonObject(from: body)
        object["_id"] = documentID
        if let rev { object["_rev"] = rev }
        if deleted { object["_deleted"] = true }

        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let response = try await send(HTTPRequest(
            method: "PUT", path: path(documentID),
            headers: ["Content-Type": "application/json"], body: data))

        switch response.status {
        // 201 for a create, 202 when the write is only accepted — and **200**, which is what a
        // tombstone write actually returns. Rejecting 200 made every notebook deletion fail
        // against a real server while passing against a mock that always answered 201.
        case 200, 201, 202:
            guard let result = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
                  let newRev = result["rev"] as? String
            else { throw CouchError.malformedResponse("PUT \(documentID) returned no rev") }
            return newRev
        case 409:
            throw CouchError.conflict(documentID: documentID)
        default:
            throw error(for: response, path: path(documentID))
        }
    }

    // MARK: - Changes feed

    public struct ChangeRow: Sendable {
        public var id: String
        public var rev: String
        public var deleted: Bool
        /// The document body as raw JSON (`include_docs=true`), decoded by the caller once its
        /// type prefix is known. Absent for rows the server elided.
        public var json: Data?
    }

    public struct Changes: Sendable {
        public var lastSeq: String
        public var rows: [ChangeRow]
    }

    /// Reads the change feed from `since`.
    ///
    /// `longpoll` holds the connection open until something changes or `timeoutMs` elapses — that
    /// is the near-real-time path, and why the reverse proxy in front of CouchDB needs a read
    /// timeout comfortably above this value. A normal feed returns immediately and is used for
    /// catch-up before entering the loop.
    public func changes(
        since: String, longpoll: Bool, timeoutMs: Int = 55_000, limit: Int? = nil
    ) async throws -> Changes {
        var query = [
            HTTPQueryItem("since", since),
            HTTPQueryItem("include_docs", "true"),
            HTTPQueryItem("feed", longpoll ? "longpoll" : "normal"),
        ]
        if longpoll {
            query.append(HTTPQueryItem("timeout", String(timeoutMs)))
            // Without a heartbeat an idle proxy can silently drop a long-held connection.
            query.append(HTTPQueryItem("heartbeat", "15000"))
        }
        if let limit { query.append(HTTPQueryItem("limit", String(limit))) }

        let response = try await send(HTTPRequest(
            method: "GET", path: path("_changes"), query: query))
        guard response.status == 200 else {
            throw error(for: response, path: path("_changes"))
        }
        return try parseChanges(response.body)
    }

    func parseChanges(_ data: Data) throws -> Changes {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CouchError.malformedResponse("_changes is not a JSON object")
        }
        // CouchDB 3 reports `last_seq` as an opaque string; older servers used a number. It is only
        // ever echoed back to the server, so keep whatever shape it arrived in.
        let lastSeq: String
        if let string = root["last_seq"] as? String {
            lastSeq = string
        } else if let number = root["last_seq"] as? NSNumber {
            lastSeq = number.stringValue
        } else {
            throw CouchError.malformedResponse("_changes carried no last_seq")
        }

        let results = root["results"] as? [[String: Any]] ?? []
        let rows: [ChangeRow] = results.compactMap { row in
            guard let id = row["id"] as? String else { return nil }
            let rev = (row["changes"] as? [[String: Any]])?.first?["rev"] as? String ?? ""
            let deleted = row["deleted"] as? Bool ?? false
            let json = (row["doc"] as? [String: Any]).flatMap {
                try? JSONSerialization.data(withJSONObject: $0)
            }
            return ChangeRow(id: id, rev: rev, deleted: deleted, json: json)
        }
        return Changes(lastSeq: lastSeq, rows: rows)
    }

    // MARK: - Attachments

    /// Assets are *written* by `put`, which carries the blob inline in the document — see
    /// `CouchAsset`. Only the read needs its own request: the change feed reports an asset
    /// document as a stub, so the bytes are fetched when a page turns out to need them.
    ///
    /// Fetches an attachment's bytes plus the type the server serves them with. Nil when either the
    /// document or the attachment is absent — for a content-addressed asset that is a peer which
    /// has not uploaded the bytes yet, not an error.
    public func getAttachment(
        _ documentID: String, name: String = CouchAssetID.blobName
    ) async throws -> (data: Data, contentType: String)? {
        let response = try await send(HTTPRequest(
            method: "GET", path: path("\(documentID)/\(name)")))
        switch response.status {
        case 200:
            return (response.body,
                    response.header("Content-Type") ?? CouchAssetID.contentType(of: response.body))
        case 404: return nil
        default: throw error(for: response, path: path(documentID))
        }
    }

    // MARK: - Plumbing

    private func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        do {
            return try await transport.send(request)
        } catch let error as CouchError {
            throw error
        } catch {
            // URLSession surfaces "offline", DNS failures and timeouts as thrown errors rather
            // than statuses. They are all "try again later", never "the document is gone".
            throw CouchError.transport(String(describing: error))
        }
    }

    private func metadata(from data: Data, documentID: String) throws -> (rev: String, deleted: Bool) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rev = object["_rev"] as? String
        else { throw CouchError.malformedResponse("GET \(documentID) carried no _rev") }
        return (rev, object["_deleted"] as? Bool ?? false)
    }

    private func jsonObject<Body: Encodable>(from body: Body) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = try encoder.encode(body)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CouchError.malformedResponse("document body did not encode to a JSON object")
        }
        return object
    }

    private func error(for response: HTTPResponse, path: String) -> CouchError {
        switch response.status {
        case 401, 403: return .unauthorized
        case 404: return .notFound(path: path)
        case 409: return .conflict(documentID: path)
        default: return .server(status: response.status, path: path)
        }
    }
}

public enum CouchError: Error, Equatable {
    /// The stored revision was stale. The caller re-reads, merges, and writes again.
    case conflict(documentID: String)
    case notFound(path: String)
    /// Credentials rejected — worth surfacing immediately, since retrying cannot fix it.
    case unauthorized
    case server(status: Int, path: String)
    /// Offline, DNS failure, timeout: keep the work queued and back off.
    case transport(String)
    case malformedResponse(String)

    /// Whether waiting and trying again could plausibly succeed.
    public var isRetriable: Bool {
        switch self {
        case .transport, .server: return true
        case .conflict, .notFound, .unauthorized, .malformedResponse: return false
        }
    }
}
