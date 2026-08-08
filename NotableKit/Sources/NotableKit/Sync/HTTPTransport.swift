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
    public var headers: [String: String]
    public var body: Data?

    public init(method: String, path: String, headers: [String: String] = [:], body: Data? = nil) {
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
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

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: true) else {
            throw WebDAVError.badURL(baseURL.absoluteString)
        }
        let basePath = components.percentEncodedPath.hasSuffix("/")
            ? String(components.percentEncodedPath.dropLast())
            : components.percentEncodedPath
        guard let encoded = request.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            throw WebDAVError.badURL(request.path)
        }
        components.percentEncodedPath = basePath + encoded
        guard let url = components.url else { throw WebDAVError.badURL(request.path) }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method
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
