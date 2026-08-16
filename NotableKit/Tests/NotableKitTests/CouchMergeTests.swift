import XCTest
@testable import NotableKit

/// Drives `docs/couch-sync-vectors/vectors.json` — the same file notable's `MergeTest` runs.
/// A merge-rule change that lands in only one app fails here.
final class CouchMergeVectorTests: XCTestCase {

    private struct VectorFile: Decodable {
        var version: Int
        var vectors: [Vector]
    }

    private struct Vector: Decodable {
        var name: String
        var kind: String
        var why: String?
        // Merge vectors take two documents; a `split` vector takes one page and a sheet, so these
        // are absent there rather than optional in spirit.
        var a: AnyDoc?
        var b: AnyDoc?
        var expected: AnyDoc
        var page: AnyDoc?
        var sheet: Sheet?
        var now: String?
    }

    private struct Sheet: Decodable {
        var width: Int
        var height: Int
    }

    /// What a `split` vector asserts about each page the split produces: which page it is, what ink
    /// it carries and where that ink now sits.
    private struct ExpectedPage: Decodable {
        var id: String
        var strokes: [ExpectedStroke]
        var images: [ExpectedImage]
        var pageWidth: Int
        var pageHeight: Int
    }

    private struct ExpectedStroke: Decodable {
        var id: String
        var top: Float
        var bottom: Float
        var pointsData: String
    }

    private struct ExpectedImage: Decodable {
        var id: String
        var y: Int
    }

    /// Raw JSON held until `kind` says which document type to decode it as.
    private struct AnyDoc: Decodable {
        let json: Data
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let value = try container.decode(JSONValue.self)
            json = try JSONEncoder().encode(value)
        }
    }

    /// Minimal JSON tree so a vector's document can be re-encoded and decoded as a concrete type.
    private enum JSONValue: Codable {
        case null, bool(Bool), number(Double), string(String)
        case array([JSONValue]), object([String: JSONValue])

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() { self = .null }
            else if let v = try? c.decode(Bool.self) { self = .bool(v) }
            else if let v = try? c.decode(Double.self) { self = .number(v) }
            else if let v = try? c.decode(String.self) { self = .string(v) }
            else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
            else { self = .object(try c.decode([String: JSONValue].self)) }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .null: try c.encodeNil()
            case .bool(let v): try c.encode(v)
            case .number(let v):
                // Keep integers integral so `Int32`/`Int` fields decode.
                if v == v.rounded(), abs(v) < 9e15 { try c.encode(Int64(v)) } else { try c.encode(v) }
            case .string(let v): try c.encode(v)
            case .array(let v): try c.encode(v)
            case .object(let v): try c.encode(v)
            }
        }
    }

    private static var vectorsURL: URL {
        // Canonical copy lives in docs/, shared verbatim with notable. Located relative to this
        // source file so there is no second copy inside the package to drift.
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // NotableKitTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // NotableKit
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("docs/couch-sync-vectors/vectors.json")
    }

    private func loadVectors() throws -> [Vector] {
        let data = try Data(contentsOf: Self.vectorsURL)
        return try JSONDecoder().decode(VectorFile.self, from: data).vectors
    }

    func testVectorFileIsPresentAndNonEmpty() throws {
        let vectors = try loadVectors()
        XCTAssertFalse(vectors.isEmpty)
        // Every merge rule with a branch of its own should have at least one vector.
        let kinds = Set(vectors.map(\.kind))
        XCTAssertEqual(kinds, ["page", "notebook", "folder", "split"])
    }

    func testVectors() throws {
        for vector in try loadVectors() {
            switch vector.kind {
            case "page":
                try check(vector, as: CouchPage.self, merge: CouchMerge.merge)
            case "notebook":
                try check(vector, as: CouchNotebook.self, merge: CouchMerge.merge)
            case "folder":
                try check(vector, as: CouchFolder.self, merge: CouchMerge.merge)
            case "split":
                try checkSplit(vector)
            default:
                XCTFail("vector \(vector.name): unknown kind \(vector.kind)")
            }
        }
    }

    /// Asserts the four properties every vector must satisfy: the stated result, commutativity,
    /// and idempotence against both inputs.
    private func check<T: Decodable & Equatable>(
        _ vector: Vector, as type: T.Type, merge: (T, T) -> T
    ) throws {
        let decoder = JSONDecoder()
        let a = try decoder.decode(T.self, from: XCTUnwrap(vector.a).json)
        let b = try decoder.decode(T.self, from: XCTUnwrap(vector.b).json)
        let expected = try decoder.decode(T.self, from: vector.expected.json)

        XCTAssertEqual(merge(a, b), expected, "\(vector.name): merge(a,b)")
        XCTAssertEqual(merge(b, a), expected, "\(vector.name): merge(b,a) — not commutative")
        XCTAssertEqual(merge(expected, a), expected, "\(vector.name): merge(expected,a) — not idempotent")
        XCTAssertEqual(merge(expected, b), expected, "\(vector.name): merge(expected,b) — not idempotent")
    }

    /// Runs a `split` vector: divides the page and checks, page by page, that the same pages come
    /// out — with the same ids, carrying the same ink, moved to the same place.
    ///
    /// Also runs the split a second time over its own output and requires nothing to change. A
    /// split that is not idempotent files a fresh page every time a notebook is opened, and this is
    /// the cheapest place to catch it.
    private func checkSplit(_ vector: Vector) throws {
        let decoder = JSONDecoder()
        let sheetSpec = try XCTUnwrap(vector.sheet, "\(vector.name): split vector needs a sheet")
        let sheet = PageSize(width: sheetSpec.width, height: sheetSpec.height)
        let now = try XCTUnwrap(vector.now)
        let source = try decoder.decode(CouchPage.self, from: XCTUnwrap(vector.page).json)
        let sourceId = try XCTUnwrap(
            decoder.decode([String: JSONValue].self, from: XCTUnwrap(vector.page).json)["id"]
                .flatMap { if case .string(let value) = $0 { return value } else { return nil } })
        let expected = try decoder.decode([ExpectedPage].self, from: vector.expected.json)

        let produced = try PageSplit.split(
            source, id: sourceId, sheet: sheet, now: now, updatedBy: "ipad")

        XCTAssertEqual(
            produced.map(\.id), expected.map(\.id), "\(vector.name): pages produced")
        for (made, want) in zip(produced, expected) {
            XCTAssertEqual(
                made.page.strokes.map(\.id), want.strokes.map(\.id),
                "\(vector.name): strokes on \(want.id)")
            for (stroke, wantStroke) in zip(made.page.strokes, want.strokes) {
                XCTAssertEqual(
                    stroke.top, wantStroke.top, accuracy: 0.01,
                    "\(vector.name): \(stroke.id) top on \(want.id)")
                XCTAssertEqual(
                    stroke.bottom, wantStroke.bottom, accuracy: 0.01,
                    "\(vector.name): \(stroke.id) bottom on \(want.id)")
                XCTAssertEqual(
                    stroke.pointsData, wantStroke.pointsData,
                    "\(vector.name): \(stroke.id) points on \(want.id) — the ink itself moved wrong")
            }
            XCTAssertEqual(
                made.page.images.map(\.id), want.images.map(\.id),
                "\(vector.name): images on \(want.id)")
            for (image, wantImage) in zip(made.page.images, want.images) {
                XCTAssertEqual(
                    image.y, wantImage.y, "\(vector.name): \(image.id) y on \(want.id)")
            }
            XCTAssertEqual(made.page.pageWidth, want.pageWidth, "\(vector.name): \(want.id) sheet")
            XCTAssertEqual(made.page.pageHeight, want.pageHeight, "\(vector.name): \(want.id) sheet")
        }

        for (id, page) in produced {
            let again = try PageSplit.split(
                page, id: id, sheet: sheet, now: now, updatedBy: "ipad")
            XCTAssertEqual(again.count, 1, "\(vector.name): splitting \(id) again divided it further")
            XCTAssertEqual(again[0].id, id, "\(vector.name): re-splitting \(id) renamed it")
        }
    }
}

/// Properties that must hold for inputs the vector file does not enumerate.
final class CouchMergePropertyTests: XCTestCase {

    /// Deterministic pseudo-random source: a failure here has to be reproducible.
    private struct Rng {
        var state: UInt64
        mutating func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(bound))
        }
    }

    private func randomPage(_ rng: inout Rng, deviceId: String) -> CouchPage {
        let base = 1_770_000_000_000 as Int64  // fixed epoch so runs are reproducible
        func stamp(_ offsetSeconds: Int) -> String {
            NotableDate.format(Date(timeIntervalSince1970: Double(base) / 1000 + Double(offsetSeconds)))
        }
        var strokes: [CouchStroke] = []
        for _ in 0..<rng.next(6) {
            let n = rng.next(8)
            strokes.append(CouchStroke(
                id: "s\(n)", createdAt: stamp(n), updatedAt: stamp(n), deviceId: deviceId,
                pen: "BALLPEN", color: -16_777_216, size: 3,
                top: 0, bottom: 1, left: 0, right: 1, pointsData: "AAA="))
        }
        var tombs: [CouchTombstone] = []
        for _ in 0..<rng.next(4) {
            tombs.append(CouchTombstone(id: "s\(rng.next(8))", deletedAt: stamp(rng.next(30))))
        }
        // Sometimes nil: an unnamed page is the common case, and it has to survive a merge
        // against a named one without either side depending on argument order.
        let titles: [String?] = [nil, "page 0", "page 1", "page 2"]
        // Likewise sometimes undeclared: a page written before page sizes existed has to merge
        // against one that declares a sheet without the outcome depending on argument order.
        let sheets: [PageSize?] = [
            nil, PageSizePreset.a4.size, PageSizePreset.a5.size, PageSizePreset.legal.size,
        ]
        let sheet = sheets[rng.next(sheets.count)]
        return CouchPage(
            notebookId: "nb", title: titles[rng.next(titles.count)],
            background: rng.next(2) == 0 ? "blank" : "grid",
            pageWidth: sheet?.width, pageHeight: sheet?.height,
            strokes: strokes, deletedStrokes: tombs,
            createdAt: stamp(0), updatedAt: stamp(rng.next(60)), updatedBy: deviceId)
    }

    /// A notebook carrying bookmarks and an outline, both of which the merge has to reconcile
    /// without a common ancestor. Page ids are drawn from a small pool so the two sides collide
    /// often — a generator whose documents never overlap would exercise none of the interesting
    /// cases.
    private func randomNotebook(_ rng: inout Rng, deviceId: String) -> CouchNotebook {
        let base = 1_770_000_000_000 as Int64
        func stamp(_ offsetSeconds: Int) -> String {
            NotableDate.format(Date(timeIntervalSince1970: Double(base) / 1000 + Double(offsetSeconds)))
        }
        var pageIds: [String] = []
        for _ in 0..<rng.next(6) {
            let id = "p\(rng.next(8))"
            if !pageIds.contains(id) { pageIds.append(id) }
        }
        var bookmarks: [CouchBookmark] = []
        for _ in 0..<rng.next(5) {
            bookmarks.append(CouchBookmark(
                pageId: "p\(rng.next(8))", updatedAt: stamp(rng.next(60)),
                removed: rng.next(3) == 0))
        }
        var outline: [CouchOutlineEntry] = []
        for _ in 0..<rng.next(5) {
            outline.append(CouchOutlineEntry(
                id: "e\(rng.next(8))", pageId: "p\(rng.next(8))",
                title: "section \(rng.next(4))", depth: rng.next(3),
                updatedAt: stamp(rng.next(60)), removed: rng.next(4) == 0))
        }
        var tombs: [CouchTombstone] = []
        for _ in 0..<rng.next(3) {
            tombs.append(CouchTombstone(id: "p\(rng.next(8))", deletedAt: stamp(rng.next(30))))
        }
        return CouchNotebook(
            title: "book \(rng.next(3))", pageIds: pageIds, deletedPageIds: tombs,
            bookmarks: bookmarks, outline: outline,
            createdAt: stamp(0), updatedAt: stamp(rng.next(60)), updatedBy: deviceId)
    }

    /// The property the whole design rests on: two devices that were both offline reconcile to the
    /// same notebook whichever way round they merge, and re-merging changes nothing.
    func testNotebookMergeIsCommutativeAndIdempotent() {
        var rng = Rng(state: 0xB00C)
        for iteration in 0..<300 {
            let a = randomNotebook(&rng, deviceId: "ipad")
            let b = randomNotebook(&rng, deviceId: "boox")
            let ab = CouchMerge.merge(a, b)
            XCTAssertEqual(ab, CouchMerge.merge(b, a), "iteration \(iteration): not commutative")
            XCTAssertEqual(ab, CouchMerge.merge(ab, a), "iteration \(iteration): not idempotent in a")
            XCTAssertEqual(ab, CouchMerge.merge(ab, b), "iteration \(iteration): not idempotent in b")
        }
    }

    /// A bookmark must never point at a page the notebook no longer has, however many times the two
    /// sides re-merge — a starred page deleted on the other device would otherwise stay in the list
    /// as a line that does nothing when tapped.
    ///
    /// Asserted for bookmarks only. The outline cannot be filtered this way and stay idempotent —
    /// see the note in `CouchMerge.merge(_:_:)` — so a dangling outline entry is the reader's to
    /// skip, not the merge's to remove.
    func testBookmarksNeverOutliveTheirPage() {
        var rng = Rng(state: 0x0B17)
        for _ in 0..<200 {
            let a = randomNotebook(&rng, deviceId: "ipad")
            let b = randomNotebook(&rng, deviceId: "boox")
            let merged = CouchMerge.merge(a, b)
            let removed = Set(merged.deletedPageIds.map(\.id))
            XCTAssertTrue(merged.bookmarks.allSatisfy { !removed.contains($0.pageId) })
            let again = CouchMerge.merge(merged, a)
            XCTAssertTrue(again.bookmarks.allSatisfy { !removed.contains($0.pageId) })
        }
    }

    /// Outline entries carry no position field, so the only thing keeping two devices from
    /// rendering the table of contents in different orders is that the merge is deterministic.
    func testOutlineOrderIsIdenticalInBothArgumentOrders() {
        var rng = Rng(state: 0x0F17)
        for iteration in 0..<200 {
            let a = randomNotebook(&rng, deviceId: "ipad")
            let b = randomNotebook(&rng, deviceId: "boox")
            XCTAssertEqual(
                CouchMerge.merge(a, b).outline.map(\.id),
                CouchMerge.merge(b, a).outline.map(\.id),
                "iteration \(iteration): outline order depends on argument order")
        }
    }

    func testMergeIsCommutativeAndIdempotent() {
        var rng = Rng(state: 0x5EED)
        for iteration in 0..<300 {
            let a = randomPage(&rng, deviceId: "ipad")
            let b = randomPage(&rng, deviceId: "boox")
            let ab = CouchMerge.merge(a, b)
            XCTAssertEqual(ab, CouchMerge.merge(b, a), "iteration \(iteration): not commutative")
            XCTAssertEqual(ab, CouchMerge.merge(ab, a), "iteration \(iteration): not idempotent in a")
            XCTAssertEqual(ab, CouchMerge.merge(ab, b), "iteration \(iteration): not idempotent in b")
        }
    }

    /// A tombstoned stroke must never reappear, however many times the two sides re-merge —
    /// this is what makes "erase on the BOOX" stick on the iPad.
    func testErasureIsAbsorbing() {
        var rng = Rng(state: 0xC0FFEE)
        for _ in 0..<200 {
            let a = randomPage(&rng, deviceId: "ipad")
            let b = randomPage(&rng, deviceId: "boox")
            let merged = CouchMerge.merge(a, b)
            let removed = Set(merged.deletedStrokes.map(\.id))
            XCTAssertTrue(merged.strokes.allSatisfy { !removed.contains($0.id) })
            // Re-merging with the pre-erase side must not resurrect anything.
            let again = CouchMerge.merge(merged, a)
            XCTAssertTrue(again.strokes.allSatisfy { !removed.contains($0.id) })
        }
    }

    /// A page's name follows the same last-writer-wins rule as its other scalars, in both argument
    /// orders. bopa cannot set a title, but it must not lose one the BOOX set — including when the
    /// later write is what *clears* the name.
    func testLaterPageRenameWinsInEitherOrder() {
        let unnamed = CouchPage(
            notebookId: "nb", title: nil,
            createdAt: "2026-08-10T06:00:00Z", updatedAt: "2026-08-10T06:00:00Z",
            updatedBy: "boox")
        var renamed = unnamed
        renamed.title = "Shopping list"
        renamed.updatedAt = "2026-08-10T06:05:00Z"
        renamed.updatedBy = "ipad"

        XCTAssertEqual(CouchMerge.merge(unnamed, renamed).title, "Shopping list")
        XCTAssertEqual(CouchMerge.merge(renamed, unnamed).title, "Shopping list")

        var cleared = renamed
        cleared.title = nil
        cleared.updatedAt = "2026-08-10T06:10:00Z"
        cleared.updatedBy = "boox"

        XCTAssertNil(CouchMerge.merge(renamed, cleared).title)
        XCTAssertNil(CouchMerge.merge(cleared, renamed).title)
    }

    /// The tiebreak ends in `a.scalarKey >= b.scalarKey`, so any scalar the merge picks but the key
    /// omits makes both argument orders "win" and the result depend on which document came first.
    /// Two pages identical except for their name, written in the same millisecond by the same
    /// device, are the case that catches it.
    func testPagesDifferingOnlyByTitleStillMergeCommutatively() {
        let one = CouchPage(
            notebookId: "nb", title: "Groceries",
            createdAt: "2026-08-10T06:00:00Z", updatedAt: "2026-08-10T06:00:00Z",
            updatedBy: "boox")
        var other = one
        other.title = "Shopping list"

        XCTAssertEqual(CouchMerge.merge(one, other), CouchMerge.merge(other, one))
    }

    /// bopa has no UI for page names, which is exactly why this matters: a document decoded and
    /// re-encoded here must come back carrying the title, or every sync through this device would
    /// quietly erase a name the BOOX set.
    func testPageTitleSurvivesDecodeAndReEncode() throws {
        let json = Data("""
        {"type":"page","schema":1,"notebookId":"nb","title":"Shopping list",
         "background":"blank","backgroundType":"native","strokes":[],"deletedStrokes":[],
         "images":[],"deletedImages":[],"createdAt":"2026-08-10T06:00:00Z",
         "updatedAt":"2026-08-10T06:00:00Z","updatedBy":"boox"}
        """.utf8)

        let decoded = try JSONDecoder().decode(CouchPage.self, from: json)
        XCTAssertEqual(decoded.title, "Shopping list")

        let round = try JSONDecoder().decode(
            CouchPage.self, from: try JSONEncoder().encode(decoded))
        XCTAssertEqual(round.title, "Shopping list")
    }

    func testTimestampsAreComparedChronologicallyNotLexicographically() {
        // "…33.871Z" sorts before "…33Z" as a string while being later in time.
        let fractional = "2026-08-10T06:12:33.871Z"
        let whole = "2026-08-10T06:12:33Z"
        XCTAssertLessThan(fractional, whole, "precondition: the strings really do sort this way")
        XCTAssertGreaterThan(CouchMerge.millis(fractional), CouchMerge.millis(whole))
    }

    func testUnparseableTimestampLosesRatherThanCrashing() {
        XCTAssertEqual(CouchMerge.millis("not a date"), Int64.min)
        let good = CouchFolder(
            title: "good", createdAt: "2026-08-10T06:00:00Z",
            updatedAt: "2026-08-10T06:05:00Z", updatedBy: "ipad")
        let bad = CouchFolder(
            title: "bad", createdAt: "2026-08-10T06:00:00Z",
            updatedAt: "garbage", updatedBy: "boox")
        XCTAssertEqual(CouchMerge.merge(good, bad).title, "good")
        XCTAssertEqual(CouchMerge.merge(bad, good).title, "good")
    }

    func testDeletionResolution() {
        // An edit after the delete resurrects; an edit before it does not.
        XCTAssertEqual(
            CouchMerge.resolveDeletion(
                liveUpdatedAt: "2026-08-10T06:10:00Z", tombstoneDeletedAt: "2026-08-10T06:05:00Z"),
            .resurrect)
        XCTAssertEqual(
            CouchMerge.resolveDeletion(
                liveUpdatedAt: "2026-08-10T06:01:00Z", tombstoneDeletedAt: "2026-08-10T06:05:00Z"),
            .applyDeletion)
        // Equal instants keep the deletion: a delete that observed the edit is the later intent.
        XCTAssertEqual(
            CouchMerge.resolveDeletion(
                liveUpdatedAt: "2026-08-10T06:05:00Z", tombstoneDeletedAt: "2026-08-10T06:05:00Z"),
            .applyDeletion)
    }

    // MARK: - Page geometry

    /// The rule that keeps a notebook readable: a page's sheet describes how the ink already on it
    /// is laid out, so a peer that has not learned the field cannot un-declare it by writing last.
    /// Without this, one sync from an older BOOX build would reflow every page it touched.
    func testADeclaredSheetSurvivesAPeerThatDeclaresNone() {
        let declared = CouchPage(
            notebookId: "nb", pageWidth: 1400, pageHeight: 1980,
            createdAt: "2026-08-10T06:00:00Z", updatedAt: "2026-08-10T06:00:00Z",
            updatedBy: "ipad")
        var silent = declared
        silent.pageWidth = nil
        silent.pageHeight = nil
        // The silent writer is the *later* one, so it wins every other scalar.
        silent.updatedAt = "2026-08-10T06:05:00Z"
        silent.updatedBy = "boox"

        XCTAssertEqual(CouchMerge.merge(declared, silent).declaredPageSize, PageSizePreset.a4.size)
        XCTAssertEqual(CouchMerge.merge(silent, declared).declaredPageSize, PageSizePreset.a4.size)
    }

    /// When both sides name a sheet they are the same sheet in practice — it is fixed at creation
    /// — but if they ever differ the later write decides, like any other scalar.
    func testTwoDeclaredSheetsResolveToTheLaterWrite() {
        let a4 = CouchPage(
            notebookId: "nb", pageWidth: 1400, pageHeight: 1980,
            createdAt: "2026-08-10T06:00:00Z", updatedAt: "2026-08-10T06:00:00Z",
            updatedBy: "ipad")
        var a3 = a4
        a3.pageWidth = 1980
        a3.pageHeight = 2800
        a3.updatedAt = "2026-08-10T06:05:00Z"
        a3.updatedBy = "boox"

        XCTAssertEqual(CouchMerge.merge(a4, a3).declaredPageSize, PageSizePreset.a3.size)
        XCTAssertEqual(CouchMerge.merge(a3, a4).declaredPageSize, PageSizePreset.a3.size)
    }

    /// Same trap as the title case: a scalar the merge picks but the tiebreak key omits makes both
    /// argument orders win, and the merge stops being commutative.
    func testPagesDifferingOnlyBySheetStillMergeCommutatively() {
        let one = CouchPage(
            notebookId: "nb", pageWidth: 1400, pageHeight: 1980,
            createdAt: "2026-08-10T06:00:00Z", updatedAt: "2026-08-10T06:00:00Z",
            updatedBy: "boox")
        var other = one
        other.pageWidth = 1439
        other.pageHeight = 1863

        XCTAssertEqual(CouchMerge.merge(one, other), CouchMerge.merge(other, one))
    }

    func testNotebooksDifferingOnlyByDefaultSheetStillMergeCommutatively() {
        let one = CouchNotebook(
            title: "Book", defaultPageWidth: 1400, defaultPageHeight: 1980,
            createdAt: "2026-08-10T06:00:00Z", updatedAt: "2026-08-10T06:00:00Z",
            updatedBy: "boox")
        var other = one
        other.defaultPageWidth = 1980
        other.defaultPageHeight = 2800

        XCTAssertEqual(CouchMerge.merge(one, other), CouchMerge.merge(other, one))
    }

    func testANotebookDefaultSurvivesAPeerThatDeclaresNone() {
        let declared = CouchNotebook(
            title: "Book", defaultPageWidth: 1400, defaultPageHeight: 1980,
            createdAt: "2026-08-10T06:00:00Z", updatedAt: "2026-08-10T06:00:00Z",
            updatedBy: "ipad")
        var silent = declared
        silent.defaultPageWidth = nil
        silent.defaultPageHeight = nil
        silent.updatedAt = "2026-08-10T06:05:00Z"
        silent.updatedBy = "boox"

        XCTAssertEqual(
            CouchMerge.merge(declared, silent).declaredDefaultPageSize, PageSizePreset.a4.size)
        XCTAssertEqual(
            CouchMerge.merge(silent, declared).declaredDefaultPageSize, PageSizePreset.a4.size)
    }
}