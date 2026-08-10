import XCTest
@testable import NotableKit

/// Step 2 of the three-step cross-app proof. The other two steps live in notable's
/// `CouchInteropTest.kt`; all three run against one real CouchDB:
///
/// 1. **notable** pushes `page:interop-<id>` carrying one stroke, `boox-stroke`.
/// 2. **bopa** (here) pulls that page, adds `ipad-stroke`, and pushes the result back.
/// 3. **notable** pulls again and must see both strokes.
///
/// What this checks that the per-app suites cannot: that the two independent implementations
/// of the document format and the merge actually agree in the same database — that Kotlin's
/// serializer writes what Swift's decoder expects, and that the merge is the same function on
/// both sides. Driven by `scripts/couch-interop.sh`.
///
/// Skipped unless `BOPA_COUCH_URL` and `COUCH_INTEROP_ID` are both set.
final class CouchInteropTests: XCTestCase {

    private var client: CouchDBClient!
    private var documentID = ""

    override func setUpWithError() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let urlString = environment["BOPA_COUCH_URL"], let url = URL(string: urlString),
              let interopID = environment["COUCH_INTEROP_ID"]
        else {
            throw XCTSkip("set BOPA_COUCH_URL and COUCH_INTEROP_ID to run the interop step")
        }
        client = CouchDBClient(
            transport: URLSessionTransport(
                baseURL: url,
                username: environment["BOPA_COUCH_USER"] ?? "sync",
                password: environment["BOPA_COUCH_PASSWORD"] ?? ""),
            database: environment["BOPA_COUCH_DATABASE"] ?? "notes")
        documentID = CouchDocID.page("interop-\(interopID)")
    }

    func testStep2_bopaMergesItsOwnStrokeIntoTheBooxPage() async throws {
        let store = FakeLocalStore()
        let engine = CouchSyncEngine(client: client, store: store, deviceID: "ipad")

        // Pull what notable wrote. This is the moment Kotlin's output meets Swift's decoder.
        let pull = try await engine.pull()
        XCTAssertTrue(
            pull.applied.contains(documentID),
            "bopa did not receive the page notable pushed — got \(pull.applied)")

        guard let received = store.page(documentID) else {
            return XCTFail("the pulled document did not decode as a page")
        }
        XCTAssertEqual(
            received.strokes.map(\.id), ["boox-stroke"],
            "bopa should see exactly the stroke notable drew")
        XCTAssertEqual(received.updatedBy, "boox")
        XCTAssertEqual(received.notebookId, "interop-nb")

        // Draw on the iPad and push back.
        var edited = received
        edited.strokes.append(CouchStroke(
            id: "ipad-stroke",
            createdAt: NotableDate.format(Date(timeIntervalSince1970: 1_770_000_100)),
            updatedAt: NotableDate.format(Date(timeIntervalSince1970: 1_770_000_100)),
            deviceId: "ipad", pen: "FOUNTAIN", color: -16_777_216, size: 4.25,
            top: 10, bottom: 20, left: 5, right: 15, pointsData: "U0ICD10AAAAA"))
        edited.updatedAt = NotableDate.format(Date(timeIntervalSince1970: 1_770_000_200))
        edited.updatedBy = "ipad"
        store.set(documentID, .page(edited))
        await engine.markDirty([documentID])

        let flush = await engine.flush()
        XCTAssertTrue(
            flush.failures.isEmpty, "pushing back failed: \(flush.failures)")
        XCTAssertTrue(
            flush.pushed.contains(documentID) || flush.merged.contains(documentID),
            "the edited page was not pushed")

        // Confirm on the server, so step 3 is diagnosing notable rather than this step.
        let onServer = try await client.get(documentID, as: CouchPage.self)
        XCTAssertEqual(
            onServer?.body.strokes.map(\.id).sorted(), ["boox-stroke", "ipad-stroke"],
            "the server should hold both devices' strokes")
    }
}
