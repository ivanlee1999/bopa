import XCTest
@testable import NotableKit

/// Which database this is (protocol §1.2).
///
/// Local sync state is scoped by endpoint and database name, and that pair cannot tell the original
/// database from a new one created later under the same name. A checkpoint from the old one either
/// fails against the new one or — worse — succeeds while describing history that server never had,
/// with stale revision entries suppressing genuine changes as though they were this device's own
/// echoes.
///
/// The identity document makes the difference observable. What it must *never* do is decide on its
/// own that a library should be rebuilt: every branch here either proceeds, or stops and leaves the
/// choice to a human.
final class CouchDatabaseIdentityTests: XCTestCase {

    private var server: MockCouchServer!
    private var store: FakeLocalStore!

    override func setUp() {
        super.setUp()
        server = MockCouchServer()
        store = FakeLocalStore()
    }

    private func makeEngine(
        state: CouchSyncState = CouchSyncState(),
        enforce: Bool = false,
        generation: String = "gen-a"
    ) -> CouchSyncEngine {
        CouchSyncEngine(
            client: CouchDBClient(transport: server, database: "notes"),
            store: store,
            deviceID: "ipad",
            state: state,
            enforceDatabaseIdentity: enforce,
            now: { Date(timeIntervalSince1970: 1_770_000_000) },
            newGeneration: { generation })
    }

    private func seedMetadata(
        generation: String,
        minimumClientProtocol: Int = couchProtocolVersion,
        locked: Bool = false,
        lockReason: String? = nil
    ) {
        server.seed(CouchMetaDocID.database, CouchDatabaseMetadata(
            minimumClientProtocol: minimumClientProtocol,
            generation: generation,
            locked: locked,
            lockReason: lockReason,
            updatedAt: "2026-08-13T00:00:00Z"))
    }

    // MARK: Naming a database

    func testAnEmptyDatabaseIsNamedOnFirstUse() async throws {
        let engine = makeEngine(generation: "gen-new")

        let identity = try await engine.verifyDatabaseIdentity()

        XCTAssertEqual(identity, .matched(generation: "gen-new"))
        let state = await engine.currentState
        XCTAssertEqual(state.databaseGeneration, "gen-new")
        XCTAssertTrue(
            server.documentIDs(includeReserved: true).contains(CouchMetaDocID.database),
            "the identity document should have been written")
    }

    /// A database that already holds a library predates this document. Minting one here would be
    /// this device deciding it is a *new* database — which is the decision that leads to rebuilding
    /// a library it should have been syncing with.
    func testAPopulatedDatabaseWithoutMetadataIsLeftAlone() async throws {
        server.seedRaw(CouchDocID.notebook("nb1"), ["type": "notebook", "schema": 1])
        let engine = makeEngine()

        let identity = try await engine.verifyDatabaseIdentity()

        XCTAssertEqual(identity, .unknown)
        let state = await engine.currentState
        XCTAssertNil(state.databaseGeneration)
        XCTAssertFalse(
            server.documentIDs(includeReserved: true).contains(CouchMetaDocID.database),
            "an existing library must not be renamed by whichever client arrives first")
    }

    /// And it must still sync: the whole point of the staged rollout is that a peer which has never
    /// written the document keeps working.
    func testADatabaseWithoutMetadataStillSyncsUnderEnforcement() async throws {
        server.seedRaw(
            CouchDocID.notebook("nb1"),
            ["type": "notebook", "schema": 1, "createdAt": "2026-01-01T00:00:00Z",
             "updatedAt": "2026-01-01T00:00:00Z", "updatedBy": "boox"])
        let engine = makeEngine(enforce: true)

        let report = try await engine.pull()

        XCTAssertEqual(report.databaseIdentity, .unknown)
        XCTAssertEqual(report.applied, [CouchDocID.notebook("nb1")])
    }

    func testAnExistingIdentityIsAdoptedOnFirstSight() async throws {
        seedMetadata(generation: "gen-server")
        let engine = makeEngine()

        let identity = try await engine.verifyDatabaseIdentity()

        XCTAssertEqual(identity, .matched(generation: "gen-server"))
        let state = await engine.currentState
        XCTAssertEqual(
            state.databaseGeneration, "gen-server",
            "a device with no prior claim adopts what it finds")
    }

    /// Two devices reaching a fresh database together both try to create the document. CouchDB
    /// gives exactly one of them the write; the loser adopts rather than retrying, because the
    /// question has already been answered.
    func testTwoDevicesRacingToNameAnEmptyDatabaseConvergeOnOneGeneration() async throws {
        let first = makeEngine(generation: "gen-first")
        let second = CouchSyncEngine(
            client: CouchDBClient(transport: server, database: "notes"),
            store: FakeLocalStore(),
            deviceID: "boox",
            enforceDatabaseIdentity: false,
            now: { Date(timeIntervalSince1970: 1_770_000_000) },
            newGeneration: { "gen-second" })

        let a = try await first.verifyDatabaseIdentity()
        let b = try await second.verifyDatabaseIdentity()

        XCTAssertEqual(a, b, "both devices must end up believing the same thing")
        XCTAssertEqual(a, .matched(generation: "gen-first"))
        let secondState = await second.currentState
        XCTAssertEqual(secondState.databaseGeneration, "gen-first")
    }

    // MARK: Refusing

    func testADifferentGenerationUnderTheSameNameIsRefused() async throws {
        seedMetadata(generation: "gen-new")
        let engine = makeEngine(
            state: CouchSyncState(lastSeq: "42", databaseGeneration: "gen-old"), enforce: true)

        let identity = try await engine.verifyDatabaseIdentity()
        XCTAssertEqual(identity, .generationChanged(stored: "gen-old", found: "gen-new"))
        XCTAssertFalse(identity.isUsable)

        do {
            _ = try await engine.pull()
            XCTFail("a pull against a different database should refuse")
        } catch CouchError.databaseIdentity {
            // The point of the test.
        }

        let state = await engine.currentState
        XCTAssertEqual(state.lastSeq, "42", "the checkpoint must not be reset on this device's own")
        XCTAssertEqual(state.databaseGeneration, "gen-old", "nor the stored identity overwritten")
    }

    /// The one that cannot be undone from the other side.
    func testAFlushIntoADifferentDatabaseUploadsNothing() async throws {
        seedMetadata(generation: "gen-new")
        let engine = makeEngine(
            state: CouchSyncState(lastSeq: "42", databaseGeneration: "gen-old"), enforce: true)
        store.set(CouchDocID.page("p1"), .page(CouchPage(
            notebookId: "nb1", createdAt: "2026-01-01T00:00:00Z",
            updatedAt: "2026-01-01T00:00:00Z", updatedBy: "ipad")))
        await engine.markDirty([CouchDocID.page("p1")])

        let report = await engine.flush()

        XCTAssertTrue(report.pushed.isEmpty, "nothing may be uploaded into an unknown library")
        XCTAssertEqual(report.stillDirty, [CouchDocID.page("p1")], "and nothing is dropped either")
        XCTAssertFalse(
            report.hasRetriableFailure,
            "waiting does not resolve whose library this is; the user's answer does")
        XCTAssertFalse(server.documentIDs().contains(CouchDocID.page("p1")))
    }

    func testAServerRequiringANewerClientIsRefusedBeforeAnythingIsApplied() async throws {
        seedMetadata(generation: "gen-a", minimumClientProtocol: couchProtocolVersion + 1)
        server.seedRaw(CouchDocID.notebook("nb1"), ["type": "notebook", "schema": 1])
        let engine = makeEngine(enforce: true)

        do {
            _ = try await engine.pull()
            XCTFail("a client below the floor should refuse")
        } catch CouchError.databaseIdentity(let identity) {
            XCTAssertEqual(identity, .clientTooOld(minimum: couchProtocolVersion + 1))
        }
        XCTAssertNil(store.body(CouchDocID.notebook("nb1")), "nothing should have been applied")
    }

    func testALockedDatabaseIsRefusedWithItsReason() async throws {
        seedMetadata(generation: "gen-a", locked: true, lockReason: "rebuilding from the iPad")
        let engine = makeEngine(enforce: true)

        do {
            _ = try await engine.pull()
            XCTFail("a locked database should refuse")
        } catch CouchError.databaseIdentity(let identity) {
            XCTAssertEqual(identity, .locked(reason: "rebuilding from the iPad"))
        }
    }

    // MARK: The staged rollout

    /// Stage 3 is gated. A client that required the metadata would refuse to sync with a peer of
    /// the previous release, which has never written it — so until both apps have shipped stages
    /// 1 and 2, a mismatch is reported and nothing more.
    func testAMismatchIsReportedButNotEnforcedByDefault() async throws {
        seedMetadata(generation: "gen-new")
        server.seedRaw(
            CouchDocID.notebook("nb1"),
            ["type": "notebook", "schema": 1, "createdAt": "2026-01-01T00:00:00Z",
             "updatedAt": "2026-01-01T00:00:00Z", "updatedBy": "boox"])
        let engine = makeEngine(state: CouchSyncState(databaseGeneration: "gen-old"))

        let report = try await engine.pull()

        XCTAssertEqual(
            report.databaseIdentity, .generationChanged(stored: "gen-old", found: "gen-new"))
        XCTAssertEqual(report.applied, [CouchDocID.notebook("nb1")], "observed, not enforced")
    }

    // MARK: The reserved namespace

    /// §1.1: bookkeeping is not a library item. It is not merged, not conflict-copied, and does not
    /// turn up in a report about what a pull brought down.
    func testTheIdentityDocumentIsNeverTreatedAsALibraryDocument() async throws {
        seedMetadata(generation: "gen-a")
        let engine = makeEngine()

        let report = try await engine.pull()

        XCTAssertTrue(report.applied.isEmpty)
        XCTAssertTrue(report.conflictCopies.isEmpty, "it is ours, not an unreadable schema")
        XCTAssertTrue(report.skippedEchoes.isEmpty, "and not noise in the report either")
        XCTAssertNil(store.body(CouchMetaDocID.database), "nothing to store locally")
    }

    /// An id from the reserved namespace this build does not know must be stepped over rather than
    /// filed as a document from the future — that is what reserving a *prefix* buys.
    func testAnUnknownReservedDocumentIsSteppedOverRatherThanConflictCopied() async throws {
        seedMetadata(generation: "gen-a")
        server.seedRaw("sync-meta:something-later", ["type": "sync-something", "schema": 99])
        let engine = makeEngine()

        let report = try await engine.pull()

        XCTAssertTrue(report.conflictCopies.isEmpty)
        XCTAssertTrue(report.applied.isEmpty)
        let state = await engine.currentState
        XCTAssertNotEqual(state.lastSeq, "0", "and the checkpoint moves past it")
    }

    func testTheCheckpointIsPreservedAcrossRunsAgainstTheSameDatabase() async throws {
        seedMetadata(generation: "gen-a")
        server.seedRaw(
            CouchDocID.notebook("nb1"),
            ["type": "notebook", "schema": 1, "createdAt": "2026-01-01T00:00:00Z",
             "updatedAt": "2026-01-01T00:00:00Z", "updatedBy": "boox"])

        let first = makeEngine(enforce: true)
        _ = try await first.pull()
        let carried = await first.currentState

        // A relaunch: same endpoint, same database, same generation.
        let second = CouchSyncEngine(
            client: CouchDBClient(transport: server, database: "notes"),
            store: store, deviceID: "ipad", state: carried, enforceDatabaseIdentity: true)
        let report = try await second.pull()

        XCTAssertEqual(report.databaseIdentity, .matched(generation: "gen-a"))
        XCTAssertEqual(report.lastSeq, carried.lastSeq, "nothing replayed")
        XCTAssertTrue(report.applied.isEmpty)
    }
}
