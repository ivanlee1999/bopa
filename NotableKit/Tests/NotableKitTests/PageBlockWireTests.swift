import Foundation
import Testing

@testable import NotableKit

/// Blocks survive a round trip through both wire formats, and a document written before they
/// existed still decodes.
///
/// This is the whole of the first stage: nothing creates a block yet, and the only thing that
/// matters is that a build which meets one does not quietly destroy it. Neither app keeps unknown
/// fields — notable decodes with `ignoreUnknownKeys`, this side uses plain `Codable` — so a field
/// a peer does not model is a field it erases the next time it writes the document back. That has
/// shipped as data loss once already, with page titles.
@Suite("Blocks on the wire")
struct PageBlockWireTests {
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()

    let paragraph = CouchBlock(
        id: "b1", kind: "md", orderKey: "a0",
        text: "## Groceries\n\nmilk **and** eggs",
        createdAt: "2026-09-01T10:00:00Z", updatedAt: "2026-09-01T10:00:00Z", deviceId: "ipad")

    let recording = CouchBlock(
        id: "b2", kind: "audio", orderKey: "a1",
        segments: [
            CouchAudioSegment(assetId: "asset:aa", startMs: 0, durationMs: 120_000),
            CouchAudioSegment(assetId: "asset:bb", startMs: 120_000, durationMs: 90_000),
        ],
        startedAt: "2026-09-01T10:05:00Z",
        createdAt: "2026-09-01T10:05:00Z", updatedAt: "2026-09-01T10:08:30Z", deviceId: "boox")

    private func page(_ blocks: [CouchBlock]) -> CouchPage {
        CouchPage(
            notebookId: "nb1", blocks: blocks,
            deletedBlocks: [CouchTombstone(id: "b0", deletedAt: "2026-09-01T09:00:00Z")],
            createdAt: "2026-09-01T09:00:00Z", updatedAt: "2026-09-01T10:08:30Z",
            updatedBy: "ipad")
    }

    @Test("A page document round-trips its blocks")
    func couchPageRoundTrip() throws {
        let original = page([paragraph, recording])
        let decoded = try decoder.decode(CouchPage.self, from: encoder.encode(original))
        #expect(decoded == original)
    }

    @Test("A page file round-trips its blocks — this is also the local on-disk format")
    func pageFileRoundTrip() throws {
        let original = PageFile(
            id: "p1", notebookId: "nb1",
            createdAt: "2026-09-01T09:00:00Z", updatedAt: "2026-09-01T10:08:30Z",
            blocks: [paragraph, recording],
            deletedBlocks: [CouchTombstone(id: "b0", deletedAt: "2026-09-01T09:00:00Z")])
        let decoded = try decoder.decode(PageFile.self, from: encoder.encode(original))
        #expect(decoded == original)
    }

    @Test("Blocks survive the trip through the CouchDB document and back")
    func mappingRoundTrip() throws {
        let dir = URL(fileURLWithPath: "/tmp/does-not-need-to-exist")
        let file = PageFile(
            id: "p1", notebookId: "nb1",
            createdAt: "2026-09-01T09:00:00Z", updatedAt: "2026-09-01T10:08:30Z",
            blocks: [paragraph, recording],
            deletedBlocks: [CouchTombstone(id: "b0", deletedAt: "2026-09-01T09:00:00Z")])

        let document = CouchMapping.couchPage(from: file, deviceID: "ipad", notebookDir: dir)
        #expect(document.blocks == [paragraph, recording])

        let back = CouchMapping.pageFile(
            from: document, id: "p1", existing: file, notebookDir: dir)
        #expect(back.blocks == [paragraph, recording])
        #expect(back.deletedBlocks == file.deletedBlocks)
    }

    /// Every page in both libraries today. Absent must read as empty, not as a decode failure —
    /// §6.5 would otherwise conflict-copy the entire library into "Unreadable sync copy" notebooks.
    @Test("A page written before blocks existed decodes with none")
    func absentReadsAsEmpty() throws {
        let json = """
        {"type":"page","schema":1,"notebookId":"nb1","background":"blank",\
        "backgroundType":"native","strokes":[],"deletedStrokes":[],"images":[],\
        "deletedImages":[],"createdAt":"2026-09-01T09:00:00Z",\
        "updatedAt":"2026-09-01T09:00:00Z","updatedBy":"boox"}
        """
        let decoded = try decoder.decode(CouchPage.self, from: Data(json.utf8))
        #expect(decoded.blocks.isEmpty)
        #expect(decoded.deletedBlocks.isEmpty)
    }

    /// A block whose `kind` this build has never heard of is carried through untouched, so a fifth
    /// kind can ship on one app before the other without the pages that use it being quarantined.
    @Test("An unrecognized kind is carried verbatim")
    func unknownKindSurvives() throws {
        let exotic = CouchBlock(
            id: "b9", kind: "video", orderKey: "z",
            createdAt: "2026-09-01T09:00:00Z", updatedAt: "2026-09-01T09:00:00Z")
        let decoded = try decoder.decode(CouchPage.self, from: encoder.encode(page([exotic])))
        #expect(decoded.blocks.first?.kind == "video")
    }

    @Test("Coordinates decide flowing versus positioned, and a half-declared block flows")
    func flowingVersusPositioned() {
        #expect(paragraph.isFlowing)
        var positioned = paragraph
        positioned.x = 100
        positioned.y = 200
        #expect(!positioned.isFlowing)
        var halfDeclared = paragraph
        halfDeclared.x = 100
        #expect(halfDeclared.isFlowing)
    }

    /// A recording's segments are wanted in `audio/`, a picture in `images/`. Where a device keeps
    /// bytes is not protocol, but the two apps agree on it so a library copied between them by hand
    /// still resolves.
    @Test("A block's assets each name the folder they belong in")
    func wantedAssetsNameTheirFolder() {
        #expect(recording.wantedAssets.map(\.folder) == ["audio", "audio"])

        var picture = paragraph
        picture.kind = "image"
        picture.imageAssetId = "asset:cc"
        #expect(picture.wantedAssets.map(\.folder) == ["images"])
        #expect(paragraph.wantedAssets.isEmpty)
    }

    /// A paragraph typed while a merge was in flight is kept — the twin of the surviving-strokes
    /// rule — but unlike a stroke, where last also means topmost, it has to land where its key says.
    @Test("A block kept through a merge lands in flow order, not at the end")
    func blocksKeptThroughAMergeLandInFlowOrder() {
        let dir = URL(fileURLWithPath: "/tmp/does-not-need-to-exist")
        let typedDuringTheMerge = CouchBlock(
            id: "b-mid", kind: "md", orderKey: "a0V", text: "typed while syncing",
            createdAt: "2026-09-01T10:07:00Z", updatedAt: "2026-09-01T10:07:00Z")

        let merged = page([paragraph, recording])
        let file = CouchMapping.pageFile(
            from: merged, id: "p1", existing: nil, notebookDir: dir,
            keepingBlocks: [typedDuringTheMerge])

        // a0 < a0V < a1 — between the two it was typed between, not appended after them.
        #expect(file.blocks.map(\.id) == ["b1", "b-mid", "b2"])
    }

    /// What the push ordering and the asset collector both read.
    @Test("A block reports the assets its bytes live in")
    func referencedAssets() {
        #expect(recording.referencedAssetIDs == ["asset:aa", "asset:bb"])
        #expect(paragraph.referencedAssetIDs.isEmpty)

        var picture = paragraph
        picture.kind = "image"
        picture.imageAssetId = "asset:cc"
        #expect(picture.referencedAssetIDs == ["asset:cc"])
    }
}
