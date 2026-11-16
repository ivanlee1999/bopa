import NotableKit
import SwiftUI
import UIKit
import XCTest
@testable import Bopa

/// Explicit, one-phase, GET-only observation of the root-authorized synthetic server fixture.
@MainActor
final class LayoutTranscriptEndToEndTests: XCTestCase {
    private struct Fixture: Decodable {
        var notebookId: String; var pageId: String; var blockId: String; var typedParagraph: String
        var metadata: CouchDatabaseMetadata; var organization: JournalOrganization
        var phases: [Phase]
    }
    private struct Phase: Decodable { var name: String; var layout: Layout? }
    private struct Layout: Decodable {
        var headings: [String]; var bullets: [String]; var ordered: [String]; var orderedNumbers: [String]
        var tasks: [ExpectedTask]; var table: Table
    }
    private struct ExpectedTask: Decodable, Equatable { var text: String; var checked: Bool }
    private struct Table: Decodable { var header: [String]; var rows: [[String]] }
    private struct Verified: Decodable {
        var phase: String; var text: String; var sourceRev: String; var sourceFingerprint: String; var pipelineVersion: String
    }

    func testAuthorizedServerLayoutThroughRealHostIndexAndNativeCard() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["BOPA_LAYOUT_E2E_ENABLE"] == "1" else { throw XCTSkip("opt-in isolated layout observer") }
        #if !targetEnvironment(simulator)
        throw XCTSkip("Disposable simulator only")
        #else
        guard env["SIMULATOR_UDID"] == "7963104C-F70B-4C36-A0E9-84DBB8EBD877",
              let url = URL(string: env["BOPA_LAYOUT_E2E_URL"] ?? ""), url.scheme == "http", url.host == "127.0.0.1",
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil, url.path.isEmpty || url.path == "/",
              env["BOPA_LAYOUT_E2E_DATABASE"] == "llm_e2e_layout_notes", env["BOPA_LAYOUT_E2E_USER"] == "llm_e2e" else { throw CocoaError(.userCancelled) }
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: try XCTUnwrap(env["BOPA_LAYOUT_E2E_FIXTURE"]))))
        guard fixture.metadata.generation == "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa16",
              fixture.notebookId == "66666666-6666-4666-8666-666666666616", fixture.pageId == "77777777-7777-4777-8777-777777777716" else { throw CocoaError(.userCancelled) }
        let expected = try JSONDecoder().decode(Verified.self, from: Data(contentsOf: URL(fileURLWithPath: try XCTUnwrap(env["BOPA_LAYOUT_E2E_VERIFIED_TEXT"]))))
        guard expected.phase == env["BOPA_LAYOUT_E2E_PHASE"] else { throw CocoaError(.userCancelled) }
        let settings = CouchSettings(serverURL: url.absoluteString, database: "llm_e2e_layout_notes", username: "llm_e2e",
            password: try XCTUnwrap(env["BOPA_LAYOUT_E2E_PASSWORD"]), deviceID: "bopa-layout-observer", textDatabase: "llm_e2e_layout_notes_text")
        let client = try XCTUnwrap(settings.makeClient())
        let metadata = try await client.get(CouchMetaDocID.database, as: CouchDatabaseMetadata.self)
        guard metadata?.body.generation == fixture.metadata.generation, metadata?.body.locked == false else { throw CocoaError(.userCancelled) }
        let remoteNote = try await client.get(CouchDocID.notebook(fixture.notebookId), as: CouchNotebook.self)
        let remotePage = try await client.get(CouchDocID.page(fixture.pageId), as: CouchPage.self)
        let note = try XCTUnwrap(remoteNote), page = try XCTUnwrap(remotePage)
        let organizations = CouchDBClient(transport: client.transport, database: settings.database + "_organization")
        let remoteOrganization = try await organizations.get("journal:" + fixture.notebookId, as: JournalOrganization.self)
        let organization = try XCTUnwrap(remoteOrganization)
        guard !note.deleted, !page.deleted, organization.body == fixture.organization,
              TextVersions.sameSource(page.body.blocks.first(where: { $0.id == fixture.blockId })?.text, fixture.typedParagraph) else { throw CocoaError(.userCancelled) }

        let suite = "layout-observer-\(UUID().uuidString)", preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        preferences.set(false, forKey: "journal.automaticTags")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { try? FileManager.default.removeItem(at: root); preferences.removePersistentDomain(forName: suite) }
        let store = NotebookStore(rootURL: root, preferences: preferences)
        // Import through the production remote mapping, without running a sync pump or push.
        let disk = FileCouchStore(rootURL: root, deviceID: settings.deviceID)
        try disk.apply(CouchDocID.notebook(fixture.notebookId), .notebook(note.body), basedOn: nil)
        try disk.apply(CouchDocID.page(fixture.pageId), .page(page.body), basedOn: nil)
        _ = try XCTUnwrap(store.organization).merge(organization.body)
        let state = CouchSyncState(revs: [CouchDocID.notebook(fixture.notebookId): note.rev, CouchDocID.page(fixture.pageId): page.rev])
        try JSONEncoder().encode(state).write(to: root.appendingPathComponent(CouchSyncStack.stateFileName(for: settings)), options: .atomic)
        store.refresh(); store.refreshJournal()
        let local = try XCTUnwrap(store.transcriptPage(notebookID: fixture.notebookId, pageID: fixture.pageId))
        let pageURL = store.notebookDirURL(fixture.notebookId).appendingPathComponent("pages/\(fixture.pageId).json")
        let before = try Data(contentsOf: pageURL)
        let standard = UserDefaults.standard
        standard.set(true, forKey: CouchSettings.cloudTextKey); standard.set("text", forKey: "library.previewContent"); standard.synchronize()
        let host = SyncBackendHost(loadSettings: { settings }, loadBackend: { .couchdb })
        host.attach(store: store, coordinator: SyncCoordinator())
        defer { host.willResignActive() }
        let index = HandwritingTranscriptIndex()
        index.serverReader = { await host.serverTranscript(notebookID: $0, pageID: $1) }
        await index.requestServer(notebookID: fixture.notebookId, pageID: fixture.pageId, store: store).value
        let verified = try XCTUnwrap(index.serverRecords[HandwritingTranscriptIndex.key(fixture.notebookId, fixture.pageId)])
        let projected = TranscriptContent(text: verified.result.text, format: verified.result.format)
        let displayed = index.content(notebookID: fixture.notebookId, pageID: fixture.pageId, fingerprint: "", serverInk: ScribeInkSnapshot(local))
        guard projected.text.isEmpty ? displayed == nil : displayed == projected else { throw CocoaError(.userCancelled) }
        guard projected.isMarkdown, verified.result.sourceRev == page.rev, ScribeInkSnapshot(local) == ScribeInkSnapshot(page.body), index.records.isEmpty else { throw CocoaError(.userCancelled) }
        guard TextVersions.sameSource(projected.text, expected.text), expected.sourceRev == verified.result.sourceRev,
              expected.sourceFingerprint == verified.result.sourceFingerprint, expected.pipelineVersion == verified.result.pipelineVersion else { throw CocoaError(.userCancelled) }
        let blocks = TranscriptMarkdown.parse(projected.text)
        let phase = try XCTUnwrap(fixture.phases.first { $0.name == expected.phase })
        try validate(blocks, layout: phase.layout, source: projected.text)
        let tableCount = blocks.filter { if case .table = $0 { true } else { false } }.count
        let taskCount = blocks.filter { if case .line(_, _, .some) = $0 { true } else { false } }.count
        guard !blocks.isEmpty else { throw CocoaError(.userCancelled) }
        for width: CGFloat in [375, 834] {
            let card = NotebookContentCard(notebook: try XCTUnwrap(store.manifest(id: fixture.notebookId)), edit: { _ in })
                .environmentObject(store).environmentObject(index).padding(16)
            try await capture(card, width: width)
        }
        index.setDrawing(true, owner: UUID(), notebookID: fixture.notebookId, pageID: fixture.pageId, store: store)
        let afterPage = try await client.get(CouchDocID.page(fixture.pageId), as: CouchPage.self)
        let afterOrganization = try await organizations.get("journal:" + fixture.notebookId, as: JournalOrganization.self)
        guard index.records.isEmpty, try Data(contentsOf: pageURL) == before, local.blocks == page.body.blocks,
              afterPage?.rev == page.rev, afterPage?.body == page.body, afterOrganization?.rev == organization.rev,
              afterOrganization?.body == organization.body, store.journalEntries[fixture.notebookId] == fixture.organization else { throw CocoaError(.userCancelled) }
        let report: [String: Any] = ["phase": env["BOPA_LAYOUT_E2E_PHASE"] ?? "", "text": projected.text, "format": projected.format ?? "",
            "sourceRev": page.rev, "sourceFingerprint": verified.result.sourceFingerprint ?? "", "pipelineVersion": verified.result.pipelineVersion ?? "",
            "engine": verified.result.engine ?? "", "tableCount": tableCount, "taskCount": taskCount,
            "canonicalPageAndOrganizationUnchanged": true, "localOCRUsed": false, "networkScope": "GET-only observer; no native/provider writes"]
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), uniformTypeIdentifier: "public.json")
        attachment.name = "verified-server-layout"; attachment.lifetime = .keepAlways; add(attachment)
        #endif
    }

    private func validate(_ blocks: [TranscriptMarkdown.Block], layout: Layout?, source: String) throws {
        guard let layout else {
            guard source.isEmpty else { throw CocoaError(.userCancelled) }; return
        }
        func normalized(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        var headings: [String] = [], bullets: [String] = [], ordered: [String] = [], numbers: [String] = [], tasks: [ExpectedTask] = []
        var tables: [Table] = []
        for block in blocks {
            switch block {
            case .line(let line, _, let checked):
                let text = normalized(line.plainText)
                if let checked { tasks.append(ExpectedTask(text: text, checked: checked)) }
                else {
                    switch line.kind {
                    case .heading: headings.append(text)
                    case .bullet: bullets.append(text)
                    case .numbered(let number): ordered.append(text); numbers.append(String(number))
                    default: break
                    }
                }
            case .table(let headers, let rows, _):
                func cell(_ text: String) -> String { normalized(MarkdownText.parseInline(text).map(\.text).joined()) }
                tables.append(Table(header: headers.map(cell), rows: rows.map { $0.map(cell) }))
            case .code: break
            }
        }
        guard headings == layout.headings.map(normalized), bullets == layout.bullets.map(normalized),
              ordered == layout.ordered.map(normalized), numbers == layout.orderedNumbers,
              tasks == layout.tasks.map({ ExpectedTask(text: normalized($0.text), checked: $0.checked) }), tables.count == 1,
              tables[0].header == layout.table.header.map(normalized), tables[0].rows == layout.table.rows.map({ $0.map(normalized) }) else {
            XCTFail("Native parsed layout differs from the authorized phase"); throw CocoaError(.userCancelled)
        }
    }

    private func capture<V: View>(_ view: V, width: CGFloat) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: width, height: 1400)
        let controller = UIHostingController(rootView: view); window.rootViewController = controller; window.makeKeyAndVisible()
        controller.view.layoutIfNeeded(); try await Task.sleep(for: .milliseconds(200))
        let image = UIGraphicsImageRenderer(bounds: controller.view.bounds).image { _ in controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true) }
        let attachment = XCTAttachment(image: image); attachment.name = "actual-server-layout-card-\(Int(width))"; attachment.lifetime = .keepAlways; add(attachment)
        window.isHidden = true; previous?.makeKeyAndVisible()
    }
}
