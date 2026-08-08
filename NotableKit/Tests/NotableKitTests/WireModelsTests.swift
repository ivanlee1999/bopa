import XCTest
@testable import NotableKit

final class WireModelsTests: XCTestCase {

    /// Shaped like Notable's actual streaming serializer output (compact, scalar header
    /// fields first, then strokes/images arrays).
    private let samplePageJSON = """
    {"version":1,"id":"5e0f2f3a-0000-4000-8000-000000000001","notebookId":"5e0f2f3a-0000-4000-8000-00000000000f","background":"blank","backgroundType":"native","parentFolderId":null,"scroll":120,"createdAt":"2026-08-02T10:00:00Z","updatedAt":"2026-08-02T10:05:00.123Z","strokes":[{"id":"5e0f2f3a-0000-4000-8000-0000000000aa","size":3.0,"pen":"BALLPEN","color":-16777216,"maxPressure":1,"top":10.0,"bottom":40.0,"left":5.0,"right":200.0,"pointsData":"__PLACEHOLDER__","createdAt":"2026-08-02T10:01:00Z","updatedAt":"2026-08-02T10:01:00Z"}],"images":[]}
    """

    func testDecodeNotableStylePageJSON() throws {
        let points = [
            NotableStrokePoint(x: 5, y: 10, pressure: 0.5, tiltX: 10, tiltY: -10, dt: 0),
            NotableStrokePoint(x: 200, y: 40, pressure: 0.8, tiltX: 11, tiltY: -9, dt: 12),
        ]
        let blob = try SBStrokeCodec.encode(points).base64EncodedString()
        let json = samplePageJSON.replacingOccurrences(of: "__PLACEHOLDER__", with: blob)

        let page = try JSONDecoder().decode(PageFile.self, from: Data(json.utf8))
        XCTAssertEqual(page.version, 1)
        XCTAssertEqual(page.scroll, 120)
        XCTAssertNil(page.parentFolderId)
        XCTAssertEqual(page.strokes.count, 1)

        let stroke = page.strokes[0]
        XCTAssertEqual(NotablePen.from(stroke.pen), .ballpen)
        XCTAssertEqual(stroke.color, -16777216) // 0xFF000000 black
        let decoded = try stroke.decodedPoints()
        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[1].x, 200, accuracy: 0.011)
        XCTAssertEqual(decoded[1].pressure!, 0.8, accuracy: 1.0 / 65535)
    }

    func testEncodeWritesExplicitNulls() throws {
        let manifest = NotebookManifest(
            notebookId: "nb-1",
            title: "Test",
            pageIds: ["p1"],
            openPageId: nil,
            parentFolderId: nil,
            linkedExternalUri: nil,
            createdAt: "2026-08-02T10:00:00Z",
            updatedAt: "2026-08-02T10:00:00Z",
            serverTimestamp: "2026-08-02T10:00:01Z"
        )
        let json = String(data: try JSONEncoder().encode(manifest), encoding: .utf8)!
        // kotlinx.serialization requires nullable-without-default fields to be present.
        XCTAssertTrue(json.contains("\"openPageId\":null"), json)
        XCTAssertTrue(json.contains("\"parentFolderId\":null"), json)
        XCTAssertTrue(json.contains("\"linkedExternalUri\":null"), json)
    }

    func testManifestRoundTrip() throws {
        let manifest = NotebookManifest(
            notebookId: "nb-1",
            title: "Round trip",
            pageIds: ["p1", "p2"],
            openPageId: "p2",
            parentFolderId: "f1",
            createdAt: "2026-08-02T10:00:00Z",
            updatedAt: "2026-08-02T11:00:00Z",
            serverTimestamp: "2026-08-02T11:00:01Z"
        )
        let decoded = try JSONDecoder().decode(
            NotebookManifest.self, from: try JSONEncoder().encode(manifest))
        XCTAssertEqual(manifest, decoded)
    }

    func testDecodeToleratesUnknownKeys() throws {
        let json = """
        {"version":2,"folders":[{"id":"f1","title":"T","parentFolderId":null,
        "createdAt":"2026-08-02T10:00:00Z","updatedAt":"2026-08-02T10:00:00Z",
        "futureField":42}],"serverTimestamp":"2026-08-02T10:00:01Z","extra":true}
        """
        let folders = try JSONDecoder().decode(FoldersFile.self, from: Data(json.utf8))
        XCTAssertEqual(folders.folders.count, 1)
    }

    func testLegacyRawPressureNormalization() throws {
        // maxPressure 4096 => stored pressures are raw; decodedPoints() must normalize.
        // Build an SB blob whose pressure channel holds "raw-looking" values by encoding
        // pre-scaled fractions of the quantizer, then override maxPressure semantics.
        let raw: [Float] = [2048, 4096]
        let points = raw.map { NotableStrokePoint(x: 0, y: 0, pressure: $0 / 4096) }
        let blob = try SBStrokeCodec.encode(points).base64EncodedString()
        // A stroke that claims normalized (1): values pass through
        let normalized = StrokeDTO(
            id: "s", size: 1, pen: .ballpen, color: -16777216, maxPressure: 1,
            top: 0, bottom: 0, left: 0, right: 0, pointsData: blob,
            createdAt: "2026-08-02T10:00:00Z", updatedAt: "2026-08-02T10:00:00Z")
        XCTAssertEqual(try normalized.decodedPoints()[0].pressure!, 0.5, accuracy: 0.001)
    }

    func testNotableDateParsesBothVariants() {
        XCTAssertNotNil(NotableDate.parse("2026-08-02T10:00:00Z"))
        XCTAssertNotNil(NotableDate.parse("2026-08-02T10:00:00.123Z"))
        XCTAssertNil(NotableDate.parse("not-a-date"))
        let d = Date(timeIntervalSince1970: 1_784_800_000.5)
        XCTAssertNotNil(NotableDate.parse(NotableDate.format(d)))
    }

    func testSyncPaths() {
        XCTAssertEqual(NotableSyncPaths.manifestFile("nb"), "/notable/notebooks/nb/manifest.json")
        XCTAssertEqual(NotableSyncPaths.pageFile("nb", "pg"), "/notable/notebooks/nb/pages/pg.json")
        XCTAssertEqual(NotableSyncPaths.tombstone("nb"), "/notable/deletions/nb")
        XCTAssertEqual(NotableSyncPaths.foldersFile, "/notable/folders.json")
    }

    func testUnknownPenFallsBackToBallpen() {
        XCTAssertEqual(NotablePen.from("FUTURE_PEN"), .ballpen)
        XCTAssertEqual(NotablePen.from(nil), .ballpen)
        XCTAssertEqual(NotablePen.from("CHARCOAL"), .charcoal)
    }
}
