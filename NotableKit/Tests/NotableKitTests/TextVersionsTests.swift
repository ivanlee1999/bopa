import Foundation
import Testing
@testable import NotableKit

@Suite("Text version integrity")
struct TextVersionsTests {
    private func block(_ text: String?, at clock: Int, device: String = "boox", positioned: Bool = false) -> CouchBlock {
        CouchBlock(id: "paragraph", kind: "md", orderKey: "a", text: text,
            x: positioned ? 10 : nil, y: positioned ? 20 : nil,
            createdAt: "2026-11-12T10:00:00Z", updatedAt: "2026-11-12T10:00:0\(clock)Z", deviceId: device)
    }

    private func page(_ blocks: [CouchBlock], removed: [String] = []) -> CouchPage {
        CouchPage(notebookId: "book", blocks: blocks,
            deletedBlocks: removed.map { CouchTombstone(id: $0, deletedAt: "2026-11-12T10:00:09Z") },
            createdAt: "2026-11-12T10:00:00Z", updatedAt: "2026-11-12T10:00:09Z", updatedBy: "boox")
    }

    private func bytes(_ page: CouchPage) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(page)
    }

    @Test func exactSourceAndGuard() {
        #expect(TextVersions.fingerprint("hello") == "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
        #expect(!TextVersions.sameSource("caf\u{e9}", "cafe\u{301}"))
        #expect(TextVersions.conflicts(baseText: "base", currentText: "remote", draftText: "mine"))
        #expect(!TextVersions.conflicts(baseText: "base", currentText: "base", draftText: "mine"))
        #expect(!TextVersions.conflicts(baseText: "base", currentText: "mine", draftText: "mine"))
        let id = TextVersions.versionID(sourceID: "source:with:colons", text: "hello")
        #expect(TextVersions.sourceID(id) == "source:with:colons")
        #expect(TextVersions.sourceID("text-version:missing:hash") == nil)
    }

    @Test func unchangedMergesDoNotCreateHistory() {
        let one = block("source", at: 1)
        let two = block("source", at: 2)
        #expect(CouchMerge.merge(page([one]), page([two])).blocks == [two])
    }

    @Test func nilAndEmptySourceHaveAnArgumentIndependentWinner() throws {
        let absent = page([block(nil, at: 1)])
        let empty = page([block("", at: 1)])
        let forward = CouchMerge.merge(absent, empty)
        let backward = CouchMerge.merge(empty, absent)
        #expect(try bytes(forward) == bytes(backward))
        #expect(forward.blocks.first { $0.kind == "md" }?.text == "")
    }

    @Test func equalHistoryCannotHideAUnicodeSourceWinnerFromSyncEquality() throws {
        let composed = block("caf\u{e9}", at: 1)
        let decomposed = block("cafe\u{301}", at: 1)
        #expect(composed != decomposed)
        let history = [TextVersions.recovery(composed), TextVersions.recovery(decomposed)]
        let a = CouchMerge.merge(page([composed] + history), page([]))
        let b = CouchMerge.merge(page([decomposed] + history), page([]))
        let merged = CouchMerge.merge(a, b)
        #expect(merged == a)
        #expect(merged != b)
        #expect(try bytes(merged) != bytes(b))
        var differentOrder = composed
        differentOrder.orderKey = "\u{e9}"
        var decomposedOrder = differentOrder
        decomposedOrder.orderKey = "e\u{301}"
        #expect(differentOrder != decomposedOrder)
    }

    @Test func divergentSourcesRemainExactAndHidden() {
        let a = block("caf\u{e9}\n\nA", at: 1)
        let b = block("cafe\u{301}\n\nB", at: 2, device: "ipad")
        let result = CouchMerge.merge(page([a]), page([b]))
        #expect(result.blocks.filter { $0.kind == "md" } == [b])
        let versions = result.blocks.filter { $0.kind == TextVersions.kind }
        #expect(Set(versions.compactMap(\.text).map(TextVersions.fingerprint)) == Set([a.text!, b.text!].map(TextVersions.fingerprint)))
        #expect(versions.allSatisfy { TextVersions.sourceID($0.id) == a.id })
    }

    @Test func deletionAndVersionTombstoneAreGroupingIndependent() throws {
        let a = page([block("one", at: 1)])
        let b = page([block("two", at: 2)])
        let removedVersion = TextVersions.versionID(sourceID: "paragraph", text: "one")
        let deletion = page([], removed: ["paragraph", removedVersion])
        let left = CouchMerge.merge(CouchMerge.merge(a, b), deletion)
        let right = CouchMerge.merge(a, CouchMerge.merge(b, deletion))
        #expect(try bytes(left) == bytes(right))
        #expect(left.blocks.allSatisfy { $0.id != "paragraph" && $0.id != removedVersion })
        #expect(left.blocks.contains { $0.text == "two" && $0.kind == TextVersions.kind })
    }

    @Test func sameTextLaterMetadataAndSurfaceConversionKeepClosure() throws {
        let a = page([block("one", at: 1)])
        let b = page([block("two", at: 2)])
        let c = page([block("one", at: 3)])
        let d = page([block("one", at: 4, positioned: true)])
        let left = CouchMerge.merge(CouchMerge.merge(CouchMerge.merge(a, b), c), d)
        let right = CouchMerge.merge(a, CouchMerge.merge(b, CouchMerge.merge(c, d)))
        #expect(try bytes(left) == bytes(right))
        let surfaceA = page([block("same", at: 1)])
        let surfaceB = page([block("same", at: 2, positioned: true)])
        let surfaceC = page([block("other", at: 3, positioned: true)])
        #expect(try bytes(CouchMerge.merge(CouchMerge.merge(surfaceA, surfaceB), surfaceC)) == bytes(CouchMerge.merge(surfaceA, CouchMerge.merge(surfaceB, surfaceC))))
    }

    @Test func mergeAlgebraAcrossRandomTriplesAndQuadruples() throws {
        struct Random {
            var value: UInt64 = 0x5eed
            mutating func next(_ upper: Int) -> Int {
                value = value &* 6364136223846793005 &+ 1442695040888963407
                return Int((value >> 32) % UInt64(upper))
            }
        }
        var random = Random()
        let sources: [String?] = [nil, "", "one", "two", "caf\u{e9}", "cafe\u{301}", "\nA|B\n"]
        enum Failed: Error { case algebra }
        for iteration in 0..<1_000 {
            var inputs: [CouchPage] = []
            for _ in 0..<4 {
                var candidate = block(sources[random.next(sources.count)], at: random.next(5), device: random.next(2) == 0 ? "boox" : "ipad", positioned: random.next(4) == 0)
                candidate.orderKey = ["a", "b", "\u{e9}"][random.next(3)]
                if random.next(8) == 0 { candidate.kind = "future-kind" }
                var removed: [String] = []
                if random.next(5) == 0 { removed.append(candidate.id) }
                if random.next(5) == 0 { removed.append(TextVersions.versionID(sourceID: candidate.id, text: sources[random.next(sources.count)] ?? "")) }
                inputs.append(page(random.next(5) == 0 ? [] : [candidate], removed: removed))
            }
            let (a,b,c,d) = (inputs[0],inputs[1],inputs[2],inputs[3])
            let ab = CouchMerge.merge(a,b)
            #expect(try bytes(ab) == bytes(CouchMerge.merge(b,a)))
            #expect(try bytes(ab) == bytes(CouchMerge.merge(ab,a)))
            let tripleLeft = try bytes(CouchMerge.merge(ab,c))
            let tripleRight = try bytes(CouchMerge.merge(a,CouchMerge.merge(b,c)))
            if tripleLeft != tripleRight {
                print("Algebra failure at \(iteration): \(String(data:try bytes(a),encoding:.utf8)!)\n\(String(data:try bytes(b),encoding:.utf8)!)\n\(String(data:try bytes(c),encoding:.utf8)!)\nLEFT \(String(data:tripleLeft,encoding:.utf8)!)\nRIGHT \(String(data:tripleRight,encoding:.utf8)!)")
                throw Failed.algebra
            }
            let canonical = try bytes(CouchMerge.merge(CouchMerge.merge(ab,c),d))
            #expect(canonical == (try bytes(CouchMerge.merge(ab,CouchMerge.merge(c,d)))))
            #expect(canonical == (try bytes(CouchMerge.merge(a,CouchMerge.merge(b,CouchMerge.merge(c,d))))))
            #expect(canonical == (try bytes(CouchMerge.merge(a,CouchMerge.merge(CouchMerge.merge(b,c),d)))))
            #expect(canonical == (try bytes(CouchMerge.merge(CouchMerge.merge(a,CouchMerge.merge(b,c)),d))))
            let result = CouchMerge.merge(CouchMerge.merge(ab,c),d)
            let removed = Set(inputs.flatMap(\.deletedBlocks).map(\.id))
            let expectedSources = Set(inputs.flatMap(\.blocks).filter { block in
                block.kind == "md" && block.text != nil && !removed.contains(TextVersions.versionID(sourceID: block.id, text: block.text!))
            }.compactMap(\.text).map(TextVersions.fingerprint))
            let preserved = Set(result.blocks.filter { $0.kind == "md" || $0.kind == TextVersions.kind }.compactMap(\.text).map(TextVersions.fingerprint))
            #expect(expectedSources.isSubset(of: preserved))
        }
    }
}
