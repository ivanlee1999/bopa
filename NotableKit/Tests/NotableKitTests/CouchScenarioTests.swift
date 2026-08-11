import XCTest
@testable import NotableKit

/// bopa's half of the cross-app scenario suite. The BOOX half is notable's `CouchScenarioTest.kt`;
/// `scripts/couch-scenarios.sh` interleaves them against one real CouchDB, and the script both
/// halves execute is `docs/couch-sync-vectors/interop-scenarios.json`.
///
/// Where `vectors.json` proves the two merge functions agree on paper, this proves two devices
/// driving their own engines through a real server converge on the same content — including the
/// cases no single-app suite can stage, like an erasure made on one device having to stay erased
/// after the other pushes its own copy back.
///
/// One invocation runs one step index: for every scenario whose step at that index belongs to this
/// device, it replays the device's persisted state, executes the ops, and saves the state again.
/// Skipped unless the environment names a server, a scenario file and a step.
final class CouchScenarioTests: XCTestCase {

    private static let deviceID = "ipad"

    func testScenarioStep() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let urlString = environment["BOPA_COUCH_URL"], let url = URL(string: urlString),
              let scriptPath = environment["COUCH_SCENARIO_FILE"],
              let stepText = environment["COUCH_SCENARIO_STEP"], let step = Int(stepText),
              let stateDir = environment["COUCH_SCENARIO_STATE_DIR"],
              let runID = environment["COUCH_SCENARIO_RUN"]
        else {
            throw XCTSkip("scenario steps run from scripts/couch-scenarios.sh")
        }

        let script = try ScenarioScript(contentsOf: URL(fileURLWithPath: scriptPath))
        let client = CouchDBClient(
            transport: URLSessionTransport(
                baseURL: url,
                username: environment["BOPA_COUCH_USER"] ?? "sync",
                password: environment["BOPA_COUCH_PASSWORD"] ?? ""),
            database: environment["BOPA_COUCH_DATABASE"] ?? "notes")

        var ran = 0
        for scenario in script.scenarios {
            guard let ops = scenario.ops(at: step, device: Self.deviceID) else { continue }
            let device = ScenarioDevice(
                scenario: scenario.name, runID: runID, deviceID: Self.deviceID,
                stateDirectory: URL(fileURLWithPath: stateDir), client: client, step: step)
            do {
                try await device.run(ops)
            } catch {
                XCTFail("[\(scenario.name)] step \(step): \(error)")
            }
            ran += 1
        }

        // A receipt, checked by the driver against the step count it expects. Without one, a run in
        // which this test never executed — a skipped assumption, a filter that matched nothing —
        // is indistinguishable from one where every scenario passed.
        try? "\(ran)".write(
            to: URL(fileURLWithPath: stateDir).appendingPathComponent("ran.\(Self.deviceID).\(step)"),
            atomically: true, encoding: .utf8)
    }
}

// MARK: - The script

private struct ScenarioScript {
    struct Scenario {
        let name: String
        let steps: [[String: Any]]

        /// The op list for this device at `index`, or nil when the step belongs to the peer.
        func ops(at index: Int, device: String) -> [[String: Any]]? {
            guard index < steps.count else { return nil }
            guard steps[index]["device"] as? String == device else { return nil }
            return steps[index]["do"] as? [[String: Any]] ?? []
        }
    }

    let scenarios: [Scenario]

    init(contentsOf url: URL) throws {
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        guard let object = root as? [String: Any],
              let raw = object["scenarios"] as? [[String: Any]]
        else { throw ScenarioError("scenario file has no `scenarios` array") }
        scenarios = raw.compactMap { entry in
            guard let name = entry["name"] as? String,
                  let steps = entry["steps"] as? [[String: Any]]
            else { return nil }
            return Scenario(name: name, steps: steps)
        }
    }
}

private struct ScenarioError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

// MARK: - Persisted device

/// One device's world between steps: what it holds locally, plus the sync state (checkpoint,
/// revisions, outbox). Each step is a separate process, so both have to survive on disk — which is
/// also what makes "edit now, push two steps later" a genuine offline edit rather than a fiction.
private final class ScenarioDevice {

    private struct Persisted: Codable {
        var lastSeq = "0"
        var revs: [String: String] = [:]
        var dirty: [String] = []
        var conflictCopies: [String] = []
        /// documentID → (deleted, body JSON). Stored as text so the file stays diffable.
        var docs: [String: Envelope] = [:]

        struct Envelope: Codable {
            var deleted: Bool
            var json: String
        }
    }

    private let scenario: String
    private let runID: String
    private let deviceID: String
    private let stateURL: URL
    private let client: CouchDBClient
    private let step: Int
    private var persisted: Persisted
    private let store: ScenarioStore

    init(
        scenario: String, runID: String, deviceID: String, stateDirectory: URL,
        client: CouchDBClient, step: Int
    ) {
        self.scenario = scenario
        self.runID = runID
        self.deviceID = deviceID
        self.client = client
        self.step = step
        self.stateURL = stateDirectory
            .appendingPathComponent("\(scenario).\(deviceID).json")
        try? FileManager.default.createDirectory(
            at: stateDirectory, withIntermediateDirectories: true)
        persisted = (try? Data(contentsOf: stateURL))
            .flatMap { try? JSONDecoder().decode(Persisted.self, from: $0) } ?? Persisted()
        store = ScenarioStore(
            docs: persisted.docs.compactMapValues {
                ScenarioCoding.decode(json: $0.json, deleted: $0.deleted)
            },
            conflictCopies: persisted.conflictCopies)
    }

    // MARK: Running

    func run(_ ops: [[String: Any]]) async throws {
        // Saved even when an op throws: the later steps of this scenario still have to run against
        // what actually happened, or one failure reads as five.
        defer { save() }
        for (index, op) in ops.enumerated() {
            try await apply(op, index: index)
        }
    }

    private func apply(_ op: [String: Any], index: Int) async throws {
        guard let name = op["op"] as? String else { throw ScenarioError("op without a name") }
        let at = NotableDate.format(Date(
            timeIntervalSince1970: 1_770_000_000 + Double(op["at"] as? Int ?? step * 1000 + index)))

        switch name {
        case "newNotebook":
            let id = try logicalID(op)
            let pages = op["pages"] as? [String] ?? []
            store.set(docID(op), .notebook(CouchNotebook(
                title: op["title"] as? String ?? "",
                pageIds: pages.map(rawID),
                createdAt: at, updatedAt: at, updatedBy: deviceID)))
            markDirty(docID(op))
            for page in pages {
                let pageDocID = CouchDocID.page(rawID(page))
                store.set(pageDocID, .page(CouchPage(
                    notebookId: id, createdAt: at, updatedAt: at, updatedBy: deviceID)))
                markDirty(pageDocID)
            }

        case "newFolder":
            store.set(docID(op), .folder(CouchFolder(
                title: op["title"] as? String ?? "",
                createdAt: at, updatedAt: at, updatedBy: deviceID)))
            markDirty(docID(op))

        case "draw":
            var page = try page(op)
            for stroke in op["strokes"] as? [String] ?? [] {
                page.strokes.append(CouchStroke(
                    id: stroke, createdAt: at, updatedAt: at, deviceId: deviceID,
                    pen: "FOUNTAIN", color: -16_777_216, size: 4.25,
                    top: 10, bottom: 20, left: 5, right: 15, pointsData: "U0ICD10AAAAA"))
            }
            page.updatedAt = at
            page.updatedBy = deviceID
            store.set(docID(op), .page(page))
            markDirty(docID(op))

        case "erase":
            var page = try page(op)
            let removed = Set(op["strokes"] as? [String] ?? [])
            let before = Set(page.strokes.map(\.id))
            page.strokes.removeAll { removed.contains($0.id) }
            // The real save path, not a hand-written tombstone: this is the code that has to be
            // right for an erasure to stay erased.
            CouchTombstones.recordErasures(
                in: &page, previousStrokeIDs: before, deletedAt: at)
            page.updatedAt = at
            page.updatedBy = deviceID
            store.set(docID(op), .page(page))
            markDirty(docID(op))

        case "placeImage":
            var page = try page(op)
            let bytes = try imageBytes(op)
            let assetID = CouchAssetID.forBytes(bytes)
            // The bytes land in this device's own store first, exactly as importing a picture
            // does; sync's job is to notice the page now names an asset and carry it across.
            store.set(assetID, .asset(CouchAsset(data: bytes, at: at, updatedBy: deviceID)))
            page.images.append(CouchImage(
                id: op["image"] as? String ?? "",
                assetId: assetID,
                x: op["x"] as? Int ?? 0, y: op["y"] as? Int ?? 0,
                width: op["width"] as? Int ?? 0, height: op["height"] as? Int ?? 0,
                createdAt: at, updatedAt: at))
            page.updatedAt = at
            page.updatedBy = deviceID
            store.set(docID(op), .page(page))
            markDirty(docID(op))

        case "setBackground":
            var page = try page(op)
            page.background = op["background"] as? String ?? "blank"
            page.updatedAt = at
            page.updatedBy = deviceID
            store.set(docID(op), .page(page))
            markDirty(docID(op))

        case "rename":
            switch try body(op) {
            case .notebook(var notebook):
                notebook.title = op["title"] as? String ?? ""
                notebook.updatedAt = at
                notebook.updatedBy = deviceID
                store.set(docID(op), .notebook(notebook))
            case .folder(var folder):
                folder.title = op["title"] as? String ?? ""
                folder.updatedAt = at
                folder.updatedBy = deviceID
                store.set(docID(op), .folder(folder))
            default:
                throw ScenarioError("rename applies to notebooks and folders")
            }
            markDirty(docID(op))

        case "move":
            var notebook = try notebook(op)
            notebook.parentFolderId = (op["folder"] as? String).map(rawID)
            notebook.updatedAt = at
            notebook.updatedBy = deviceID
            store.set(docID(op), .notebook(notebook))
            markDirty(docID(op))

        case "addPage":
            var notebook = try notebook(op)
            guard let page = op["page"] as? String else { throw ScenarioError("addPage needs page") }
            notebook.pageIds.append(rawID(page))
            notebook.updatedAt = at
            notebook.updatedBy = deviceID
            store.set(docID(op), .notebook(notebook))
            markDirty(docID(op))
            let pageDocID = CouchDocID.page(rawID(page))
            store.set(pageDocID, .page(CouchPage(
                notebookId: try logicalID(op), createdAt: at, updatedAt: at, updatedBy: deviceID)))
            markDirty(pageDocID)

        case "deletePage":
            var notebook = try notebook(op)
            guard let page = op["page"] as? String else {
                throw ScenarioError("deletePage needs page")
            }
            let removed = rawID(page)
            notebook.pageIds.removeAll { $0 == removed }
            notebook.deletedPageIds = CouchTombstones.derive(
                previousIDs: [removed], currentIDs: [],
                existing: notebook.deletedPageIds, deletedAt: at)
            notebook.updatedAt = at
            notebook.updatedBy = deviceID
            store.set(docID(op), .notebook(notebook))
            markDirty(docID(op))

        case "delete":
            guard let (type, _) = CouchDocID.split(docID(op)) else {
                throw ScenarioError("undeletable id")
            }
            store.set(docID(op), .deleted(CouchDeletedDoc(
                type: type, deletedAt: at, updatedBy: deviceID)))
            markDirty(docID(op))

        case "push":
            let engine = makeEngine()
            let report = await engine.flush()
            guard report.failures.isEmpty else {
                throw ScenarioError("push failed: \(report.failures)")
            }
            await absorb(engine)

        case "pull":
            let engine = makeEngine()
            _ = try await engine.pull()
            await absorb(engine)

        case "reset":
            // A reinstall: the device forgets both its content and where it was in the feed.
            persisted = Persisted()
            store.reset()

        // MARK: Assertions

        case "expectStrokes":
            let expected = (op["ids"] as? [String] ?? []).sorted()
            let actual = try page(op).strokes.map(\.id).sorted()
            XCTAssertEqual(actual, expected, "[\(scenario)] \(describe(op)) strokes")

        case "expectImage":
            let bytes = try imageBytes(op)
            let assetID = CouchAssetID.forBytes(bytes)
            let placed = try page(op).images.first { $0.id == op["image"] as? String }
            XCTAssertEqual(
                placed?.assetId, assetID,
                "[\(scenario)] \(describe(op)) should place \(assetID)")
            // The reference is only half of it: without the bytes the peer cannot draw anything,
            // which is the whole failure this scenario exists to catch.
            guard case .asset(let held)? = try store.load(assetID) else {
                XCTFail("[\(scenario)] \(describe(op)) holds no bytes for \(assetID)")
                break
            }
            XCTAssertEqual(
                held.data, bytes, "[\(scenario)] \(describe(op)) holds different bytes")

        case "expectPageIds":
            let expected = (op["pages"] as? [String] ?? []).map(rawID)
            XCTAssertEqual(
                try notebook(op).pageIds, expected, "[\(scenario)] \(describe(op)) pageIds")

        case "expectTitle":
            let expected = op["title"] as? String ?? ""
            switch try body(op) {
            case .notebook(let notebook):
                XCTAssertEqual(notebook.title, expected, "[\(scenario)] \(describe(op)) title")
            case .folder(let folder):
                XCTAssertEqual(folder.title, expected, "[\(scenario)] \(describe(op)) title")
            default:
                XCTFail("[\(scenario)] \(describe(op)) is not titled")
            }

        case "expectParent":
            let expected = (op["folder"] as? String).map(rawID)
            XCTAssertEqual(
                try notebook(op).parentFolderId, expected, "[\(scenario)] \(describe(op)) parent")

        case "expectBackground":
            XCTAssertEqual(
                try page(op).background, op["background"] as? String ?? "blank",
                "[\(scenario)] \(describe(op)) background")

        case "expectDeleted":
            let held = try store.load(docID(op))
            XCTAssertTrue(
                held?.isDeleted ?? false,
                "[\(scenario)] \(describe(op)) should be deleted, holds \(String(describing: held))")

        case "expectConflictCopy":
            XCTAssertTrue(
                store.conflictCopies.contains(docID(op)),
                "[\(scenario)] \(describe(op)) should have been set aside, "
                    + "got \(store.conflictCopies)")

        case "expectClean":
            XCTAssertTrue(
                persisted.dirty.isEmpty,
                "[\(scenario)] step \(step): nothing should still be queued, "
                    + "got \(persisted.dirty)")

        default:
            throw ScenarioError("unknown op `\(name)`")
        }
    }

    // MARK: Engine plumbing

    private func makeEngine() -> CouchSyncEngine {
        CouchSyncEngine(
            client: client, store: store, deviceID: deviceID,
            state: CouchSyncState(
                lastSeq: persisted.lastSeq, revs: persisted.revs, dirty: Set(persisted.dirty)))
    }

    private func absorb(_ engine: CouchSyncEngine) async {
        let state = await engine.currentState
        persisted.lastSeq = state.lastSeq
        persisted.revs = state.revs
        persisted.dirty = state.dirty.sorted()
    }

    private func markDirty(_ documentID: String) {
        if !persisted.dirty.contains(documentID) { persisted.dirty.append(documentID) }
    }

    private func save() {
        persisted.docs = store.snapshot().compactMapValues { body in
            ScenarioCoding.encode(body).map {
                Persisted.Envelope(deleted: body.isDeleted, json: $0)
            }
        }
        persisted.conflictCopies = store.conflictCopies
        guard let data = try? JSONEncoder().encode(persisted) else { return }
        try? data.write(to: stateURL, options: .atomic)
    }

    // MARK: Names and lookups

    /// `"pgA"` → `"ipad-starts-boox-continues-pgA-1770000000"`. Namespacing by run keeps repeated
    /// runs from colliding in a database that is never wiped between them.
    private func rawID(_ logical: String) -> String { "\(scenario)-\(logical)-\(runID)" }

    private func docID(_ op: [String: Any]) -> String {
        let logical = op["doc"] as? String ?? ""
        let id = rawID(logical)
        if logical.hasPrefix("nb") { return CouchDocID.notebook(id) }
        if logical.hasPrefix("fd") { return CouchDocID.folder(id) }
        return CouchDocID.page(id)
    }

    private func logicalID(_ op: [String: Any]) throws -> String {
        guard let logical = op["doc"] as? String else { throw ScenarioError("op without a doc") }
        return rawID(logical)
    }

    private func describe(_ op: [String: Any]) -> String {
        "step \(step) \(op["op"] as? String ?? "?") \(op["doc"] as? String ?? "?")"
    }

    /// The picture an image op works with, base64 in the script so both apps hash the same bytes
    /// and therefore agree on the asset id without ever comparing notes.
    private func imageBytes(_ op: [String: Any]) throws -> Data {
        guard let base64 = op["bytes"] as? String, let bytes = Data(base64Encoded: base64) else {
            throw ScenarioError("\(describe(op)) needs `bytes` as base64")
        }
        return bytes
    }

    private func body(_ op: [String: Any]) throws -> CouchDocBody {
        guard let body = try store.load(docID(op)) else {
            throw ScenarioError("\(describe(op)): this device holds no \(docID(op))")
        }
        return body
    }

    private func page(_ op: [String: Any]) throws -> CouchPage {
        guard case .page(let page) = try body(op) else {
            throw ScenarioError("\(describe(op)) is not a page")
        }
        return page
    }

    private func notebook(_ op: [String: Any]) throws -> CouchNotebook {
        guard case .notebook(let notebook) = try body(op) else {
            throw ScenarioError("\(describe(op)) is not a notebook")
        }
        return notebook
    }
}

// MARK: - Store

/// Map-backed `CouchLocalStore` whose contents the device serializes between steps.
private final class ScenarioStore: CouchLocalStore, @unchecked Sendable {
    private let lock = NSLock()
    private var docs: [String: CouchDocBody]
    private var copies: [String]

    init(docs: [String: CouchDocBody], conflictCopies: [String]) {
        self.docs = docs
        self.copies = conflictCopies
    }

    var conflictCopies: [String] { lock.withLock { copies } }

    func load(_ documentID: String) throws -> CouchDocBody? { lock.withLock { docs[documentID] } }

    func apply(_ documentID: String, _ body: CouchDocBody, basedOn: CouchDocBody?) throws {
        lock.withLock { docs[documentID] = body }
    }

    /// Every asset a held page places whose bytes are not here — the same question the real stores
    /// answer from disk and from Room.
    func missingAssetIDs() throws -> [String] {
        lock.withLock {
            Set(docs.values.flatMap(\.referencedAssetIDs))
                .filter { docs[$0] == nil }
                .sorted()
        }
    }

    /// Protocol §6.5: the local copy is left exactly as it is. Recording the id is enough to assert
    /// that — the real store materializes the remote document under a fresh identity.
    func applyConflictCopy(_ documentID: String, json: Data) throws {
        lock.withLock { if !copies.contains(documentID) { copies.append(documentID) } }
    }

    func set(_ documentID: String, _ body: CouchDocBody) { lock.withLock { docs[documentID] = body } }
    func snapshot() -> [String: CouchDocBody] { lock.withLock { docs } }
    func reset() { lock.withLock { docs = [:]; copies = [] } }
}

// MARK: - Body ⇄ JSON

private enum ScenarioCoding {
    static func decode(json: String, deleted: Bool) -> CouchDocBody? {
        guard let data = json.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        if deleted {
            return (try? decoder.decode(CouchDeletedDoc.self, from: data)).map(CouchDocBody.deleted)
        }
        guard let type = (try? decoder.decode(TypeEnvelope.self, from: data))?.type
        else { return nil }
        switch type {
        case CouchDocType.page:
            return (try? decoder.decode(CouchPage.self, from: data)).map(CouchDocBody.page)
        case CouchDocType.notebook:
            return (try? decoder.decode(CouchNotebook.self, from: data)).map(CouchDocBody.notebook)
        case CouchDocType.folder:
            return (try? decoder.decode(CouchFolder.self, from: data)).map(CouchDocBody.folder)
        case CouchDocType.asset:
            return (try? decoder.decode(CouchAsset.self, from: data)).map(CouchDocBody.asset)
        default:
            return nil
        }
    }

    static func encode(_ body: CouchDocBody) -> String? {
        let encoder = JSONEncoder()
        let data: Data?
        switch body {
        case .page(let page): data = try? encoder.encode(page)
        case .notebook(let notebook): data = try? encoder.encode(notebook)
        case .folder(let folder): data = try? encoder.encode(folder)
        // The blob rides along in `_attachments`, so a device that downloaded a picture in one
        // step still has it in the next — which is what makes the assertion about bytes real.
        case .asset(let asset): data = try? encoder.encode(asset)
        case .deleted(let tombstone): data = try? encoder.encode(tombstone)
        }
        return data.flatMap { String(data: $0, encoding: .utf8) }
    }

    private struct TypeEnvelope: Decodable { var type: String }
}
