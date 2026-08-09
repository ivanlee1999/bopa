import Foundation

/// One entry from a PROPFIND multistatus listing.
public struct DavResource: Equatable, Sendable {
    public var path: String        // decoded server-absolute path, no trailing slash
    public var name: String        // last path component
    public var etag: String?
    public var isCollection: Bool
}

/// WebDAV verbs used by the sync engine, over any HTTPTransport.
public struct WebDAVClient: Sendable {
    public let transport: HTTPTransport

    public init(transport: HTTPTransport) {
        self.transport = transport
    }

    public struct GetResult: Sendable {
        public var notModified: Bool
        public var etag: String?
        public var data: Data
    }

    /// GET with optional If-None-Match. 304 => notModified with empty data.
    public func get(_ path: String, ifNoneMatch: String? = nil) async throws -> GetResult {
        var headers: [String: String] = [:]
        if let ifNoneMatch { headers["If-None-Match"] = ifNoneMatch }
        let r = try await transport.send(HTTPRequest(method: "GET", path: path, headers: headers))
        switch r.status {
        case 200: return GetResult(notModified: false, etag: r.header("Etag"), data: r.body)
        case 304: return GetResult(notModified: true, etag: ifNoneMatch, data: Data())
        case 404: throw WebDAVError.notFound(path: path)
        default: throw WebDAVError.unexpectedStatus(r.status, path: path)
        }
    }

    /// PUT with optional If-Match precondition. Returns the new ETag if the server sent one.
    @discardableResult
    public func put(_ path: String, data: Data, ifMatch: String? = nil) async throws -> String? {
        var headers = ["Content-Type": "application/octet-stream"]
        if let ifMatch { headers["If-Match"] = ifMatch }
        let r = try await transport.send(
            HTTPRequest(method: "PUT", path: path, headers: headers, body: data))
        switch r.status {
        case 200, 201, 204: return r.header("Etag")
        case 412: throw WebDAVError.preconditionFailed(path: path)
        default: throw WebDAVError.unexpectedStatus(r.status, path: path)
        }
    }

    /// MKCOL; succeeds silently if the collection already exists (405/301).
    public func makeCollection(_ path: String) async throws {
        let r = try await transport.send(HTTPRequest(method: "MKCOL", path: path))
        switch r.status {
        case 200, 201, 405, 301: return
        default: throw WebDAVError.unexpectedStatus(r.status, path: path)
        }
    }

    /// DELETE; 404 is treated as success (already gone).
    public func delete(_ path: String) async throws {
        let r = try await transport.send(HTTPRequest(method: "DELETE", path: path))
        switch r.status {
        case 200, 204, 404: return
        default: throw WebDAVError.unexpectedStatus(r.status, path: path)
        }
    }

    /// PROPFIND Depth: 1 listing of a collection. Returns children only (the collection's own
    /// entry is filtered out). Throws .notFound for 404.
    public func list(_ path: String) async throws -> [DavResource] {
        let body = Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <D:propfind xmlns:D="DAV:">
          <D:prop><D:getetag/><D:resourcetype/></D:prop>
        </D:propfind>
        """.utf8)
        let r = try await transport.send(HTTPRequest(
            method: "PROPFIND", path: path,
            headers: ["Depth": "1", "Content-Type": "application/xml"], body: body))
        switch r.status {
        case 207: break
        case 404: throw WebDAVError.notFound(path: path)
        default: throw WebDAVError.unexpectedStatus(r.status, path: path)
        }
        let all = try MultistatusParser.parse(r.body)
        let normalizedSelf = path.hasSuffix("/") ? String(path.dropLast()) : path
        // Keep only DIRECT children. Some servers prefix hrefs (e.g. "/dav/notable/...")
        // so the parent is matched as a substring rather than by equality; requiring
        // exactly one remaining segment then rejects grandchildren, which a server that
        // over-reports depth would otherwise smuggle in as if they were children.
        let marker = "\(normalizedSelf)/"
        return all.compactMap { resource in
            guard resource.path != normalizedSelf,
                  let separator = resource.path.range(of: marker)
            else { return nil }
            let remainder = resource.path[separator.upperBound...]
            guard !remainder.isEmpty, !remainder.contains("/") else { return nil }
            return resource
        }
    }
}

/// Namespace-agnostic parser for WebDAV multistatus responses.
enum MultistatusParser {
    static func parse(_ data: Data) throws -> [DavResource] {
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        let delegate = Delegate()
        parser.delegate = delegate
        guard parser.parse() else { throw WebDAVError.malformedMultistatus }
        return delegate.resources
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var resources: [DavResource] = []
        private var currentHref: String?
        private var currentEtag: String?
        private var currentIsCollection = false
        private var text = ""
        private var inResponse = false

        func parser(
            _ parser: XMLParser, didStartElement elementName: String,
            namespaceURI: String?, qualifiedName: String?, attributes: [String: String]
        ) {
            switch elementName.lowercased() {
            case "response":
                inResponse = true
                currentHref = nil
                currentEtag = nil
                currentIsCollection = false
            case "collection":
                currentIsCollection = true
            default:
                break
            }
            text = ""
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(
            _ parser: XMLParser, didEndElement elementName: String,
            namespaceURI: String?, qualifiedName: String?
        ) {
            switch elementName.lowercased() {
            case "href":
                if inResponse { currentHref = text.trimmingCharacters(in: .whitespacesAndNewlines) }
            case "getetag":
                let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if inResponse, !value.isEmpty { currentEtag = value }
            case "response":
                inResponse = false
                if let href = currentHref {
                    // href may be absolute URL or absolute path, possibly percent-encoded.
                    let rawPath: String
                    if let url = URL(string: href), url.scheme != nil {
                        rawPath = url.path
                    } else {
                        rawPath = href.removingPercentEncoding ?? href
                    }
                    let path = rawPath.hasSuffix("/") ? String(rawPath.dropLast()) : rawPath
                    let name = path.components(separatedBy: "/").last ?? path
                    resources.append(DavResource(
                        path: path, name: name, etag: currentEtag, isCollection: currentIsCollection))
                }
            default:
                break
            }
        }
    }
}
