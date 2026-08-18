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
    /// Watches every response's `Date` header for a clock this device and the server disagree
    /// about (§7). Optional because it is advisory: a client without one syncs identically.
    public let clockSkew: ClockSkewMonitor?

    public init(
        transport: HTTPTransport, database: String = "notes",
        clockSkew: ClockSkewMonitor? = nil
    ) {
        self.transport = transport
        self.database = database
        self.clockSkew = clockSkew
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
        /// type prefix is known.
        ///
        /// Only ever nil for a tombstone. CouchDB answers `"doc": null` for a row whose document
        /// was deleted between the feed reading the sequence and `include_docs` fetching the body,
        /// and the engine already synthesizes what a stripped tombstone needs. A *live* row without
        /// a body is malformed transport data and is rejected at the parser instead — see
        /// `parseChanges`.
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
            // No `heartbeat`, deliberately. CouchDB treats it as *overriding* `timeout`: given
            // both, it holds the connection open until something actually changes, however long
            // that takes — and its keep-alive bytes reset URLSession's idle timer in turn, so the
            // call never returned on its own either. It was added to stop an idle proxy dropping
            // a long-held connection; losing that costs a retry, where keeping it cost the whole
            // rhythm of the pull loop.
        }
        if let limit { query.append(HTTPQueryItem("limit", String(limit))) }

        let response = try await send(HTTPRequest(
            method: "GET", path: path("_changes"), query: query,
            // Outlast the window the server was asked to hold the connection open for.
            timeout: longpoll ? TimeInterval(timeoutMs) / 1000 + 15 : nil))
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

        // Strict, because `last_seq` is checkpointed the moment this batch applies. A row dropped
        // here — a proxy that truncated the response, a server answering a shape this client does
        // not know — is a remote change skipped *permanently*: the checkpoint moves past it and
        // CouchDB never offers it again. Refusing the whole response costs one retry; accepting a
        // partial one costs the change.
        //
        // A document this build cannot *merge* is a different thing and is not rejected here: it is
        // valid transport carrying an unknown schema, and the engine preserves it as a conflict
        // copy and checkpoints it.
        guard let results = root["results"] as? [Any] else {
            throw CouchError.malformedResponse("_changes carried no results array")
        }
        let rows: [ChangeRow] = try results.enumerated().map { index, element in
            guard let row = element as? [String: Any] else {
                throw CouchError.malformedResponse("_changes result \(index) is not an object")
            }
            guard let id = row["id"] as? String, !id.isEmpty else {
                throw CouchError.malformedResponse("_changes result \(index) carried no id")
            }
            guard let rev = (row["changes"] as? [[String: Any]])?.first?["rev"] as? String,
                  !rev.isEmpty
            else {
                throw CouchError.malformedResponse("_changes result \(index) carried no revision")
            }
            // `NSNumber` and not `Bool`: JSONSerialization renders every JSON scalar as NSNumber,
            // so `as? Bool` also accepts `"deleted": 1`. Checking the ObjC type tag is what tells a
            // real Boolean from a number that happens to be castable to one.
            let rawDeleted = row["deleted"]
            let deleted: Bool
            if rawDeleted == nil || rawDeleted is NSNull {
                deleted = false
            } else if let flag = rawDeleted as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID() {
                deleted = flag.boolValue
            } else {
                throw CouchError.malformedResponse(
                    "_changes result \(index) carried a non-Boolean deleted")
            }

            let rawDocument = row["doc"]
            let json: Data?
            if let document = rawDocument as? [String: Any] {
                json = try JSONSerialization.data(withJSONObject: document)
            } else if deleted, rawDocument == nil || rawDocument is NSNull {
                // The one body CouchDB legitimately omits: `include_docs` found the document
                // already deleted. The engine synthesizes the tombstone the merge needs from
                // `deleted` and the revision alone, so there is nothing to fetch and nothing to
                // lose.
                json = nil
            } else {
                throw CouchError.malformedResponse(
                    "_changes result \(index) (\(id)) carried no document")
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
        let attachmentPath = path("\(documentID)/\(name)")
        let response = try await send(HTTPRequest(method: "GET", path: attachmentPath))
        switch response.status {
        case 200:
            return (response.body,
                    response.header("Content-Type") ?? CouchAssetID.contentType(of: response.body))
        case 404: return nil
        default: throw error(for: response, path: attachmentPath)
        }
    }

    // MARK: - Plumbing

    private func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        do {
            let response = try await transport.send(request)
            // Read from every response that came back at all, whatever its status: a 404 or a 409
            // is still the server telling this device what time it thinks it is. Measured here,
            // the moment the response lands, because the interval being computed is exactly
            // "local now minus the instant the server stamped".
            //
            // A request that *threw* is skipped: there is no response, and an offline device has
            // nothing to compare against.
            await clockSkew?.observe(response, receivedAt: Date())
            return response
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
        default:
            return .server(
                status: response.status, path: path,
                retryAfter: Self.retryAfter(response.header("Retry-After")))
        }
    }

    /// `Retry-After` in either shape RFC 9110 allows: a delay in seconds, or an HTTP date.
    ///
    /// Clamped rather than trusted. A misconfigured proxy answering `Retry-After: 86400` would
    /// otherwise park sync for a day — the server gets to slow this device down, not to switch it
    /// off — and a date already in the past means "now", not a negative sleep.
    static func retryAfter(_ header: String?) -> TimeInterval? {
        guard let header = header?.trimmingCharacters(in: .whitespaces), !header.isEmpty else {
            return nil
        }
        let seconds: TimeInterval
        if let delay = TimeInterval(header) {
            seconds = delay
        } else if let date = httpDateFormatter.date(from: header) {
            seconds = date.timeIntervalSinceNow
        } else {
            return nil
        }
        return min(max(seconds, 0), maxRetryAfter)
    }

    /// The longest a server may push this device out. Matches the retry ceiling the controllers
    /// back off to on their own.
    static let maxRetryAfter: TimeInterval = 60
}

/// RFC 9110 §5.6.7 preferred form, in the fixed locale the spec requires — a device set to a
/// non-Gregorian calendar or a non-English locale would otherwise fail to parse a valid header.
private let httpDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    return formatter
}()

public enum CouchError: Error, Equatable {
    /// The stored revision was stale. The caller re-reads, merges, and writes again.
    case conflict(documentID: String)
    case notFound(path: String)
    /// Credentials rejected — worth surfacing immediately, since retrying cannot fix it.
    case unauthorized
    /// Any other status the client does not handle specially. `retryAfter` carries the server's
    /// own answer to "when should I come back", in seconds, when it sent one.
    case server(status: Int, path: String, retryAfter: TimeInterval? = nil)
    /// Offline, DNS failure, timeout: keep the work queued and back off.
    case transport(String)
    case malformedResponse(String)
    /// The database is not the one this device has been syncing with, requires a newer client, or
    /// is locked for a rebuild (§1.2). Never retried: the answer is a human's, not a delay's.
    case databaseIdentity(CouchSyncEngine.DatabaseIdentity)

    /// Whether waiting and trying again could plausibly succeed.
    ///
    /// Every `server` status used to answer yes, which meant a request the server had already
    /// refused on its merits — a document larger than the configured maximum, a malformed request,
    /// a database name this account may not touch — was retried on the same escalating schedule as
    /// a dropped connection, forever, and the one message that would tell the user what to fix
    /// scrolled past between attempts.
    ///
    /// The line is whether *waiting* is plausibly part of the answer. 5xx says the server failed at
    /// something it agreed to do; 408, 425 and 429 say "not now, ask again". Every other 4xx is
    /// this device having asked something the server will keep declining.
    public var isRetriable: Bool {
        switch self {
        case .transport: return true
        case let .server(status, _, _):
            switch status {
            case 408, 425, 429: return true          // timeout, too early, rate limited
            case 500...599: return true              // the server's own fault, possibly transient
            default: return false                    // 400, 403, 405, 413, … will not improve
            }
        // 404 and 409 are inputs to the caller's own logic rather than failures to retry blindly,
        // and no amount of waiting fixes a rejected credential, a response this build cannot parse,
        // or a database whose identity the user has to rule on.
        case .conflict, .notFound, .unauthorized, .malformedResponse, .databaseIdentity:
            return false
        }
    }

    /// How long the server asked this device to wait, if it said. Only meaningful when
    /// `isRetriable`.
    public var retryAfter: TimeInterval? {
        if case let .server(_, _, retryAfter) = self { return retryAfter }
        return nil
    }

    /// One sentence a person can act on, for the reports that reach a UI. The raw case
    /// descriptions ("unauthorized", "server(status: 413, …)") belong in logs; they used to reach
    /// the settings footer verbatim whenever a *flush* failed, while these wordings sat unused on
    /// the pull path only.
    public var userMessage: String {
        switch self {
        case .unauthorized:
            return "Sync rejected the username or password."
        case .transport:
            return "Offline — changes are saved and will sync when you reconnect."
        case .conflict:
            return "Another device kept changing the same notes; will retry shortly."
        case .server(let status, _, _) where status == 413:
            // The one terminal status with an answer the user can act on. Everything else in this
            // class is a server or configuration fault they can only report.
            return "A page is too large for the sync server to accept."
        case .server(let status, _, _):
            return status < 500
                ? "The sync server refused the request (\(status)). Check the sync settings."
                : "The sync server returned an error (\(status))."
        case .notFound, .malformedResponse, .databaseIdentity:
            return String(describing: self)
        }
    }
}
