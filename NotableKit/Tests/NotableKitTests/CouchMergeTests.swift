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
        var a: AnyDoc
        var b: AnyDoc
        var expected: AnyDoc
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
        XCTAssertEqual(kinds, ["page", "notebook", "folder"])
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
        let a = try decoder.decode(T.self, from: vector.a.json)
        let b = try decoder.decode(T.self, from: vector.b.json)
        let expected = try decoder.decode(T.self, from: vector.expected.json)

        XCTAssertEqual(merge(a, b), expected, "\(vector.name): merge(a,b)")
        XCTAssertEqual(merge(b, a), expected, "\(vector.name): merge(b,a) — not commutative")
        XCTAssertEqual(merge(expected, a), expected, "\(vector.name): merge(expected,a) — not idempotent")
        XCTAssertEqual(merge(expected, b), expected, "\(vector.name): merge(expected,b) — not idempotent")
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
        return CouchPage(
            notebookId: "nb", title: titles[rng.next(titles.count)],
            background: rng.next(2) == 0 ? "blank" : "grid",
            strokes: strokes, deletedStrokes: tombs,
            createdAt: stamp(0), updatedAt: stamp(rng.next(60)), updatedBy: deviceId)
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
}
