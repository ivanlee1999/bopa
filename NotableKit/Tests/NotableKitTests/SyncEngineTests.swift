import XCTest
@testable import NotableKit

final class SyncEngineTests: XCTestCase {
    private var server: MockWebDAVServer!
    private var rootURL: URL!

    override func setUp() {
        super.setUp()
        server = MockWebDAVServer()
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("bopa-sync-test-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: rootURL)
        super.tearDown()
    }

    private func engine() -> SyncEngine {
        SyncEngine(transport: server, rootURL: rootURL)
    }

    // MARK: Fixtures

    @discardableResult
    private func writeLocalNotebook(
        id: String, title: String = "Nb", pageIds: [String], updatedAt: String
    ) throws -> NotebookManifest {
        let manifest = NotebookManifest(
            notebookId: id, title: title, pageIds: pageIds,
            createdAt: "2026-08-01T00:00:00Z", updatedAt: updatedAt,
            serverTimestamp: updatedAt)
        let dir = rootURL.appendingPathComponent("notebooks/\(id)/pages")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONEncoder().encode(manifest)
            .write(to: rootURL.appendingPathComponent("notebooks/\(id)/manifest.json"))
        for pageId in pageIds {
            let page = PageFile(
                id: pageId, notebookId: id,
                createdAt: "2026-08-01T00:00:00Z", updatedAt: updatedAt)
            try JSONEncoder().encode(page)
                .write(to: dir.appendingPathComponent("\(pageId).json"))
        }
        return manifest
    }

    private func seedRemoteNotebook(id: String, title: String = "Remote", pageIds: [String], updatedAt: String) throws {
        let manifest = NotebookManifest(
            notebookId: id, title: title, pageIds: pageIds,
            createdAt: "2026-08-01T00:00:00Z", updatedAt: updatedAt,
            serverTimestamp: updatedAt)
        for pageId in pageIds {
            let page = PageFile(
                id: pageId, notebookId: id,
                createdAt: "2026-08-01T00:00:00Z", updatedAt: updatedAt)
            server.setFile("/notable/notebooks/\(id)/pages/\(pageId).json", try JSONEncoder().encode(page))
        }
        server.setFile("/notable/notebooks/\(id)/manifest.json", try JSONEncoder().encode(manifest))
    }

    private func localManifest(_ id: String) throws -> NotebookManifest {
        let data = try Data(contentsOf: rootURL.appendingPathComponent("notebooks/\(id)/manifest.json"))
        return try JSONDecoder().decode(NotebookManifest.self, from: data)
    }

    // MARK: Scenarios

    func testInitialUploadOfLocalNotebook() async throws {
        try writeLocalNotebook(id: "nb1", pageIds: ["p1", "p2"], updatedAt: "2026-08-02T10:00:00Z")

        let report = await engine().sync()

        XCTAssertEqual(report.uploaded, ["nb1"])
        XCTAssertTrue(report.errors.isEmpty)
        XCTAssertNotNil(server.fileData("/notable/notebooks/nb1/manifest.json"))
        XCTAssertNotNil(server.fileData("/notable/notebooks/nb1/pages/p1.json"))
        XCTAssertNotNil(server.fileData("/notable/notebooks/nb1/pages/p2.json"))
    }

    func testDownloadOfNewRemoteNotebook() async throws {
        try seedRemoteNotebook(id: "nb2", pageIds: ["pa"], updatedAt: "2026-08-02T11:00:00Z")

        let report = await engine().sync()

        XCTAssertEqual(report.downloaded, ["nb2"])
        let manifest = try localManifest("nb2")
        XCTAssertEqual(manifest.title, "Remote")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: rootURL.appendingPathComponent("notebooks/nb2/pages/pa.json").path))
    }

    func testSecondSyncIsAllSkips() async throws {
        try writeLocalNotebook(id: "nb1", pageIds: ["p1"], updatedAt: "2026-08-02T10:00:00Z")
        _ = await engine().sync()

        let report = await engine().sync()

        XCTAssertEqual(report.uploaded, [])
        XCTAssertEqual(report.downloaded, [])
        XCTAssertEqual(report.skipped, ["nb1"])
    }

    func testLocalEditUploadsOnNextSync() async throws {
        try writeLocalNotebook(id: "nb1", pageIds: ["p1"], updatedAt: "2026-08-02T10:00:00Z")
        _ = await engine().sync()

        try writeLocalNotebook(id: "nb1", pageIds: ["p1"], updatedAt: "2026-08-02T10:05:00Z")
        let report = await engine().sync()

        XCTAssertEqual(report.uploaded, ["nb1"])
        let remote = try JSONDecoder().decode(
            NotebookManifest.self,
            from: XCTUnwrap(server.fileData("/notable/notebooks/nb1/manifest.json")))
        XCTAssertEqual(remote.updatedAt, "2026-08-02T10:05:00Z")
    }

    func testRemoteEditDownloadsOnNextSync() async throws {
        try writeLocalNotebook(id: "nb1", pageIds: ["p1"], updatedAt: "2026-08-02T10:00:00Z")
        _ = await engine().sync()

        try seedRemoteNotebook(
            id: "nb1", title: "Edited on BOOX", pageIds: ["p1", "p9"],
            updatedAt: "2026-08-02T10:30:00Z")
        let report = await engine().sync()

        XCTAssertEqual(report.downloaded, ["nb1"])
        let manifest = try localManifest("nb1")
        XCTAssertEqual(manifest.title, "Edited on BOOX")
        XCTAssertEqual(manifest.pageIds, ["p1", "p9"])
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: rootURL.appendingPathComponent("notebooks/nb1/pages/p9.json").path))
    }

    // MARK: Divergence

    /// **The test this whole feature exists for.** Both sides edited the same notebook. Whichever
    /// clock is newer, neither copy may be touched: the run reports a conflict and leaves the
    /// local file and the server file exactly as they were.
    func testBothSidesChangedMovesNothingAndReportsAConflict() async throws {
        try writeLocalNotebook(id: "nb1", pageIds: ["p1"], updatedAt: "2026-08-02T10:00:00Z")
        _ = await engine().sync()

        try seedRemoteNotebook(
            id: "nb1", title: "Remote change", pageIds: ["p1"], updatedAt: "2026-08-02T10:10:00Z")
        try writeLocalNotebook(
            id: "nb1", title: "Local change", pageIds: ["p1"], updatedAt: "2026-08-02T10:20:00Z")
        let remoteBefore = try XCTUnwrap(server.fileData("/notable/notebooks/nb1/manifest.json"))

        let report = await engine().sync()

        XCTAssertEqual(report.conflicts.map(\.notebookId), ["nb1"])
        XCTAssertTrue(report.uploaded.isEmpty, "uploaded during a conflict")
        XCTAssertTrue(report.downloaded.isEmpty, "downloaded during a conflict")
        XCTAssertEqual(try localManifest("nb1").title, "Local change", "local copy was modified")
        XCTAssertEqual(
            server.fileData("/notable/notebooks/nb1/manifest.json"), remoteBefore,
            "server copy was modified")
    }

    /// Local newer, remote newer — the direction must not change the answer. Before this, one of
    /// these silently uploaded and the other silently downloaded.
    func testBothSidesChangedConflictsRegardlessOfWhichIsNewer() async throws {
        try writeLocalNotebook(id: "nb1", pageIds: ["p1"], updatedAt: "2026-08-02T10:00:00Z")
        _ = await engine().sync()

        try writeLocalNotebook(
            id: "nb1", title: "Local change", pageIds: ["p1"], updatedAt: "2026-08-02T10:10:00Z")
        try seedRemoteNotebook(
            id: "nb1", title: "Remote change", pageIds: ["p1"], updatedAt: "2026-08-02T10:20:00Z")

        let report = await engine().sync()

        XCTAssertEqual(report.conflicts.map(\.notebookId), ["nb1"])
        XCTAssertEqual(try localManifest("nb1").title, "Local change")
    }

    /// A conflict is re-reported until it is settled — the flag is derived, never persisted.
    func testConflictIsReportedAgainOnTheNextRun() async throws {
        try writeLocalNotebook(id: "nb1", pageIds: ["p1"], updatedAt: "2026-08-02T10:00:00Z")
        _ = await engine().sync()
        try seedRemoteNotebook(
            id: "nb1", title: "Remote", pageIds: ["p1"], updatedAt: "2026-08-02T10:10:00Z")
        try writeLocalNotebook(
            id: "nb1", title: "Local", pageIds: ["p1"], updatedAt: "2026-08-02T10:20:00Z")

        _ = await engine().sync()
        let second = await engine().sync()

        XCTAssertEqual(second.conflicts.map(\.notebookId), ["nb1"])
    }

    /// Different pages edited on each side is the everyday case for one person on two devices.
    /// It is not a conflict and must merge with no prompt.
    func testIndependentPageEditsMergeWithoutAConflict() async throws {
        try writeLocalNotebook(id: "nb1", pageIds: ["p1", "p2"], updatedAt: "2026-08-02T10:00:00Z")
        _ = await engine().sync()

        // The BOOX rewrites p2 only; we rewrite p1 only. Manifest structure is untouched.
        try seedRemotePage(notebook: "nb1", pageId: "p2", updatedAt: "2026-08-02T10:10:00Z")
        try bumpRemoteManifestClock("nb1", to: "2026-08-02T10:10:00Z")
        try writeLocalPage(notebook: "nb1", pageId: "p1", updatedAt: "2026-08-02T10:20:00Z")
        try bumpLocalManifestClock("nb1", to: "2026-08-02T10:20:00Z")

        let report = await engine().sync()

        XCTAssertTrue(report.conflicts.isEmpty, "independent pages should not conflict")
        XCTAssertEqual(report.merged, ["nb1"])
        // p2 came down, p1 went up.
        XCTAssertEqual(try localPageUpdatedAt("nb1", "p2"), "2026-08-02T10:10:00Z")
        let uploaded = try JSONDecoder().decode(
            PageFile.self,
            from: XCTUnwrap(server.fileData("/notable/notebooks/nb1/pages/p1.json")))
        XCTAssertEqual(uploaded.updatedAt, "2026-08-02T10:20:00Z")
    }

    /// A server that does not return ETags cannot tell us a page moved, so it must never make us
    /// invent a conflict — matching Notable.
    func testPageWithNoSyncRowIsNotAConflict() async throws {
        // Never synced: no page rows exist, so nothing can be called changed on both sides.
        try writeLocalNotebook(id: "nb1", pageIds: ["p1"], updatedAt: "2026-08-02T10:20:00Z")
        try seedRemoteNotebook(
            id: "nb1", title: "Nb", pageIds: ["p1"], updatedAt: "2026-08-02T10:10:00Z")

        let report = await engine().sync()

        XCTAssertTrue(report.conflicts.first?.pageIds.isEmpty ?? true)
    }

    /// The BOOX re-publishing a page whose content it did not change — Notable rewrites page files
    /// when a notebook is merely opened, and a byte-identical PUT still rotates the ETag — must not
    /// turn the next local edit into a conflict for the user to settle. An ETag is evidence that
    /// the file was written, not that its content moved.
    func testRemotePageRepublishedUnchangedIsNotAConflict() async throws {
        try writeLocalNotebook(id: "nb1", pageIds: ["p1"], updatedAt: "2026-08-02T10:00:00Z")
        _ = await engine().sync()

        // Same bytes back on the server for both files; only the ETags move.
        let page = try XCTUnwrap(server.fileData("/notable/notebooks/nb1/pages/p1.json"))
        server.setFile("/notable/notebooks/nb1/pages/p1.json", page)
        let manifest = try XCTUnwrap(server.fileData("/notable/notebooks/nb1/manifest.json"))
        server.setFile("/notable/notebooks/nb1/manifest.json", manifest)

        // Then the user erases a stroke on p1 here.
        try writeLocalPage(notebook: "nb1", pageId: "p1", updatedAt: "2026-08-02T10:20:00Z")
        try bumpLocalManifestClock("nb1", to: "2026-08-02T10:20:00Z")

        let report = await engine().sync()

        XCTAssertTrue(
            report.conflicts.isEmpty,
            "a byte-identical remote rewrite is not a change to reconcile")
        let uploaded = try JSONDecoder().decode(
            PageFile.self,
            from: XCTUnwrap(server.fileData("/notable/notebooks/nb1/pages/p1.json")))
        XCTAssertEqual(uploaded.updatedAt, "2026-08-02T10:20:00Z", "the local edit did not go up")
    }

    /// The same page really changed on both sides — still a conflict. The content check must only
    /// discount rewrites that carry identical bytes.
    func testRemotePageWithDifferentContentStillConflicts() async throws {
        try writeLocalNotebook(id: "nb1", pageIds: ["p1"], updatedAt: "2026-08-02T10:00:00Z")
        _ = await engine().sync()

        try seedRemotePage(notebook: "nb1", pageId: "p1", updatedAt: "2026-08-02T10:10:00Z")
        try bumpRemoteManifestClock("nb1", to: "2026-08-02T10:10:00Z")
        try writeLocalPage(notebook: "nb1", pageId: "p1", updatedAt: "2026-08-02T10:20:00Z")
        try bumpLocalManifestClock("nb1", to: "2026-08-02T10:20:00Z")

        let report = await engine().sync()

        XCTAssertEqual(report.conflicts.map(\.pageIds), [["p1"]])
    }

    /// Once a rewrite has been shown to carry the same content, its ETag is adopted — otherwise
    /// every later sync re-fetches that page to reach the same conclusion.
    func testUnchangedRewriteAdoptsTheNewEtag() async throws {
        try writeLocalNotebook(id: "nb1", pageIds: ["p1"], updatedAt: "2026-08-02T10:00:00Z")
        _ = await engine().sync()
        let page = try XCTUnwrap(server.fileData("/notable/notebooks/nb1/pages/p1.json"))
        server.setFile("/notable/notebooks/nb1/pages/p1.json", page)
        server.setFile(
            "/notable/notebooks/nb1/manifest.json",
            try XCTUnwrap(server.fileData("/notable/notebooks/nb1/manifest.json")))
        try bumpLocalManifestClock("nb1", to: "2026-08-02T10:20:00Z")
        _ = await engine().sync()

        server.clearRequestLog()
        let report = await engine().sync()

        XCTAssertEqual(report.skipped, ["nb1"])
        XCTAssertFalse(
            server.requestLog().contains {
                $0.method == "GET" && $0.path.hasSuffix("/pages/p1.json")
            },
            "re-fetched a page already proven unchanged")
    }

    /// A weak validator and its strong spelling are the same revision. Servers and proxies do not
    /// always agree on which to send, and a raw string compare reads that as a remote edit.
    func testWeakAndStrongEtagSpellingsAreTheSameRevision() {
        XCTAssertTrue(SyncEngine.sameEtag("W/\"v3\"", "\"v3\""))
        XCTAssertTrue(SyncEngine.sameEtag("\"v3\"", "v3"))
        XCTAssertFalse(SyncEngine.sameEtag("\"v3\"", "\"v4\""))
        XCTAssertFalse(SyncEngine.sameEtag(nil, nil), "two unknowns are not a match")
        XCTAssertFalse(SyncEngine.sameEtag("\"v3\"", nil))
    }

    // MARK: Resolution

    func testKeepMineUploadsOnTheNextRun() async throws {
        try await stageSamePageConflict()

        try await engine().resolveNotebook(notebookId: "nb1", resolution: .keepMine)
        let report = await engine().sync()

        XCTAssertTrue(report.conflicts.isEmpty, "still conflicted after resolving")
        XCTAssertEqual(report.uploaded, ["nb1"])
        let remote = try JSONDecoder().decode(
            NotebookManifest.self,
            from: XCTUnwrap(server.fileData("/notable/notebooks/nb1/manifest.json")))
        XCTAssertEqual(remote.title, "Local change")
    }

    /// Taking the server copy applies immediately — there is no rebaseline that reliably makes the
    /// next run choose the remote side, so this one transfers on the spot.
    func testUseRemoteReplacesTheLocalCopyAndSettles() async throws {
        try await stageSamePageConflict()

        try await engine().resolveNotebook(notebookId: "nb1", resolution: .useRemote)

        XCTAssertEqual(try localManifest("nb1").title, "Remote change")
        let report = await engine().sync()
        XCTAssertTrue(report.conflicts.isEmpty, "still conflicted after resolving")
        XCTAssertEqual(try localManifest("nb1").title, "Remote change", "the next sync undid it")
    }

    /// Sets up the canonical both-sides edit and leaves it conflicted.
    private func stageSamePageConflict() async throws {
        try writeLocalNotebook(id: "nb1", pageIds: ["p1"], updatedAt: "2026-08-02T10:00:00Z")
        _ = await engine().sync()
        try seedRemoteNotebook(
            id: "nb1", title: "Remote change", pageIds: ["p1"], updatedAt: "2026-08-02T10:10:00Z")
        try writeLocalNotebook(
            id: "nb1", title: "Local change", pageIds: ["p1"], updatedAt: "2026-08-02T10:20:00Z")
        let report = await engine().sync()
        XCTAssertEqual(report.conflicts.map(\.notebookId), ["nb1"], "fixture did not conflict")
    }

    func testRemoteTombstoneDeletesLocalNotebook() async throws {
        try writeLocalNotebook(id: "nb1", pageIds: ["p1"], updatedAt: "2026-08-02T10:00:00Z")
        _ = await engine().sync()

        server.setFile("/notable/deletions/nb1", Data())
        let report = await engine().sync()

        XCTAssertEqual(report.deletedLocally, ["nb1"])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: rootURL.appendingPathComponent("notebooks/nb1").path))
    }

    func testDeleteNotebookWritesTombstone() async throws {
        try writeLocalNotebook(id: "nb1", pageIds: ["p1"], updatedAt: "2026-08-02T10:00:00Z")
        let e = engine()
        _ = await e.sync()

        try await e.deleteNotebook("nb1")

        XCTAssertNotNil(server.fileData("/notable/deletions/nb1"))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: rootURL.appendingPathComponent("notebooks/nb1").path))
    }

    func testUploadRemovesOrphanRemotePages() async throws {
        try writeLocalNotebook(id: "nb1", pageIds: ["p1", "p2"], updatedAt: "2026-08-02T10:00:00Z")
        _ = await engine().sync()

        // Page p2 removed locally (e.g. page deleted), manifest updated.
        try? FileManager.default.removeItem(
            at: rootURL.appendingPathComponent("notebooks/nb1/pages/p2.json"))
        try writeLocalNotebook(id: "nb1", pageIds: ["p1"], updatedAt: "2026-08-02T10:10:00Z")

        let report = await engine().sync()

        XCTAssertEqual(report.uploaded, ["nb1"])
        XCTAssertNil(server.fileData("/notable/notebooks/nb1/pages/p2.json"),
                     "orphan remote page should be cleaned up")
    }

    func testPreconditionFailureIsReportedAsConflictNotError() async throws {
        try writeLocalNotebook(id: "nb1", pageIds: ["p1"], updatedAt: "2026-08-02T10:00:00Z")
        _ = await engine().sync()

        // Local changed; remote manifest silently replaced (etag rotated) AFTER our
        // conditional GET would 304 — simulate by rotating the file with same content,
        // then changing local. The If-Match from stored state no longer matches.
        let remoteData = try XCTUnwrap(server.fileData("/notable/notebooks/nb1/manifest.json"))
        server.setFile("/notable/notebooks/nb1/manifest.json", remoteData) // rotates etag, same bytes
        try writeLocalNotebook(id: "nb1", pageIds: ["p1"], updatedAt: "2026-08-02T10:20:00Z")

        let report = await engine().sync()

        // The rotated ETag makes the remote read as changed while the manifests still agree
        // structurally, so this is an independent-edit merge, not a conflict: our page goes up and
        // nothing is lost. The 412 contract itself is exercised directly below, because the engine
        // no longer has a path that produces one from an ordinary run.
        XCTAssertEqual(report.merged, ["nb1"])
        XCTAssertTrue(report.conflicts.isEmpty)

        let dav = WebDAVClient(transport: server)
        do {
            _ = try await dav.put("/notable/notebooks/nb1/manifest.json", data: Data("x".utf8), ifMatch: "\"stale\"")
            XCTFail("expected 412")
        } catch WebDAVError.preconditionFailed {
            // expected
        }
    }

    func testServerErrorSurfacesInReportWithoutCrashing() async throws {
        try writeLocalNotebook(id: "nb1", pageIds: ["p1"], updatedAt: "2026-08-02T10:00:00Z")
        _ = await engine().sync()
        try writeLocalNotebook(id: "nb1", pageIds: ["p1"], updatedAt: "2026-08-02T10:10:00Z")
        server.failingPaths = ["/notable/notebooks/nb1/pages/p1.json"]

        let report = await engine().sync()

        XCTAssertEqual(report.uploaded, [])
        XCTAssertEqual(report.errors.count, 1)
    }

    func testStatePersistsAcrossEngineInstances() async throws {
        try writeLocalNotebook(id: "nb1", pageIds: ["p1"], updatedAt: "2026-08-02T10:00:00Z")
        _ = await engine().sync()

        // New engine instance (fresh app launch) should still skip.
        let report = await engine().sync()
        XCTAssertEqual(report.skipped, ["nb1"])
    }

    func testSkipRefreshesStoredEtagSoNextSyncCanHit304() async throws {
        try writeLocalNotebook(id: "nb1", pageIds: ["p1"], updatedAt: "2026-08-02T10:00:00Z")
        _ = await engine().sync()

        // Remote manifest rewritten with the SAME updatedAt (within tolerance => .skip),
        // which rotates its ETag. The engine must adopt the new ETag.
        let remote = try XCTUnwrap(server.fileData("/notable/notebooks/nb1/manifest.json"))
        server.setFile("/notable/notebooks/nb1/manifest.json", remote)
        let skipReport = await engine().sync()
        XCTAssertEqual(skipReport.skipped, ["nb1"])

        server.clearRequestLog()
        let finalReport = await engine().sync()
        XCTAssertEqual(finalReport.skipped, ["nb1"])

        let manifestGets = server.requestLog().filter {
            $0.method == "GET" && $0.path == "/notable/notebooks/nb1/manifest.json"
        }
        XCTAssertEqual(manifestGets.count, 1)
        // A stale ETag would make this conditional GET miss and return a full 200 body.
        let currentEtag = try XCTUnwrap(server.etag(for: "/notable/notebooks/nb1/manifest.json"))
        XCTAssertEqual(manifestGets.first?.ifNoneMatch, currentEtag)
    }

    func testListReturnsOnlyDirectChildren() async throws {
        server.setFile("/notable/notebooks/nb1/manifest.json", Data("{}".utf8))
        server.setFile("/notable/notebooks/nb1/pages/p1.json", Data("{}".utf8))

        let children = try await WebDAVClient(transport: server).list("/notable/notebooks/nb1")
        let names = children.map(\.name).sorted()

        XCTAssertEqual(names, ["manifest.json", "pages"])
        XCTAssertFalse(names.contains("p1.json"), "grandchildren must not be reported as children")
    }

    func testSyncStateFileNeverUploaded() async throws {
        try writeLocalNotebook(id: "nb1", pageIds: ["p1"], updatedAt: "2026-08-02T10:00:00Z")
        _ = await engine().sync()

        XCTAssertFalse(server.filePaths().contains { $0.contains("bopa-sync-state") })
    }

    // MARK: Remote index

    private func remoteIndex() throws -> RemoteIndex {
        try XCTUnwrap(RemoteIndex.load(root: rootURL))
    }

    private func writeLocalFolders(_ folders: [FolderDTO]) throws {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let file = FoldersFile(folders: folders, serverTimestamp: "2026-08-02T10:00:00Z")
        try JSONEncoder().encode(file)
            .write(to: rootURL.appendingPathComponent("folders.json"))
    }

    private func folder(_ id: String, updatedAt: String = "2026-08-02T10:00:00Z") -> FolderDTO {
        FolderDTO(id: id, title: "F-\(id)", createdAt: "2026-08-01T00:00:00Z", updatedAt: updatedAt)
    }

    func testRemoteIndexRecordsUploadedNotebook() async throws {
        try writeLocalNotebook(id: "nb1", pageIds: ["p1"], updatedAt: "2026-08-02T10:00:00Z")

        _ = await engine().sync()

        let index = try remoteIndex()
        XCTAssertEqual(index.version, 1)
        XCTAssertTrue(index.hasNotebook("nb1"))
        XCTAssertFalse(index.syncedAt.isEmpty)
    }

    func testRemoteIndexRecordsDownloadedNotebook() async throws {
        try seedRemoteNotebook(id: "nb2", pageIds: ["pa"], updatedAt: "2026-08-02T11:00:00Z")

        _ = await engine().sync()

        XCTAssertEqual(try remoteIndex().notebookIds, ["nb2"])
    }

    func testRemoteIndexRecordsRemoteFolderIds() async throws {
        try writeLocalFolders([folder("local-only")])
        try writeLocalNotebook(id: "nb1", pageIds: ["p1"], updatedAt: "2026-08-02T10:00:00Z")

        _ = await engine().sync()

        // The merge pushed the local folder to the server, so it counts as remote now.
        XCTAssertEqual(try remoteIndex().folderIds, ["local-only"])
        XCTAssertTrue(try remoteIndex().hasFolder("local-only"))
    }

    func testRemoteIndexKeepsFoldersThatOnlyExistOnServer() async throws {
        let remote = FoldersFile(
            folders: [folder("server-folder")], serverTimestamp: "2026-08-02T10:00:00Z")
        server.setFile("/notable/folders.json", try JSONEncoder().encode(remote))

        _ = await engine().sync()

        XCTAssertEqual(try remoteIndex().folderIds, ["server-folder"])
    }

    func testRemoteIndexDropsNotebookThatDisappearedFromServer() async throws {
        try seedRemoteNotebook(id: "nb2", pageIds: ["pa"], updatedAt: "2026-08-02T11:00:00Z")
        _ = await engine().sync()
        XCTAssertTrue(try remoteIndex().hasNotebook("nb2"))

        // Server-side wipe (not a tombstone): the local copy stays but is no longer remote.
        server.removeAll(under: "/notable/notebooks/nb2")
        // Fails to re-upload, so it must not be recorded as present on the server.
        server.failingPaths = ["/notable/notebooks/nb2/manifest.json"]

        _ = await engine().sync()

        XCTAssertFalse(try remoteIndex().hasNotebook("nb2"))
    }

    func testRemoteIndexDropsFolderThatDisappearedFromServer() async throws {
        let remote = FoldersFile(
            folders: [folder("f1"), folder("f2")], serverTimestamp: "2026-08-02T10:00:00Z")
        server.setFile("/notable/folders.json", try JSONEncoder().encode(remote))
        _ = await engine().sync()
        XCTAssertEqual(try remoteIndex().folderIds, ["f1", "f2"])

        // Someone rewrote folders.json on the server without f2, and the local copy is
        // rewritten to match so the union merge does not resurrect it.
        let trimmed = FoldersFile(
            folders: [folder("f1")], serverTimestamp: "2026-08-02T12:00:00Z")
        let data = try JSONEncoder().encode(trimmed)
        server.setFile("/notable/folders.json", data)
        try data.write(to: rootURL.appendingPathComponent("folders.json"))

        _ = await engine().sync()

        XCTAssertEqual(try remoteIndex().folderIds, ["f1"])
    }

    func testRemoteIndexDropsLocallyDeletedNotebook() async throws {
        try writeLocalNotebook(id: "nb1", pageIds: ["p1"], updatedAt: "2026-08-02T10:00:00Z")
        let e = engine()
        _ = await e.sync()
        XCTAssertTrue(try remoteIndex().hasNotebook("nb1"))

        try await e.deleteNotebook("nb1")

        XCTAssertFalse(try remoteIndex().hasNotebook("nb1"))
    }

    func testRemoteIndexFileNeverUploaded() async throws {
        try writeLocalFolders([folder("f1")])
        try writeLocalNotebook(id: "nb1", pageIds: ["p1"], updatedAt: "2026-08-02T10:00:00Z")
        _ = await engine().sync()
        _ = await engine().sync()

        XCTAssertFalse(server.filePaths().contains { $0.contains("bopa-remote-index") })
        XCTAssertFalse(server.filePaths().contains { $0.contains(RemoteIndex.fileName) })
    }

    // MARK: Remote tree state

    /// A run against the wrong folder and a healthy no-op both move nothing, so without this the
    /// two are indistinguishable — which is exactly what makes a misconfigured base URL invisible.

    func testFreshServerReportsAbsentTree() async throws {
        let report = await engine().sync()

        XCTAssertEqual(report.remoteTree, .absent)
        XCTAssertTrue(report.uploaded.isEmpty)
        XCTAssertTrue(report.downloaded.isEmpty)
        XCTAssertTrue(report.errors.isEmpty)
    }

    func testSecondSyncOfStillEmptyServerReportsEmpty() async throws {
        _ = await engine().sync()
        let report = await engine().sync()

        XCTAssertEqual(report.remoteTree, .empty)
    }

    func testPopulatedServerReportsPopulated() async throws {
        try seedRemoteNotebook(id: "nb1", pageIds: ["p1"], updatedAt: "2026-08-02T10:00:00Z")
        let report = await engine().sync()

        XCTAssertEqual(report.remoteTree, .populated)
        XCTAssertEqual(report.downloaded, ["nb1"])
    }

    /// A BOOX that has only ever made folders is a working setup, not a wrong address.
    func testRemoteFoldersFileAloneCountsAsPopulated() async throws {
        _ = await engine().sync()   // create the tree so this run is not `.absent`
        server.setFile(
            NotableSyncPaths.foldersFile,
            try JSONEncoder().encode(FoldersFile(
                folders: [folder("f1")], serverTimestamp: "2026-08-02T10:00:00Z")))

        let report = await engine().sync()

        XCTAssertEqual(report.remoteTree, .populated)
    }

    func testMakeCollectionDistinguishesCreatedFromExisting() async throws {
        let dav = WebDAVClient(transport: server)

        let created = try await dav.makeCollection("/some/dir")
        let again = try await dav.makeCollection("/some/dir")

        XCTAssertTrue(created)
        XCTAssertFalse(again)
    }

    // MARK: Assets

    func testDownloadsImagesAndBackgrounds() async throws {
        try seedRemoteNotebook(id: "nb1", pageIds: ["p1"], updatedAt: "2026-08-02T10:00:00Z")
        server.setFile("/notable/notebooks/nb1/images/photo.jpg", Data("jpeg-bytes".utf8))
        server.setFile("/notable/notebooks/nb1/backgrounds/paper.pdf", Data("pdf-bytes".utf8))

        let report = await engine().sync()

        XCTAssertEqual(report.downloaded, ["nb1"])
        XCTAssertTrue(report.errors.isEmpty)
        XCTAssertEqual(
            try Data(contentsOf: localAsset("nb1", "images/photo.jpg")), Data("jpeg-bytes".utf8))
        XCTAssertEqual(
            try Data(contentsOf: localAsset("nb1", "backgrounds/paper.pdf")), Data("pdf-bytes".utf8))
    }

    func testUploadsImagesAndBackgrounds() async throws {
        try writeLocalNotebook(id: "nb1", pageIds: ["p1"], updatedAt: "2026-08-02T10:00:00Z")
        try writeLocalAsset("nb1", "images/photo.jpg", "jpeg-bytes")
        try writeLocalAsset("nb1", "backgrounds/paper.pdf", "pdf-bytes")

        let report = await engine().sync()

        XCTAssertEqual(report.uploaded, ["nb1"])
        XCTAssertTrue(report.errors.isEmpty)
        XCTAssertEqual(
            server.fileData("/notable/notebooks/nb1/images/photo.jpg"), Data("jpeg-bytes".utf8))
        XCTAssertEqual(
            server.fileData("/notable/notebooks/nb1/backgrounds/paper.pdf"), Data("pdf-bytes".utf8))
    }

    /// Assets are optional. A notebook that never had an image has no such folder, and a 404
    /// listing must read as "nothing to do" rather than an error.
    func testNotebookWithoutAssetsSyncsCleanly() async throws {
        try seedRemoteNotebook(id: "nb1", pageIds: ["p1"], updatedAt: "2026-08-02T10:00:00Z")

        let report = await engine().sync()

        XCTAssertEqual(report.downloaded, ["nb1"])
        XCTAssertTrue(report.errors.isEmpty)
    }

    /// A background that will not transfer must not cost the user their strokes.
    func testAssetFailureStillLandsTheNotebook() async throws {
        try seedRemoteNotebook(id: "nb1", pageIds: ["p1"], updatedAt: "2026-08-02T10:00:00Z")
        server.setFile("/notable/notebooks/nb1/backgrounds/paper.pdf", Data("pdf-bytes".utf8))
        server.failingPaths = ["/notable/notebooks/nb1/backgrounds/paper.pdf"]

        let report = await engine().sync()

        XCTAssertEqual(report.downloaded, ["nb1"])
        XCTAssertTrue(report.errors.contains { $0.contains("paper.pdf") }, "\(report.errors)")
        // Manifest and pages are intact, so the note opens — just without its background.
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: rootURL.appendingPathComponent("notebooks/nb1/manifest.json").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: rootURL.appendingPathComponent("notebooks/nb1/pages/p1.json").path))
    }

    /// Assets already present are left alone — they are immutable blobs keyed by name, so
    /// re-fetching them every sync would be pure waste.
    func testExistingAssetsAreNotRefetched() async throws {
        try seedRemoteNotebook(id: "nb1", pageIds: ["p1"], updatedAt: "2026-08-02T10:00:00Z")
        server.setFile("/notable/notebooks/nb1/images/photo.jpg", Data("jpeg-bytes".utf8))
        _ = await engine().sync()

        server.clearRequestLog()
        _ = await engine().sync()

        XCTAssertFalse(server.requestLog().contains {
            $0.method == "GET" && $0.path == "/notable/notebooks/nb1/images/photo.jpg"
        }, "asset re-fetched on a second sync")
    }

    // MARK: Upload-only (the open notebook)

    /// The failure this mode exists to prevent: a download landing under an open editor is
    /// reverted by the next autosave and then uploaded as the winner, so remote work vanishes
    /// from both sides. Deferring the download costs nothing — it happens on the next run.
    func testUploadOnlyNotebookIsNeverDownloadedOverEvenWhenRemoteIsNewer() async throws {
        try writeLocalNotebook(id: "nb1", pageIds: ["p1"], updatedAt: "2026-08-02T10:00:00Z")
        _ = await engine().sync()
        try seedRemoteNotebook(
            id: "nb1", title: "From BOOX", pageIds: ["p1"], updatedAt: "2026-08-09T10:00:00Z")

        let report = await engine().sync(uploadOnly: ["nb1"])

        XCTAssertFalse(report.downloaded.contains("nb1"), "downloaded over the open notebook")
        XCTAssertTrue(report.skipped.contains("nb1"))
        // Local manifest untouched: still the local title, not the remote one.
        let local = try JSONDecoder().decode(
            NotebookManifest.self,
            from: Data(contentsOf: rootURL.appendingPathComponent("notebooks/nb1/manifest.json")))
        XCTAssertEqual(local.title, "Nb")
    }

    /// Deferral must not be mistaken for "in sync", or the download would be stranded forever
    /// once the notebook is closed.
    func testDeferredDownloadHappensOnTheNextRunOnceClosed() async throws {
        try writeLocalNotebook(id: "nb1", pageIds: ["p1"], updatedAt: "2026-08-02T10:00:00Z")
        _ = await engine().sync()
        try seedRemoteNotebook(
            id: "nb1", title: "From BOOX", pageIds: ["p1"], updatedAt: "2026-08-09T10:00:00Z")
        _ = await engine().sync(uploadOnly: ["nb1"])

        let report = await engine().sync()   // editor closed

        XCTAssertEqual(report.downloaded, ["nb1"])
        let local = try JSONDecoder().decode(
            NotebookManifest.self,
            from: Data(contentsOf: rootURL.appendingPathComponent("notebooks/nb1/manifest.json")))
        XCTAssertEqual(local.title, "From BOOX")
    }

    /// The point of upload-only rather than skip-entirely: your work still reaches the server
    /// while you are writing.
    func testUploadOnlyNotebookStillUploadsLocalChanges() async throws {
        try writeLocalNotebook(id: "nb1", pageIds: ["p1"], updatedAt: "2026-08-02T10:00:00Z")

        let report = await engine().sync(uploadOnly: ["nb1"])

        XCTAssertEqual(report.uploaded, ["nb1"])
        XCTAssertNotNil(server.fileData("/notable/notebooks/nb1/manifest.json"))
    }

    /// A remote-only notebook has no local copy to protect, but materialising one under an open
    /// editor would be just as surprising — defer it too.
    func testUploadOnlyDefersARemoteOnlyNotebook() async throws {
        try seedRemoteNotebook(id: "nb1", pageIds: ["p1"], updatedAt: "2026-08-09T10:00:00Z")

        let report = await engine().sync(uploadOnly: ["nb1"])

        XCTAssertTrue(report.downloaded.isEmpty)
        XCTAssertTrue(report.skipped.contains("nb1"))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: rootURL.appendingPathComponent("notebooks/nb1/manifest.json").path))
    }

    func testUploadOnlyOnlyAffectsTheNamedNotebook() async throws {
        try seedRemoteNotebook(id: "nb1", pageIds: ["p1"], updatedAt: "2026-08-09T10:00:00Z")
        try seedRemoteNotebook(id: "nb2", pageIds: ["p1"], updatedAt: "2026-08-09T10:00:00Z")

        let report = await engine().sync(uploadOnly: ["nb1"])

        XCTAssertEqual(report.downloaded, ["nb2"])
    }

    // MARK: Divergence fixtures

    /// Rewrites one page on the server, standing in for the BOOX editing just that page.
    private func seedRemotePage(notebook: String, pageId: String, updatedAt: String) throws {
        let page = PageFile(
            id: pageId, notebookId: notebook,
            createdAt: "2026-08-01T00:00:00Z", updatedAt: updatedAt)
        server.setFile(
            "/notable/notebooks/\(notebook)/pages/\(pageId).json", try JSONEncoder().encode(page))
    }

    private func writeLocalPage(notebook: String, pageId: String, updatedAt: String) throws {
        let page = PageFile(
            id: pageId, notebookId: notebook,
            createdAt: "2026-08-01T00:00:00Z", updatedAt: updatedAt)
        try JSONEncoder().encode(page).write(
            to: rootURL.appendingPathComponent("notebooks/\(notebook)/pages/\(pageId).json"))
    }

    /// Moves a manifest clock without touching structure, so the notebook reads as changed while
    /// staying structurally identical to the other side.
    private func bumpRemoteManifestClock(_ id: String, to updatedAt: String) throws {
        var manifest = try JSONDecoder().decode(
            NotebookManifest.self,
            from: XCTUnwrap(server.fileData("/notable/notebooks/\(id)/manifest.json")))
        manifest.updatedAt = updatedAt
        server.setFile(
            "/notable/notebooks/\(id)/manifest.json", try JSONEncoder().encode(manifest))
    }

    private func bumpLocalManifestClock(_ id: String, to updatedAt: String) throws {
        let url = rootURL.appendingPathComponent("notebooks/\(id)/manifest.json")
        var manifest = try JSONDecoder().decode(
            NotebookManifest.self, from: Data(contentsOf: url))
        manifest.updatedAt = updatedAt
        try JSONEncoder().encode(manifest).write(to: url)
    }

    private func localPageUpdatedAt(_ id: String, _ pageId: String) throws -> String {
        let data = try Data(
            contentsOf: rootURL.appendingPathComponent("notebooks/\(id)/pages/\(pageId).json"))
        return try JSONDecoder().decode(PageFile.self, from: data).updatedAt
    }

    private func localAsset(_ id: String, _ relative: String) -> URL {
        rootURL.appendingPathComponent("notebooks/\(id)/\(relative)")
    }

    private func writeLocalAsset(_ id: String, _ relative: String, _ contents: String) throws {
        let url = localAsset(id, relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }
}
