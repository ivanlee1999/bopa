import XCTest
@testable import NotableKit

final class CouchMappingTests: XCTestCase {

    /// A notebook directory holding `images/a.png`. Page images map to content-addressed asset
    /// ids, so the mapping is only meaningful against real bytes.
    private var notebookDir: URL!
    private let imageBytes = Data("not really a png, but bytes are bytes".utf8)
    private var imageAssetID: String { CouchAssetID.forBytes(imageBytes) }

    override func setUpWithError() throws {
        notebookDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CouchMappingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: NotableImageFiles.directory(in: notebookDir), withIntermediateDirectories: true)
        try imageBytes.write(
            to: NotableImageFiles.directory(in: notebookDir).appendingPathComponent("a.png"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: notebookDir)
    }

    private func couchPage(from file: PageFile, deviceID: String = "ipad") -> CouchPage {
        CouchMapping.couchPage(from: file, deviceID: deviceID, notebookDir: notebookDir)
    }

    private func stamp(_ second: Int) -> String {
        NotableDate.format(Date(timeIntervalSince1970: 1_770_000_000 + Double(second)))
    }

    private func samplePage() -> PageFile {
        PageFile(
            id: "p1", notebookId: "nb1", background: "grid", backgroundType: "native",
            scroll: 420, createdAt: stamp(0), updatedAt: stamp(5),
            strokes: [StrokeDTO(
                id: "s1", size: 4.5, pen: .fountain, color: -16_777_216, maxPressure: 1,
                top: 1, bottom: 2, left: 3, right: 4, pointsData: "U0IC",
                createdAt: stamp(1), updatedAt: stamp(1))],
            images: [ImageDTO(
                id: "i1", x: 1, y: 2, width: 3, height: 4, uri: "images/a.png",
                createdAt: stamp(2), updatedAt: stamp(2))],
            deletedStrokes: [CouchTombstone(id: "gone", deletedAt: stamp(3))],
            updatedBy: "ipad")
    }

    func testPageRoundTripsThroughTheCouchDocument() {
        let original = samplePage()
        let document = couchPage(from: original)
        let restored = CouchMapping.pageFile(
            from: document, id: "p1", existing: original, notebookDir: notebookDir)
        XCTAssertEqual(restored, original)
    }

    /// Ink is the part that must survive byte-for-byte: `pointsData` is the encoded geometry.
    func testStrokeGeometrySurvivesUnchanged() {
        let document = couchPage(from: samplePage())
        let stroke = document.strokes[0]
        XCTAssertEqual(stroke.pointsData, "U0IC")
        XCTAssertEqual(stroke.color, -16_777_216)
        XCTAssertEqual(stroke.size, 4.5)
        XCTAssertEqual(stroke.pen, "FOUNTAIN")
    }

    /// A pen this build has not learned must come back as itself, not be flattened to a ballpen.
    func testUnknownPenNameSurvives() {
        var document = couchPage(from: samplePage())
        document.strokes[0].pen = "SOME_FUTURE_PEN"
        let restored = CouchMapping.pageFile(
            from: document, id: "p1", existing: nil, notebookDir: notebookDir)
        XCTAssertEqual(restored.strokes[0].pen, "SOME_FUTURE_PEN")
    }

    /// Scroll position is this device's, not the notebook's: an incoming change must not yank
    /// the reader back to the top of the page.
    func testScrollPositionIsNotTakenFromTheServer() {
        let local = samplePage()
        var incoming = couchPage(from: local, deviceID: "boox")
        incoming.strokes = []
        let restored = CouchMapping.pageFile(
            from: incoming, id: "p1", existing: local, notebookDir: notebookDir)
        XCTAssertEqual(restored.scroll, 420)
    }

    func testTombstonesTravelWithThePage() {
        let document = couchPage(from: samplePage())
        XCTAssertEqual(document.deletedStrokes.map(\.id), ["gone"])
        let restored = CouchMapping.pageFile(
            from: document, id: "p1", existing: nil, notebookDir: notebookDir)
        XCTAssertEqual(restored.deletedStrokes.map(\.id), ["gone"])
    }

    func testNotebookRoundTripsAndKeepsDeviceLocalFieldsLocal() {
        let manifest = NotebookManifest(
            notebookId: "nb1", title: "notes", pageIds: ["p1", "p2"], openPageId: "p2",
            parentFolderId: "f1", createdAt: stamp(0), updatedAt: stamp(5),
            serverTimestamp: stamp(5),
            deletedPageIds: [CouchTombstone(id: "p0", deletedAt: stamp(2))], updatedBy: "ipad")

        let document = CouchMapping.couchNotebook(from: manifest, deviceID: "ipad")
        XCTAssertEqual(document.pageIds, ["p1", "p2"])
        XCTAssertEqual(document.deletedPageIds.map(\.id), ["p0"])

        let restored = CouchMapping.manifest(from: document, id: "nb1", existing: manifest)
        XCTAssertEqual(restored, manifest)

        // Arriving fresh on a device that never opened it, openPageId stays unset rather than
        // adopting the other device's cursor.
        let onNewDevice = CouchMapping.manifest(from: document, id: "nb1", existing: nil)
        XCTAssertNil(onNewDevice.openPageId)
    }

    func testFolderRoundTrips() {
        let dto = FolderDTO(
            id: "f1", title: "study", parentFolderId: nil,
            createdAt: stamp(0), updatedAt: stamp(1))
        let restored = CouchMapping.folderDTO(
            from: CouchMapping.couchFolder(from: dto, deviceID: "ipad"), id: "f1")
        XCTAssertEqual(restored, dto)
    }

    /// Files written before CouchDB sync existed carry neither tombstones nor `updatedBy`.
    func testOlderPageFilesStillDecode() throws {
        let json = """
        {"version":1,"id":"p1","notebookId":"nb1","background":"blank","backgroundType":"native",
         "parentFolderId":null,"scroll":0,"createdAt":"\(stamp(0))","updatedAt":"\(stamp(1))",
         "strokes":[],"images":[]}
        """
        let page = try JSONDecoder().decode(PageFile.self, from: Data(json.utf8))
        XCTAssertTrue(page.deletedStrokes.isEmpty)
        XCTAssertEqual(page.updatedBy, "")

        // The device id fills in when such a file is first pushed.
        let document = couchPage(from: page)
        XCTAssertEqual(document.updatedBy, "ipad")
    }
}
