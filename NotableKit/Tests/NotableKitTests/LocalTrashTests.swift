import XCTest

@testable import NotableKit

/// The Trash file, and specifically the one thing it has to remember besides *what* is in it:
/// whether the peer was ever told.
///
/// Trashing used to be local bookkeeping — the file was written and nothing was published — so an
/// item thrown away on this device stayed in the other's library. Telling those entries apart from
/// the ones written since is what lets the fix rescue them exactly once, so the distinction has to
/// survive a decode of a file written before the flag existed.
final class LocalTrashTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bopa-local-trash-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    /// A file from before the flag has no opinion about whether it was published, and "no opinion"
    /// has to read as "nobody knows" rather than as "yes" — the entries are precisely the stranded
    /// ones. A `Bool` defaulting to false would work here and lie everywhere else.
    func testAnEntryWrittenBeforeTheFlagReadsAsUnpublished() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let json = """
            {"notebooks":[{"id":"n1","deletedAt":"2026-01-01T00:00:00.000Z"}],
             "folders":[{"id":"f1","deletedAt":"2026-01-01T00:00:00.000Z"}]}
            """
        try Data(json.utf8).write(to: LocalTrash.fileURL(root: root))

        let stranded = LocalTrash.unpublished(root: root)

        XCTAssertEqual(stranded.notebookIDs, ["n1"])
        XCTAssertEqual(stranded.folderIDs, ["f1"])
    }

    /// Anything this build stages is published by the same call that stages it, so it must never
    /// come back as owing a republish.
    func testAnEntryStagedNowIsAlreadyPublished() throws {
        try LocalTrash.addNotebook("n1", at: Date(), root: root)
        try LocalTrash.addFolder("f1", at: Date(), root: root)

        let stranded = LocalTrash.unpublished(root: root)

        XCTAssertEqual(stranded.notebookIDs, [])
        XCTAssertEqual(stranded.folderIDs, [])
    }

    /// A trashing that arrived from the peer is by definition already known to it.
    func testATrashingReceivedFromThePeerOwesNoRepublish() throws {
        try LocalTrash.setNotebook("n1", deletedAt: "2026-01-01T00:00:00.000Z", root: root)

        XCTAssertEqual(LocalTrash.unpublished(root: root).notebookIDs, [])
    }

    /// Marking is what makes the republish once-only, and it must not disturb the stamp it is
    /// recording against — `deletedAt` is the value §5.5 compares.
    func testMarkingPublishedSettlesTheEntryWithoutMovingItsStamp() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let json = """
            {"notebooks":[{"id":"n1","deletedAt":"2026-01-01T00:00:00.000Z"},
                          {"id":"n2","deletedAt":"2026-01-02T00:00:00.000Z"}],"folders":[]}
            """
        try Data(json.utf8).write(to: LocalTrash.fileURL(root: root))

        try LocalTrash.markPublished(notebookIDs: ["n1"], folderIDs: [], root: root)

        XCTAssertEqual(
            LocalTrash.unpublished(root: root).notebookIDs, ["n2"],
            "only the ids named are settled — a write that failed must be retried next launch")
        let contents = LocalTrash.load(root: root)
        XCTAssertEqual(
            contents.notebooks.first { $0.id == "n1" }?.deletedAt, "2026-01-01T00:00:00.000Z")
        XCTAssertTrue(contents.notebookIDs.contains("n1"), "settling is not restoring")
    }
}
