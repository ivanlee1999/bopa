import XCTest
@testable import NotableKit

final class ScribeTextReaderTests: XCTestCase {
    private func page() -> CouchPage {
        let stroke = CouchStroke(id: "s", createdAt: "2026-11-14T00:00:00Z", updatedAt: "2026-11-14T00:00:00Z",
            deviceId: "boox", pen: "BALLPEN", color: -1, size: 3, top: 1, bottom: 10, left: 1, right: 10, pointsData: "AQ==")
        return CouchPage(notebookId: "book", pageWidth: 1080, pageHeight: 1440, strokes: [stroke],
            createdAt: stroke.createdAt, updatedAt: stroke.updatedAt, updatedBy: "boox")
    }
    private func fixture() -> (MockCouchServer, CouchDBClient, CouchPage, ScribePageText) {
        let server = MockCouchServer(), page = page()
        server.seed("page:p", page)
        let text = ScribePageText(pageId: "p", notebookId: "book", text: "Server text",
            sourceRev: server.revision("page:p"), sourceFingerprint: "sha256:" + String(repeating: "a", count: 64),
            pipelineVersion: "scribe-v2:" + String(repeating: "b", count: 64), format: "markdown")
        server.seed("pagetext:p", text)
        return (server, CouchDBClient(transport: server), page, text)
    }

    func testLegacyProjectionDecodesButCannotBeDisplayedAsVerifiedServerText() throws {
        let data = Data(#"{"pageId":"p","text":"Old text","recognizedClock":"2026-11-14T00:00:00Z","engine":"old"}"#.utf8)
        let text = try JSONDecoder().decode(ScribePageText.self, from: data)
        XCTAssertEqual(text.text, "Old text"); XCTAssertEqual(text.engine, "old")
        XCTAssertEqual(text.recognizedClock, "2026-11-14T00:00:00Z")
        XCTAssertFalse(text.hasSourceIdentity)
    }

    func testVerifiedReadUsesOnlyGETsAndRevalidatesCanonicalRevision() async throws {
        let (server, client, page, _) = fixture()
        let result = try await ScribeTextReader.read(client: client, notebookID: "book", pageID: "p", localInk: ScribeInkSnapshot(page))
        XCTAssertEqual(result?.result.text, "Server text")
        XCTAssertEqual(result?.result.format, "markdown")
        XCTAssertEqual(server.requestLog.map(\.method), ["GET", "GET", "GET"])
        XCTAssertEqual(server.requestLog.map(\.path), ["/notes/page:p", "/notes_text/pagetext:p", "/notes/page:p"])
    }

    func testStaleMissingOrMalformedEnhancedIdentityIsRejected() async throws {
        for variant in 0..<4 {
            let (server, client, page, original) = fixture()
            var text = original
            switch variant {
            case 0: text.sourceRev = "0-stale"
            case 1: text.sourceRev = nil
            case 2: text.sourceFingerprint = "sha256:not-a-hash"
            default: text.pipelineVersion = "legacy"
            }
            server.seed("pagetext:p", text)
            let result = try await ScribeTextReader.read(client: client, notebookID: "book", pageID: "p", localInk: ScribeInkSnapshot(page))
            XCTAssertNil(result)
        }
    }

    func testInkOrderErasureGeometryAndDimensionsMustMatch() async throws {
        for variant in 0..<5 {
            let (server, client, original, text) = fixture()
            var remote = original
            var second = original.strokes[0]; second.id = "second"
            remote.strokes.append(second); server.seed("page:p", remote)
            var currentText = text; currentText.sourceRev = server.revision("page:p"); server.seed("pagetext:p", currentText)
            var local = remote
            switch variant {
            case 0: local.strokes.reverse()
            case 1: local.strokes.removeLast()
            case 2: local.strokes[0].pointsData = "Ag=="
            case 3: local.deletedStrokes = [CouchTombstone(id: "gone", deletedAt: original.updatedAt)]
            default: local.pageWidth = 1200
            }
            let result = try await ScribeTextReader.read(client: client, notebookID: "book", pageID: "p", localInk: ScribeInkSnapshot(local))
            XCTAssertNil(result)
        }
    }

    func testNativeImportedInkMatchesCanonicalSourceWithoutComparingDeviceIdentity() {
        var remote = page()
        remote.deletedStrokes = [CouchTombstone(id: "removed", deletedAt: remote.updatedAt)]
        let local = CouchMapping.pageFile(from: remote, id: "p", existing: nil, notebookDir: URL(fileURLWithPath: "/unused"))
        XCTAssertEqual(ScribeInkSnapshot(local), ScribeInkSnapshot(remote))
    }

    func testChangedRemoteRevisionDuringTextReadIsRejectedEvenForSameInk() async throws {
        let (server, _, page, _) = fixture()
        var renamed = page; renamed.title = "Changed metadata"
        let client = CouchDBClient(transport: ChangingSource(server: server, page: renamed))
        let result = try await ScribeTextReader.read(client: client, notebookID: "book", pageID: "p", localInk: ScribeInkSnapshot(page))
        XCTAssertNil(result)
    }

    func testWrongProjectionIdentityIsRejectedAndTextDatabaseIsConfigurable() async throws {
        let (server, client, page, original) = fixture()
        var text = original; text.notebookId = "another-book"; server.seed("pagetext:p", text)
        let result = try await ScribeTextReader.read(client: client, notebookID: "book", pageID: "p", localInk: ScribeInkSnapshot(page), textDatabase: "scribe_text")
        XCTAssertNil(result)
        XCTAssertTrue(server.requestLog.contains { $0.path == "/scribe_text/pagetext:p" })
    }

    private struct ChangingSource: HTTPTransport {
        let server: MockCouchServer; let page: CouchPage
        func send(_ request: HTTPRequest) async throws -> HTTPResponse {
            XCTAssertEqual(request.method, "GET"); XCTAssertEqual(request.timeout, 8)
            if request.path.contains("pagetext:") { server.seed("page:p", page) }
            return try await server.send(request)
        }
    }
}
