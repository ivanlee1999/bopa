import Foundation
@testable import NotableKit

/// In-memory WebDAV server implementing the subset the sync engine uses, with strict ETag
/// and If-Match/If-None-Match semantics and real multistatus XML — so tests exercise the
/// actual client parser and precondition logic.
final class MockWebDAVServer: HTTPTransport, @unchecked Sendable {
    struct File {
        var data: Data
        var etag: String
    }

    private let lock = NSLock()
    private var files: [String: File] = [:]
    private var collections: Set<String> = []
    private var etagCounter = 0
    /// Paths that force a 500, for failure-injection tests.
    var failingPaths: Set<String> = []
    /// Every request the client made, for asserting conditional-request behavior.
    private var requests: [(method: String, path: String, ifNoneMatch: String?)] = []

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        handle(request)
    }

    private func handle(_ request: HTTPRequest) -> HTTPResponse {
        lock.withLock {
            let path = normalize(request.path)
            requests.append((request.method, path, request.headers["If-None-Match"]))
            if failingPaths.contains(path) { return HTTPResponse(status: 500) }

            switch request.method {
            case "GET": return get(path, request)
            case "PUT": return put(path, request)
            case "MKCOL": return mkcol(path)
            case "DELETE": return delete(path)
            case "PROPFIND": return propfind(path, request)
            default: return HTTPResponse(status: 405)
            }
        }
    }

    // MARK: Verbs

    private func get(_ path: String, _ request: HTTPRequest) -> HTTPResponse {
        guard let file = files[path] else { return HTTPResponse(status: 404) }
        if let condition = request.headers["If-None-Match"], condition == file.etag {
            return HTTPResponse(status: 304, headers: ["Etag": file.etag])
        }
        return HTTPResponse(status: 200, headers: ["Etag": file.etag], body: file.data)
    }

    private func put(_ path: String, _ request: HTTPRequest) -> HTTPResponse {
        if let condition = request.headers["If-Match"] {
            guard let existing = files[path], existing.etag == condition else {
                return HTTPResponse(status: 412)
            }
        }
        etagCounter += 1
        let etag = "\"v\(etagCounter)\""
        files[path] = File(data: request.body ?? Data(), etag: etag)
        return HTTPResponse(status: 201, headers: ["Etag": etag])
    }

    private func mkcol(_ path: String) -> HTTPResponse {
        if collections.contains(path) { return HTTPResponse(status: 405) }
        collections.insert(path)
        return HTTPResponse(status: 201)
    }

    private func delete(_ path: String) -> HTTPResponse {
        if files.removeValue(forKey: path) != nil { return HTTPResponse(status: 204) }
        if collections.remove(path) != nil {
            files = files.filter { !$0.key.hasPrefix(path + "/") }
            return HTTPResponse(status: 204)
        }
        return HTTPResponse(status: 404)
    }

    private func propfind(_ path: String, _ request: HTTPRequest) -> HTTPResponse {
        let exists = collections.contains(path) || files[path] != nil
        guard exists else { return HTTPResponse(status: 404) }

        var entries: [(path: String, etag: String?, isCollection: Bool)] = [
            (path, files[path]?.etag, collections.contains(path))
        ]
        if request.headers["Depth"] == "1", collections.contains(path) {
            let prefix = path + "/"
            for (p, f) in files where p.hasPrefix(prefix) && !p.dropFirst(prefix.count).contains("/") {
                entries.append((p, f.etag, false))
            }
            for c in collections where c.hasPrefix(prefix) && !c.dropFirst(prefix.count).contains("/") {
                entries.append((c, nil, true))
            }
        }

        var xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <D:multistatus xmlns:D="DAV:">
        """
        for entry in entries {
            let href = entry.isCollection ? entry.path + "/" : entry.path
            let etagXML = entry.etag.map { "<D:getetag>\($0.replacingOccurrences(of: "\"", with: "&quot;"))</D:getetag>" } ?? ""
            let typeXML = entry.isCollection ? "<D:collection/>" : ""
            xml += """
            <D:response>
              <D:href>\(href)</D:href>
              <D:propstat>
                <D:prop>\(etagXML)<D:resourcetype>\(typeXML)</D:resourcetype></D:prop>
                <D:status>HTTP/1.1 200 OK</D:status>
              </D:propstat>
            </D:response>
            """
        }
        xml += "</D:multistatus>"
        return HTTPResponse(status: 207, body: Data(xml.utf8))
    }

    // MARK: Test helpers

    private func normalize(_ path: String) -> String {
        path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    func fileData(_ path: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return files[normalize(path)]?.data
    }

    func setFile(_ path: String, _ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        etagCounter += 1
        files[normalize(path)] = File(data: data, etag: "\"v\(etagCounter)\"")
        // Auto-create parent collections for convenience.
        var components = normalize(path).components(separatedBy: "/").dropLast()
        while components.count > 1 {
            collections.insert(components.joined(separator: "/"))
            components = components.dropLast()
        }
    }

    /// Requests recorded so far; `clearRequestLog()` resets it between sync runs.
    func requestLog() -> [(method: String, path: String, ifNoneMatch: String?)] {
        lock.withLock { requests }
    }

    func clearRequestLog() {
        lock.withLock { requests.removeAll() }
    }

    func etag(for path: String) -> String? {
        lock.withLock { files[normalize(path)]?.etag }
    }

    func filePaths() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return files.keys.sorted()
    }
}
