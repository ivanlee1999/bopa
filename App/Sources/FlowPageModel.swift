import Foundation
import NotableKit

/// One native typing surface per consecutive Markdown run. The on-disk journal is a draft,
/// never a second synced document; successful saves still write the page's original blocks.
@MainActor
final class FlowPageModel: NSObject, ObservableObject {
    struct Part: Identifiable {
        let id: String
        var blocks: [CouchBlock]
        var source: String
        var conflict = false
        var pending: [CouchBlock]?
        var isMarkdown: Bool { blocks.isEmpty || blocks.allSatisfy { $0.kind == "md" } }
    }
    private struct Draft: Codable {
        var id: String
        var blocks: [CouchBlock]
        var source: String
        var pending: [CouchBlock]?
    }
    @Published private(set) var parts: [Part] = []
    @Published private(set) var page: PageFile?
    @Published var error: String?
    @Published private(set) var saved = true
    @Published private(set) var versions: [CouchBlock] = []
    private(set) var recoveredNotebookID: String?
    private var store: NotebookStore?
    private var notebookID = ""
    private var pageID = ""
    private var saveTask: Task<Void, Never>?
    private var committing = false
    private var editing = false
    private var dirty: Set<String> = []
    private var deviceID = CouchSettings.defaultDeviceID

    @discardableResult
    func attach(store: NotebookStore, notebookID: String, pageID: String) -> Bool {
        if self.pageID == pageID, self.notebookID == notebookID, self.store != nil { return true }
        guard flush() else { return false }
        self.store = store; self.notebookID = notebookID; self.pageID = pageID
        recoveredNotebookID = nil
        deviceID = CouchSettings.load().deviceID
        NotificationCenter.default.removeObserver(self)
        NotificationCenter.default.addObserver(self, selector: #selector(changed), name: NotebookStore.didApplyRemoteChangesNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(changed), name: NotebookStore.didChangeLocallyNotification, object: nil)
        do {
            try reload()
            if let data = try? Data(contentsOf: draftURL),
               let drafts = try? JSONDecoder().decode([Draft].self, from: data) {
                for draft in drafts {
                    if let pending = draft.pending, let page,
                       pending.allSatisfy({ planned in page.blocks.contains { $0.id == planned.id && TextVersions.sameSource($0.text, planned.text) } }),
                       draft.blocks.filter({ old in !pending.contains { $0.id == old.id } }).allSatisfy({ old in page.deletedBlocks.contains { $0.id == old.id } }) {
                        continue
                    }
                    if let index = parts.firstIndex(where: { $0.id == draft.id }) {
                        parts[index].blocks = draft.blocks; parts[index].source = draft.source; parts[index].pending = draft.pending
                    } else {
                        parts.append(Part(id: draft.id, blocks: draft.blocks, source: draft.source, pending: draft.pending))
                    }
                    dirty.insert(draft.id)
                }
                saved = dirty.isEmpty
                try writeDraft()
            }
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    func source(for id: String) -> String { parts.first(where: { $0.id == id })?.source ?? "" }

    func update(_ source: String, id: String) {
        guard let index = parts.firstIndex(where: { $0.id == id }),
              !TextVersions.sameSource(parts[index].source, source) else { return }
        parts[index].source = source
        dirty.insert(id); saved = false
        do { try writeDraft() } catch { self.error = error.localizedDescription }
        saveTask?.cancel()
        if !parts[index].conflict {
            saveTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                if !Task.isCancelled { self?.flush() }
            }
        }
    }

    func beganEditing() { editing = true }
    func endedEditing() {
        editing = false
        if flush() { try? reload() }
    }

    @objc private func changed() {
        guard !committing, !editing, dirty.isEmpty else { return }
        do { try reload() } catch { self.error = error.localizedDescription }
    }

    @discardableResult
    func flush() -> Bool {
        saveTask?.cancel()
        guard !dirty.isEmpty else {
            guard !saved else { return true }
            do { try writeDraft(); saved = true; error = nil; return true }
            catch { self.error = error.localizedDescription; return false }
        }
        guard let store, !committing else { return false }
        committing = true; defer { committing = false }
        do {
            try writeDraft()
            for index in parts.indices where dirty.contains(parts[index].id) {
                let part = parts[index]
                var current = try store.loadPage(notebookId: notebookID, pageId: pageID)
                let stamp = localStamp(in: current)
                let pendingCollision = (part.pending ?? []).contains { planned in
                    guard !part.blocks.contains(where: { $0.id == planned.id }) else { return false }
                    if current.deletedBlocks.contains(where: { $0.id == planned.id }) { return true }
                    guard let remote = current.blocks.first(where: { $0.id == planned.id }) else { return false }
                    return remote.kind != "md" || !TextVersions.sameSource(remote.text, planned.text)
                }
                if pendingCollision {
                    try preserve(part, in: current, stamp: stamp)
                    parts[index].conflict = true
                    self.error = "This note changed while you were typing. Your draft is kept."
                    return false
                }
                var minted: [String] = []
                var reusable = (part.pending ?? []).filter { planned in !part.blocks.contains { $0.id == planned.id } }.map(\.id)
                let proposed: [CouchBlock]
                do {
                    proposed = try FlowText.replacing(base: part.blocks, in: current.blocks,
                        with: part.source, stamp: stamp, deviceID: deviceID,
                        makeID: { let id = reusable.isEmpty ? UUID().uuidString.lowercased() : reusable.removeFirst(); minted.append(id); return id })
                } catch {
                    try preserve(part, in: current, stamp: stamp)
                    parts[index].conflict = true
                    self.error = "This note changed while you were typing. Your draft is kept."
                    return false
                }
                let base = Dictionary(part.blocks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                let latest = Dictionary(current.blocks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                let next = Dictionary(proposed.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                let conflicts = part.blocks.contains { original in
                    guard let remote = latest[original.id], !current.deletedBlocks.contains(where: { $0.id == original.id }) else { return true }
                    guard let candidate = next[original.id] else {
                        return !TextVersions.sameSource(remote.text, original.text)
                    }
                    return TextVersions.conflicts(baseText: original.text, currentText: remote.text, draftText: candidate.text ?? "")
                }
                if conflicts {
                    try preserve(part, in: current, stamp: stamp)
                    parts[index].conflict = true
                    self.error = "This note changed while you were typing. Your draft is kept."
                    return false
                }
                let owned = Set(base.keys).union(minted)
                parts[index].pending = FlowText.ordered(proposed).filter { owned.contains($0.id) }
                try writeDraft()
                current.blocks = proposed
                let written = try store.savePage(current, baselineBlockIDs: Set(base.keys))
                // The native field keeps its visible text while focused. An untouched remote
                // paragraph is saved but must retain the field's old base for the next guard.
                let chunks = MarkdownBlocks.split(part.source)
                var newBase = FlowText.ordered(written.blocks).filter { owned.contains($0.id) }
                if newBase.count == chunks.count {
                    for i in newBase.indices { newBase[i].text = chunks[i] }
                }
                parts[index].blocks = newBase; parts[index].conflict = false; parts[index].pending = nil
                page = written; dirty.remove(part.id)
            }
            saved = true; error = nil
            try writeDraft()
            refreshVersions()
            return true
        } catch {
            if store.manifest(id: notebookID)?.pageIds.contains(pageID) != true {
                return recoverMissingPage()
            }
            self.error = error.localizedDescription; saved = false; return false
        }
    }

    func discardAfterLocalDeletion() {
        saveTask?.cancel(); dirty = []; parts = []; saved = true
        try? writeDraft()
    }

    private func recoverMissingPage() -> Bool {
        guard let store else { return false }
        let source = parts.filter { dirty.contains($0.id) }.map(\.source).joined(separator: "\n\n")
        guard !source.isEmpty else { discardAfterLocalDeletion(); return true }
        do {
            let id = DerivedID.derive("notable-flow-draft-recovery:\(notebookID):\(pageID):\(TextVersions.fingerprint(source))")
            let title = "Recovered text — \(store.manifest(id: notebookID)?.title ?? notebookID)"
            let notebook = try store.manifest(id: id) ?? store.createNotebook(title: title, notebookId: id)
            guard let destination = notebook.pageIds.first else { return false }
            var page = try store.loadPage(notebookId: id, pageId: destination)
            if FlowText.markdown(in: page.blocks).isEmpty {
                page.blocks = try FlowText.replacing(base: [], in: page.blocks, with: source,
                    stamp: localStamp(in: page), deviceID: deviceID)
                _ = try store.savePage(page)
            }
            recoveredNotebookID = id
            dirty = []; parts = []; saved = true; self.error = nil
            try writeDraft()
            return true
        } catch { self.error = error.localizedDescription; saved = false; return false }
    }

    private func preserve(_ part: Part, in current: PageFile, stamp: String) throws {
        guard let store, !part.source.isEmpty else { return }
        var source = part.blocks.first ?? CouchBlock(id: part.id, kind: "md", text: "", createdAt: stamp, updatedAt: stamp, deviceId: deviceID)
        source.text = part.source; source.updatedAt = stamp; source.deviceId = deviceID
        let recovered = TextVersions.recovery(source)
        guard !current.deletedBlocks.contains(where: { $0.id == recovered.id }) else { throw FlowText.EditError.boundaryChanged }
        var copy = current
        if !copy.blocks.contains(where: { $0.id == recovered.id }) { copy.blocks.append(recovered) }
        page = try store.savePage(copy)
        refreshVersions()
    }

    func useCurrent() {
        guard let store, let current = try? store.loadPage(notebookId: notebookID, pageId: pageID) else { return }
        do {
            for part in parts where dirty.contains(part.id) { try preserve(part, in: current, stamp: SyncClock.shared.stamp()) }
            dirty = []; try writeDraft(); try reload(); error = nil; saved = true
        } catch { self.error = error.localizedDescription }
    }

    @discardableResult
    func addDraftToNote() -> Bool {
        // Keeping both is a fresh append, using the same durable intent as ordinary typing.
        // This also makes retry/relaunch after the page write idempotent.
        for index in parts.indices where dirty.contains(parts[index].id) {
            parts[index].blocks = []; parts[index].pending = nil; parts[index].conflict = false
        }
        guard flush() else { return false }
        do { try reload(); return true }
        catch { self.error = error.localizedDescription; return false }
    }

    func restoreVersion(_ version: CouchBlock) {
        guard let store else { return }
        committing = true; defer { committing = false }
        do {
            var current = try store.loadPage(notebookId: notebookID, pageId: pageID)
            current.blocks = try FlowText.replacing(base: [], in: current.blocks,
                with: version.text ?? "", stamp: localStamp(in: current), deviceID: deviceID)
            _ = try store.savePage(current)
            if dirty.isEmpty { try reload() }
        } catch { self.error = error.localizedDescription }
    }

    private func reload() throws {
        guard let store else { return }
        let loaded = try store.loadPage(notebookId: notebookID, pageId: pageID)
        page = loaded
        parts = FlowText.sections(in: loaded.blocks).map { Part(id: $0.id, blocks: $0.blocks, source: $0.source) }
        if parts.last?.isMarkdown != true { parts.append(Part(id: "new-\(pageID)", blocks: [], source: "")) }
        refreshVersions()
    }

    private func localStamp(in page: PageFile) -> String {
        let previous = FlowText.ordered(page.blocks).map(\.updatedAt)
            .max { CouchMerge.millis($0) < CouchMerge.millis($1) } ?? page.updatedAt
        return SyncClock.shared.stamp(after: previous)
    }

    private func refreshVersions() {
        versions = (page?.blocks ?? []).filter { $0.kind == TextVersions.kind }.sorted { $0.updatedAt > $1.updatedAt }
    }

    private var draftURL: URL {
        store!.rootURL.appendingPathComponent("local-flow-drafts").appendingPathComponent(notebookID).appendingPathComponent("\(pageID).json")
    }
    private func writeDraft() throws {
        guard store != nil else { return }
        let pending = parts.filter { dirty.contains($0.id) }.map { Draft(id: $0.id, blocks: $0.blocks, source: $0.source, pending: $0.pending) }
        if pending.isEmpty { if FileManager.default.fileExists(atPath: draftURL.path) { try FileManager.default.removeItem(at: draftURL) }; return }
        try FileManager.default.createDirectory(at: draftURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(pending).write(to: draftURL, options: .atomic)
    }
}
