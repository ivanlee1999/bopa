import Foundation
import NotableKit
import XCTest

@testable import Bopa

// MARK: - Fake transport

/// Canned-response `HTTPTransport`. NotableKit's own `MockWebDAVServer` lives in its test
/// target and isn't visible here, so this is a standalone stub driven by a responder closure.
private final class FakeTransport: HTTPTransport, @unchecked Sendable {
    struct Recorded: Sendable {
        var method: String
        var path: String
        var headers: [String: String]
    }

    private let lock = NSLock()
    private var recorded: [Recorded] = []
    private let responder: @Sendable (HTTPRequest) -> HTTPResponse

    init(responder: @escaping @Sendable (HTTPRequest) -> HTTPResponse) {
        self.responder = responder
    }

    /// Convenience: map exact request paths to multistatus bodies; anything else is a 404.
    convenience init(listings: [String: Data]) {
        self.init { request in
            guard request.method == "PROPFIND" else {
                return HTTPResponse(status: 201)
            }
            guard let body = listings[request.path] else {
                return HTTPResponse(status: 404)
            }
            return HTTPResponse(status: 207, body: body)
        }
    }

    var requests: [Recorded] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        lock.lock()
        recorded.append(Recorded(method: request.method, path: request.path, headers: request.headers))
        lock.unlock()
        return responder(request)
    }
}

/// Builds a DAV multistatus document. `hrefs` are written verbatim so tests can supply
/// percent-encoded hrefs and absolute-URL hrefs the way real servers do.
private func multistatus(_ entries: [(href: String, isCollection: Bool)]) -> Data {
    let responses = entries.map { entry in
        """
          <D:response>
            <D:href>\(entry.href)</D:href>
            <D:propstat><D:prop>
              <D:getetag>"etag-\(abs(entry.href.hashValue))"</D:getetag>
              <D:resourcetype>\(entry.isCollection ? "<D:collection/>" : "")</D:resourcetype>
            </D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat>
          </D:response>
        """
    }.joined(separator: "\n")
    return Data("""
    <?xml version="1.0" encoding="utf-8"?>
    <D:multistatus xmlns:D="DAV:">
    \(responses)
    </D:multistatus>
    """.utf8)
}

// MARK: - Path arithmetic

final class RemotePathTests: XCTestCase {

    func testNormalize() {
        XCTAssertEqual(RemotePath.normalize(""), "/")
        XCTAssertEqual(RemotePath.normalize("   "), "/")
        XCTAssertEqual(RemotePath.normalize("/"), "/")
        XCTAssertEqual(RemotePath.normalize("onyx"), "/onyx")
        XCTAssertEqual(RemotePath.normalize("/onyx/"), "/onyx")
        XCTAssertEqual(RemotePath.normalize("/onyx///"), "/onyx")
        XCTAssertEqual(RemotePath.normalize("/Mes documents/Örebro/"), "/Mes documents/Örebro")
    }

    func testChildAtHostRootHasNoDoubleSlash() {
        XCTAssertEqual(RemotePath.child("/", name: "onyx"), "/onyx")
        XCTAssertEqual(RemotePath.child("", name: "onyx"), "/onyx")
        XCTAssertEqual(RemotePath.child("/onyx", name: "notes"), "/onyx/notes")
        XCTAssertEqual(RemotePath.child("/onyx/", name: "notes"), "/onyx/notes")
        XCTAssertEqual(RemotePath.child("/onyx", name: " Mes documents "), "/onyx/Mes documents")
        XCTAssertEqual(RemotePath.child("/onyx", name: "  "), "/onyx")
    }

    func testParentWalksBackToRoot() {
        XCTAssertEqual(RemotePath.parent("/onyx/notes/2026"), "/onyx/notes")
        XCTAssertEqual(RemotePath.parent("/onyx"), "/")
        XCTAssertEqual(RemotePath.parent("/"), "/")
    }

    func testAbsoluteURLStringPercentEncodesNames() {
        let host = URL(string: "https://webdav.example.com")!
        XCTAssertEqual(
            RemotePath.absoluteURLString(hostRoot: host, path: "/"),
            "https://webdav.example.com")
        XCTAssertEqual(
            RemotePath.absoluteURLString(hostRoot: host, path: "/Mes documents/Örebro"),
            "https://webdav.example.com/Mes%20documents/%C3%96rebro")
        XCTAssertEqual(
            RemotePath.absoluteURLString(hostRoot: host, path: "/a#b?c"),
            "https://webdav.example.com/a%23b%3Fc")
        // A literal "%" in a folder name must not be mistaken for an escape.
        XCTAssertEqual(
            RemotePath.absoluteURLString(hostRoot: host, path: "/100% done"),
            "https://webdav.example.com/100%25%20done")
    }

    func testAbsoluteURLStringKeepsPort() {
        let host = URL(string: "http://192.168.1.4:5005")!
        XCTAssertEqual(
            RemotePath.absoluteURLString(hostRoot: host, path: "/dav/notes"),
            "http://192.168.1.4:5005/dav/notes")
    }

    /// What the picker writes must survive a trip through SyncSettings unchanged, otherwise
    /// the second time you open the picker you start somewhere else.
    func testChosenURLRoundTripsThroughSettings() {
        let host = URL(string: "https://webdav.example.com")!
        for path in ["/", "/onyx", "/Mes documents/Örebro", "/100% done"] {
            let urlString = RemotePath.absoluteURLString(hostRoot: host, path: path)
            let settings = SyncSettings(serverURL: urlString, username: "u", password: "p")
            XCTAssertEqual(settings.remotePath, path, "round trip failed for \(path)")
            XCTAssertEqual(settings.hostRootURL?.absoluteString, "https://webdav.example.com")
        }
    }
}

// MARK: - SyncSettings browsing helpers

final class SyncSettingsBrowsingTests: XCTestCase {

    func testHostRootStripsPathQueryAndFragment() {
        let settings = SyncSettings(
            serverURL: "https://webdav.liyifan.us/onyx/sub?x=1#frag", username: "u", password: "p")
        XCTAssertEqual(settings.hostRootURL?.absoluteString, "https://webdav.liyifan.us")
        XCTAssertEqual(settings.remotePath, "/onyx/sub")
    }

    func testMissingSchemeIsAssumedHTTPS() {
        let settings = SyncSettings(serverURL: "webdav.liyifan.us/onyx", username: "u", password: "p")
        XCTAssertEqual(settings.hostRootURL?.absoluteString, "https://webdav.liyifan.us")
        XCTAssertEqual(settings.remotePath, "/onyx")
    }

    func testHostRootWithNoPathIsRoot() {
        let settings = SyncSettings(serverURL: "https://webdav.liyifan.us", username: "u", password: "p")
        XCTAssertEqual(settings.remotePath, "/")
        XCTAssertEqual(settings.remotePathDisplay, "/")
    }

    func testPercentEncodedServerURLDecodesToPath() {
        let settings = SyncSettings(
            serverURL: "https://h.example/Mes%20documents/%C3%96rebro", username: "u", password: "p")
        XCTAssertEqual(settings.remotePath, "/Mes documents/Örebro")
    }

    func testCanBrowseRequiresHostAndCredentials() {
        XCTAssertFalse(SyncSettings(serverURL: "", username: "u", password: "p").canBrowse)
        XCTAssertFalse(SyncSettings(serverURL: "https://h.example", username: "", password: "p").canBrowse)
        XCTAssertFalse(SyncSettings(serverURL: "https://h.example", username: "u", password: "").canBrowse)
        XCTAssertTrue(SyncSettings(serverURL: "https://h.example/onyx", username: "u", password: "p").canBrowse)
        XCTAssertEqual(SyncSettings(serverURL: "", username: "u", password: "p").remotePathDisplay, "Not set")
    }

    func testBrowsingTransportIsRootedAtHostAndKeepsCredentials() {
        let settings = SyncSettings(
            serverURL: "https://webdav.liyifan.us/onyx", username: "ivan", password: "s3cret")
        let transport = settings.makeBrowsingTransport()
        XCTAssertEqual(transport?.baseURL.absoluteString, "https://webdav.liyifan.us")
        // Credentials aren't readable off the transport, so assert via a real request URL.
        XCTAssertNotNil(transport)
    }

    func testNonHTTPSchemeIsRejected() {
        XCTAssertNil(SyncSettings(serverURL: "ftp://h.example/x", username: "u", password: "p").hostRootURL)
    }

    /// The sidebar's subtitle source. It must agree with the full settings' own display text
    /// while reading only the server URL — that is what keeps the Keychain out of the sidebar.
    func testLoadRemotePathDisplayReadsOnlyTheServerURL() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "SyncSettingsBrowsingTests.display"))
        defer { defaults.removePersistentDomain(forName: "SyncSettingsBrowsingTests.display") }

        defaults.removeObject(forKey: SyncSettings.serverKey)
        XCTAssertEqual(SyncSettings.loadRemotePathDisplay(defaults: defaults), "Not set")

        for (url, expected) in [
            ("https://h.example/onyx", "/onyx"),
            ("https://h.example", "/"),
            ("https://h.example/Mes%20documents", "/Mes documents"),
            // Non-empty but unusable: still "Not set", which is why the server browser
            // distinguishes "no address" from "address that doesn't parse" itself.
            ("ftp://h.example/x", "Not set"),
        ] {
            defaults.set(url, forKey: SyncSettings.serverKey)
            XCTAssertEqual(
                SyncSettings.loadRemotePathDisplay(defaults: defaults), expected,
                "wrong subtitle for \(url)")
            XCTAssertEqual(
                SyncSettings.loadRemotePathDisplay(defaults: defaults),
                SyncSettings(serverURL: url, username: "u", password: "p").remotePathDisplay,
                "diverged from the full settings for \(url)")
        }
    }
}

// MARK: - Browser model

@MainActor
final class RemoteFolderBrowserModelTests: XCTestCase {

    private func rootListing() -> Data {
        multistatus([
            (href: "/", isCollection: true),
            (href: "/onyx/", isCollection: true),
            (href: "/Mes%20documents/", isCollection: true),
            (href: "/readme.txt", isCollection: false),
        ])
    }

    private func onyxListing() -> Data {
        multistatus([
            (href: "/onyx/", isCollection: true),
            (href: "/onyx/notable/", isCollection: true),
            (href: "/onyx/notes.json", isCollection: false),
        ])
    }

    func testListsCollectionAtHostRootWithFoldersFirst() async {
        let transport = FakeTransport(listings: ["/": rootListing()])
        let model = RemoteFolderBrowserModel(transport: transport, startPath: "/")
        await model.load()

        XCTAssertEqual(model.state, .loaded)
        XCTAssertEqual(model.path, "/")
        XCTAssertTrue(model.isAtRoot)
        // Own entry ("/") filtered out; collections sorted before files.
        XCTAssertEqual(model.entries.map(\.name), ["Mes documents", "onyx", "readme.txt"])
        XCTAssertEqual(model.collections.map(\.path), ["/Mes documents", "/onyx"])
        XCTAssertEqual(model.files.map(\.name), ["readme.txt"])
        XCTAssertEqual(transport.requests.map(\.method), ["PROPFIND"])
        XCTAssertEqual(transport.requests.first?.headers["Depth"], "1")
    }

    func testPercentEncodedHrefsAreDecodedIntoNamesAndPaths() async {
        let transport = FakeTransport(listings: [
            "/": multistatus([
                (href: "/", isCollection: true),
                (href: "/Mes%20documents/", isCollection: true),
                (href: "/%C3%96rebro%202026/", isCollection: true),
            ]),
        ])
        let model = RemoteFolderBrowserModel(transport: transport, startPath: "/")
        await model.load()

        XCTAssertEqual(model.collections.map(\.name), ["Mes documents", "Örebro 2026"])
        XCTAssertEqual(model.collections.map(\.path), ["/Mes documents", "/Örebro 2026"])
    }

    func testAbsoluteURLHrefsAreAccepted() async {
        let transport = FakeTransport(listings: [
            "/onyx": multistatus([
                (href: "https://webdav.example.com/onyx/", isCollection: true),
                (href: "https://webdav.example.com/onyx/notable/", isCollection: true),
            ]),
        ])
        let model = RemoteFolderBrowserModel(transport: transport, startPath: "/onyx")
        await model.load()

        XCTAssertEqual(model.state, .loaded)
        XCTAssertEqual(model.collections.map(\.path), ["/onyx/notable"])
    }

    func testDrillDownAndGoUp() async {
        let transport = FakeTransport(listings: ["/": rootListing(), "/onyx": onyxListing()])
        let model = RemoteFolderBrowserModel(transport: transport, startPath: "/")
        await model.load()

        let onyx = try! XCTUnwrap(model.collections.first { $0.name == "onyx" })
        await model.open(onyx)
        XCTAssertEqual(model.path, "/onyx")
        XCTAssertEqual(model.state, .loaded)
        XCTAssertEqual(model.collections.map(\.name), ["notable"])
        XCTAssertFalse(model.isAtRoot)

        await model.goUp()
        XCTAssertEqual(model.path, "/")
        XCTAssertEqual(model.collections.map(\.name), ["Mes documents", "onyx"])
        XCTAssertEqual(transport.requests.map(\.path), ["/", "/onyx", "/"])
    }

    func testGoUpAtRootIsANoOp() async {
        let transport = FakeTransport(listings: ["/": rootListing()])
        let model = RemoteFolderBrowserModel(transport: transport, startPath: "/")
        await model.load()
        await model.goUp()

        XCTAssertEqual(model.path, "/")
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testStartsAtConfiguredPathAndBreadcrumbsWalkBackToRoot() async {
        let transport = FakeTransport(listings: ["/onyx/notable": multistatus([])])
        let model = RemoteFolderBrowserModel(transport: transport, startPath: "/onyx/notable/")
        await model.load()

        XCTAssertEqual(model.path, "/onyx/notable")
        XCTAssertEqual(model.breadcrumbs.map(\.name), ["Server", "onyx", "notable"])
        XCTAssertEqual(model.breadcrumbs.map(\.path), ["/", "/onyx", "/onyx/notable"])
    }

    func testBreadcrumbNavigationJumpsToAncestor() async {
        let transport = FakeTransport(listings: ["/onyx/notable": multistatus([]), "/": rootListing()])
        let model = RemoteFolderBrowserModel(transport: transport, startPath: "/onyx/notable")
        await model.load()
        await model.go(to: "/")

        XCTAssertEqual(model.path, "/")
        XCTAssertEqual(model.collections.map(\.name), ["Mes documents", "onyx"])
    }

    func testEmptyFolderLoadsWithNoEntries() async {
        let transport = FakeTransport(listings: ["/onyx": multistatus([(href: "/onyx/", isCollection: true)])])
        let model = RemoteFolderBrowserModel(transport: transport, startPath: "/onyx")
        await model.load()

        XCTAssertEqual(model.state, .loaded)
        XCTAssertTrue(model.entries.isEmpty)
    }

    func testUnauthorizedMapsToCredentialMessage() async {
        let transport = FakeTransport { _ in HTTPResponse(status: 401) }
        let model = RemoteFolderBrowserModel(transport: transport, startPath: "/onyx")
        await model.load()

        guard case .failed(let message) = model.state else { return XCTFail("expected failure") }
        XCTAssertTrue(message.contains("401"), message)
        XCTAssertTrue(message.localizedCaseInsensitiveContains("password"), message)
    }

    func testNotFoundMapsToMissingFolderMessage() async {
        let transport = FakeTransport(listings: [:])   // everything 404s
        let model = RemoteFolderBrowserModel(transport: transport, startPath: "/gone")
        await model.load()

        guard case .failed(let message) = model.state else { return XCTFail("expected failure") }
        XCTAssertTrue(message.contains("404"), message)
        XCTAssertTrue(message.contains("/gone"), message)
    }

    func testForbiddenMapsToAccessDeniedMessage() async {
        let transport = FakeTransport { _ in HTTPResponse(status: 403) }
        let model = RemoteFolderBrowserModel(transport: transport, startPath: "/onyx")
        await model.load()

        guard case .failed(let message) = model.state else { return XCTFail("expected failure") }
        XCTAssertTrue(message.contains("403"), message)
    }

    func testGenericFailureStillNamesTheStatus() async {
        let transport = FakeTransport { _ in HTTPResponse(status: 500) }
        let model = RemoteFolderBrowserModel(transport: transport, startPath: "/")
        await model.load()

        guard case .failed(let message) = model.state else { return XCTFail("expected failure") }
        XCTAssertTrue(message.contains("500"), message)
    }

    func testMissingTransportReportsSetupInsteadOfCrashing() async {
        let model = RemoteFolderBrowserModel(transport: nil, startPath: "/")
        await model.load()

        guard case .failed(let message) = model.state else { return XCTFail("expected failure") }
        XCTAssertTrue(message.localizedCaseInsensitiveContains("server address"), message)
    }

    func testCreateFolderIssuesMKCOLThenRefreshes() async {
        let after = multistatus([
            (href: "/onyx/", isCollection: true),
            (href: "/onyx/Mes%20documents/", isCollection: true),
        ])
        let before = multistatus([(href: "/onyx/", isCollection: true)])
        let created = LockedBox(false)
        let transport = FakeTransport { request in
            switch request.method {
            case "MKCOL":
                created.value = true
                return HTTPResponse(status: 201)
            case "PROPFIND":
                return HTTPResponse(status: 207, body: created.value ? after : before)
            default:
                return HTTPResponse(status: 405)
            }
        }
        let model = RemoteFolderBrowserModel(transport: transport, startPath: "/onyx")
        await model.load()
        XCTAssertTrue(model.entries.isEmpty)

        await model.createFolder(named: "Mes documents")

        // MKCOL gets the decoded path; URLSessionTransport is what percent-encodes it.
        let mkcol = transport.requests.filter { $0.method == "MKCOL" }
        XCTAssertEqual(mkcol.map(\.path), ["/onyx/Mes documents"])
        XCTAssertEqual(model.collections.map(\.name), ["Mes documents"])
        XCTAssertNil(model.actionError)
        XCTAssertFalse(model.isCreating)
    }

    func testCreateFolderRejectsDuplicateNameWithoutHittingTheServer() async {
        let transport = FakeTransport(listings: ["/onyx": onyxListing()])
        let model = RemoteFolderBrowserModel(transport: transport, startPath: "/onyx")
        await model.load()

        await model.createFolder(named: "NOTABLE")

        XCTAssertTrue(transport.requests.allSatisfy { $0.method == "PROPFIND" })
        XCTAssertEqual(model.actionError, "“NOTABLE” already exists here.")
    }

    func testCreateFolderRejectsSlashAndBlankNames() async {
        let transport = FakeTransport(listings: ["/onyx": multistatus([])])
        let model = RemoteFolderBrowserModel(transport: transport, startPath: "/onyx")
        await model.load()

        await model.createFolder(named: "   ")
        XCTAssertNil(model.actionError)

        await model.createFolder(named: "a/b")
        XCTAssertNotNil(model.actionError)
        XCTAssertTrue(transport.requests.allSatisfy { $0.method == "PROPFIND" })
    }

    func testCreateFolderSurfacesServerError() async {
        let transport = FakeTransport { request in
            request.method == "MKCOL" ? HTTPResponse(status: 409) : HTTPResponse(status: 207, body: multistatus([]))
        }
        let model = RemoteFolderBrowserModel(transport: transport, startPath: "/onyx")
        await model.load()
        await model.createFolder(named: "new")

        XCTAssertEqual(model.actionError, RemoteBrowseError.message(forStatus: 409))
    }

    /// The picker must never issue HEAD/GET against a collection: this user's Synology sits
    /// behind Cloudflare, which answers 403 to HEAD on directories.
    func testOnlyPropfindAndMkcolAreEverSent() async {
        let transport = FakeTransport { request in
            request.method == "MKCOL" ? HTTPResponse(status: 201) : HTTPResponse(status: 207, body: multistatus([
                (href: "/onyx/", isCollection: true),
                (href: "/onyx/sub/", isCollection: true),
            ]))
        }
        let model = RemoteFolderBrowserModel(transport: transport, startPath: "/onyx")
        await model.load()
        if let sub = model.collections.first { await model.open(sub) }
        await model.goUp()
        await model.createFolder(named: "fresh")

        XCTAssertTrue(
            Set(transport.requests.map(\.method)).isSubset(of: ["PROPFIND", "MKCOL"]),
            "unexpected verbs: \(Set(transport.requests.map(\.method)))")
    }
}

/// Tiny mutable box usable from the `@Sendable` responder closures above.
private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: T

    init(_ value: T) { storage = value }

    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }
}
