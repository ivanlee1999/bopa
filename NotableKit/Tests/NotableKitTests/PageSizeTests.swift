import XCTest
@testable import NotableKit

/// The page-size contract both apps depend on. These are deliberately value-pinning tests: the
/// preset table exists twice, once here and once in Kotlin, and a dimension that drifts by one
/// unit between them puts the two apps back to laying out different pages.
final class PageSizeTests: XCTestCase {

    private let stamp = "2026-08-02T10:00:00Z"

    private func page() -> PageFile {
        PageFile(id: "p1", notebookId: "nb-1", createdAt: stamp, updatedAt: stamp)
    }

    private func manifest() -> NotebookManifest {
        NotebookManifest(
            notebookId: "nb-1", title: "Book", pageIds: ["p1"],
            createdAt: stamp, updatedAt: stamp, serverTimestamp: stamp)
    }

    // MARK: - The unit

    /// 0.15 mm per unit is what makes every other number here hold: A4 lands next to the 1404
    /// bopa used before page sizes existed, and a unit converts cleanly to a PostScript point.
    func testUnitIsATenthOfAMillimetreAndAHalf() {
        XCTAssertEqual(PageUnits.millimetresPerUnit, 0.15, accuracy: 1e-12)
        XCTAssertEqual(PageUnits.pointsPerUnit, 0.4251968, accuracy: 1e-6)
    }

    /// The reason for that unit: A4 in page units is A4 in points, so PDF and `.xopp` export
    /// need no per-notebook fudge factor.
    func testA4ConvertsToTheStandardPDFPageBox() {
        let a4 = PageSizePreset.a4.size
        XCTAssertEqual(a4.widthInPoints, 595.276, accuracy: 0.05)
        XCTAssertEqual(a4.heightInPoints, 841.89, accuracy: 0.5)
    }

    // MARK: - The preset table

    func testPresetDimensionsAreTheAgreedValues() {
        XCTAssertEqual(PageSizePreset.a3.size, PageSize(width: 1980, height: 2800))
        XCTAssertEqual(PageSizePreset.a4.size, PageSize(width: 1400, height: 1980))
        XCTAssertEqual(PageSizePreset.a5.size, PageSize(width: 987, height: 1400))
        XCTAssertEqual(PageSizePreset.letter.size, PageSize(width: 1439, height: 1863))
        XCTAssertEqual(PageSizePreset.legal.size, PageSize(width: 1439, height: 2371))
    }

    /// Each preset's units are its millimetres at 0.15 mm each. Checked rather than computed in
    /// the source, so the written-down table cannot quietly disagree with the paper it names.
    func testPresetsMatchTheirMillimetreSizes() {
        for preset in PageSizePreset.all {
            let width = preset.millimetres.width / PageUnits.millimetresPerUnit
            let height = preset.millimetres.height / PageUnits.millimetresPerUnit
            XCTAssertEqual(Double(preset.size.width), width, accuracy: 0.5, preset.name)
            XCTAssertEqual(Double(preset.size.height), height, accuracy: 0.5, preset.name)
        }
    }

    /// Portrait is the storage convention — "landscape" is a fit, not a size, so nothing here
    /// may be wider than it is tall.
    func testEveryPresetIsStoredPortrait() {
        for preset in PageSizePreset.all {
            XCTAssertLessThanOrEqual(preset.size.width, preset.size.height, preset.name)
        }
    }

    func testPresetIdsAreStableLowercaseAndUnique() {
        let ids = PageSizePreset.all.map(\.id)
        XCTAssertEqual(ids, ids.map { $0.lowercased() })
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertEqual(PageSizePreset.default.id, "a4")
    }

    func testASizeIsRecognisedByItsDimensionsAlone() {
        XCTAssertEqual(PageSizePreset.matching(PageSize(width: 1400, height: 1980)), .a4)
        XCTAssertNil(PageSizePreset.matching(PageSize(width: 1401, height: 1980)))
    }

    /// A size from a build with more presets than this one still reads as something.
    func testAnUnknownSizeIsLabelledInMillimetres() {
        XCTAssertEqual(PageSizePreset.label(for: PageSizePreset.a4.size), "A4")
        XCTAssertEqual(PageSizePreset.label(for: PageSize(width: 2000, height: 4000)), "300×600 mm")
    }

    // MARK: - Reading a size off the wire

    func testAPageThatDeclaresNoSizeFallsBackWithoutClaimingOne() {
        var page = page()
        page.pageWidth = nil
        page.pageHeight = nil

        XCTAssertNil(page.declaredPageSize)
        XCTAssertEqual(page.pageSize, .legacyUndeclared)
        XCTAssertEqual(page.pageSize, PageSize(width: 1404, height: 1872))
    }

    /// Half a declaration is not a sheet: guessing the other half from an aspect ratio is
    /// exactly how the two apps would end up laying out different pages again.
    func testHalfADeclarationIsNotASheet() {
        var page = page()
        page.pageWidth = 1400
        page.pageHeight = nil
        XCTAssertNil(page.declaredPageSize)

        page.pageWidth = nil
        page.pageHeight = 1980
        XCTAssertNil(page.declaredPageSize)
    }

    /// A peer writing 0 for "unset" must not produce a page nothing can lay out.
    func testNonPositiveDimensionsDecodeAsNoDeclaration() throws {
        let json = """
        {"version":1,"id":"p1","notebookId":"nb-1","background":"blank",\
        "backgroundType":"native","parentFolderId":null,"scroll":0,\
        "pageWidth":0,"pageHeight":-5,\
        "createdAt":"2026-08-02T10:00:00Z","updatedAt":"2026-08-02T10:00:00Z",\
        "strokes":[],"images":[]}
        """
        let page = try JSONDecoder().decode(PageFile.self, from: Data(json.utf8))
        XCTAssertNil(page.declaredPageSize)
        XCTAssertEqual(page.pageSize, .legacyUndeclared)
    }

    func testDeclaredSizeRoundTripsThroughJSON() throws {
        var page = page()
        page.setPageSize(PageSizePreset.a3.size)

        let data = try JSONEncoder().encode(page)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains("\"pageWidth\":1980"), json)
        XCTAssertTrue(json.contains("\"pageHeight\":2800"), json)

        let decoded = try JSONDecoder().decode(PageFile.self, from: data)
        XCTAssertEqual(decoded.declaredPageSize, PageSizePreset.a3.size)
    }

    /// kotlinx.serialization needs nullable-without-default fields present, so an undeclared
    /// size travels as an explicit null rather than a missing key.
    func testAnUndeclaredSizeIsWrittenAsExplicitNull() throws {
        let page = page()
        let json = String(decoding: try JSONEncoder().encode(page), as: UTF8.self)
        XCTAssertTrue(json.contains("\"pageWidth\":null"), json)
        XCTAssertTrue(json.contains("\"pageHeight\":null"), json)
    }

    func testManifestCarriesTheDefaultForNewPages() throws {
        var manifest = manifest()
        XCTAssertNil(manifest.declaredDefaultPageSize)

        manifest.setDefaultPageSize(PageSizePreset.letter.size)
        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(NotebookManifest.self, from: data)
        XCTAssertEqual(decoded.declaredDefaultPageSize, PageSizePreset.letter.size)
    }

    // MARK: - Interop with the BOOX

    /// Verbatim output of the BOOX's own `NotebookSerializer.serializePage` for an A4 page,
    /// captured from a run of the Kotlin serializer rather than hand-written. Pinning the real
    /// bytes is the point: the two apps agree about a page only if this decodes to A4 here.
    private let booxPageJSON = """
    {"version":1,"id":"p-1","notebookId":"nb-1","background":"blank","backgroundType":"native",\
    "parentFolderId":null,"scroll":120,"pageWidth":1400,"pageHeight":1980,\
    "createdAt":"2023-11-14T22:13:20Z","updatedAt":"2023-11-14T22:13:20Z",\
    "strokes":[],"images":[]}
    """

    /// The manifest the BOOX writes alongside it.
    private let booxManifestJSON = """
    {"version":1,"notebookId":"nb-1","title":"Interop","pageIds":["p-1"],"openPageId":"p-1",\
    "parentFolderId":null,"defaultBackground":"blank","defaultBackgroundType":"native",\
    "linkedExternalUri":null,"defaultPageWidth":1400,"defaultPageHeight":1980,\
    "createdAt":"2023-11-14T22:13:20Z","updatedAt":"2023-11-14T22:13:20Z",\
    "serverTimestamp":"2026-08-12T06:16:08.774513Z"}
    """

    func testAPageWrittenByTheBooxLandsOnTheSameSheet() throws {
        let page = try JSONDecoder().decode(PageFile.self, from: Data(booxPageJSON.utf8))
        XCTAssertEqual(page.declaredPageSize, PageSizePreset.a4.size)
        XCTAssertEqual(page.pageSize, PageSize(width: 1400, height: 1980))
        XCTAssertEqual(page.scroll, 120)
    }

    func testANotebookWrittenByTheBooxCarriesItsDefaultSheet() throws {
        let manifest = try JSONDecoder()
            .decode(NotebookManifest.self, from: Data(booxManifestJSON.utf8))
        XCTAssertEqual(manifest.declaredDefaultPageSize, PageSizePreset.a4.size)
    }

    /// The other direction: the keys this app writes are the ones the BOOX reads. It parses with
    /// `ignoreUnknownKeys`, so a renamed key would be silently dropped rather than reported.
    func testWhatWeWriteUsesTheKeysTheBooxReads() throws {
        var page = page()
        page.setPageSize(PageSizePreset.a3.size)
        let json = String(decoding: try JSONEncoder().encode(page), as: UTF8.self)
        XCTAssertTrue(json.contains("\"pageWidth\":1980"), json)
        XCTAssertTrue(json.contains("\"pageHeight\":2800"), json)

        var manifest = manifest()
        manifest.setDefaultPageSize(PageSizePreset.a3.size)
        let manifestJSON = String(decoding: try JSONEncoder().encode(manifest), as: UTF8.self)
        XCTAssertTrue(manifestJSON.contains("\"defaultPageWidth\":1980"), manifestJSON)
        XCTAssertTrue(manifestJSON.contains("\"defaultPageHeight\":2800"), manifestJSON)
    }
}
