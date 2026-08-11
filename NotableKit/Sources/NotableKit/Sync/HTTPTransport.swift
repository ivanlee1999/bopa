import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Minimal HTTP abstraction so the sync engine can run against URLSession in the app and an
/// in-memory WebDAV implementation in tests.
public struct HTTPRequest: Sendable {
    public var method: String
    /// Server-absolute path (e.g. "/notable/notebooks/<id>/manifest.json"), resolved against
    /// the transport's base URL.
    public var path: String
    /// Query items, kept as an ordered array rather than a dictionary so requests are reproducible
    /// in tests. Carried separately from `path` because path encoding escapes "?".
    public var query: [HTTPQueryItem]
    public var headers: [String: String]
    public var body: Data?
    /// Per-request timeout in seconds, or nil for the session's default. Set only by the longpoll
    /// path, which must outlast the window it asked the server to hold the connection open.
    public var timeout: TimeInterval?

    public init(
        method: String, path: String, query: [HTTPQueryItem] = [],
        headers: [String: String] = [:], body: Data? = nil, timeout: TimeInterval? = nil
    ) {
        self.method = method
        self.path = path
        self.query = query
        self.headers = headers
        self.body = body
        self.timeout = timeout
    }
}

public struct HTTPQueryItem: Sendable, Equatable {
    public var name: String
    public var value: String

    public init(_ name: String, _ value: String) {
        self.name = name
        self.value = value
    }
}

public struct HTTPResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    /// Case-insensitive header lookup (server ETag casing varies).
    public func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

public protocol HTTPTransport: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

public enum WebDAVError: Error, Equatable {
    case badURL(String)
    case unexpectedStatus(Int, path: String)
    case preconditionFailed(path: String)   // 412: concurrent writer won
    case notFound(path: String)
    case malformedMultistatus
}

/// URLSession-backed transport with HTTP Basic auth.
public struct URLSessionTransport: HTTPTransport {
    public let baseURL: URL
    let authorization: String?
    let session: URLSession

    public init(baseURL: URL, username: String? = nil, password: String? = nil, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
        if let username, let password {
            let token = Data("\(username):\(password)".utf8).base64EncodedString()
            self.authorization = "Basic \(token)"
        } else {
            self.authorization = nil
        }
    }

    /// Resolves a server-absolute request path against `baseURL`. Exposed so the composition can be
    /// asserted without a network: it is where a base URL whose path is wrong (say, one that already
    /// ends in the shared folder) turns into a request for the wrong tree.
    public func url(for path: String, query: [HTTPQueryItem] = []) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: true) else {
            throw WebDAVError.badURL(baseURL.absoluteString)
        }
        let basePath = components.percentEncodedPath.hasSuffix("/")
            ? String(components.percentEncodedPath.dropLast())
            : components.percentEncodedPath
        guard let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            throw WebDAVError.badURL(path)
        }
        components.percentEncodedPath = basePath + encoded
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.name, value: $0.value) }
        }
        guard let url = components.url else { throw WebDAVError.badURL(path) }
        return url
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let url = try url(for: request.path, query: request.query)

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method
        // An idle timer, which is exactly right for a longpoll that asks for no keep-alives: the
        // server is silent for the whole park, so this bounds the wait outright.
        if let timeout = request.timeout { urlRequest.timeoutInterval = timeout }
        urlRequest.httpBody = request.body
        for (k, v) in request.headers { urlRequest.setValue(v, forHTTPHeaderField: k) }
        if let authorization { urlRequest.setValue(authorization, forHTTPHeaderField: "Authorization") }

        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw WebDAVError.unexpectedStatus(-1, path: request.path)
        }
        var headers: [String: String] = [:]
        for (k, v) in http.allHeaderFields {
            if let key = k as? String, let value = v as? String { headers[key] = value }
        }
        return HTTPResponse(status: http.statusCode, headers: headers, body: data)
    }
}
