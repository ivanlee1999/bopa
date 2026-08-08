import Foundation
import NotableKit

/// Local notebook repository. Mirrors Notable's server layout on disk
/// (`Documents/notable/notebooks/<id>/manifest.json` + `pages/<pageId>.json`) so that the
/// M3 sync engine reduces to reconciling this directory with the WebDAV `/notable` tree.
@MainActor
final class NotebookStore: ObservableObject {
    @Published private(set) var notebooks: [NotebookManifest] = []

    let rootURL: URL

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.withoutEscapingSlashes]
        return e
    }()
    private let decoder = JSONDecoder()

    init(rootURL: URL? = nil) {
        self.rootURL = rootURL
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("notable", isDirectory: true)
        refresh()
    }

    private func notebookDir(_ id: String) -> URL {
        rootURL.appendingPathComponent("notebooks/\(id)", isDirectory: true)
    }
    private func manifestURL(_ id: String) -> URL {
        notebookDir(id).appendingPathComponent("manifest.json")
    }
    private func pageURL(notebookId: String, pageId: String) -> URL {
        notebookDir(notebookId).appendingPathComponent("pages/\(pageId).json")
    }

    func refresh() {
        let notebooksDir = rootURL.appendingPathComponent("notebooks", isDirectory: true)
        let ids = (try? FileManager.default.contentsOfDirectory(atPath: notebooksDir.path)) ?? []
        notebooks = ids.compactMap { id in
            guard let data = try? Data(contentsOf: manifestURL(id)) else { return nil }
            return try? decoder.decode(NotebookManifest.self, from: data)
        }
        .sorted { ($0.updatedAt, $0.title) > ($1.updatedAt, $1.title) }
    }

    func createNotebook(title: String) throws -> NotebookManifest {
        let now = NotableDate.format(Date())
        let notebookId = UUID().uuidString.lowercased()
        let pageId = UUID().uuidString.lowercased()

        let page = PageFile(
            id: pageId, notebookId: notebookId,
            createdAt: now, updatedAt: now)
        let manifest = NotebookManifest(
            notebookId: notebookId, title: title, pageIds: [pageId], openPageId: pageId,
            createdAt: now, updatedAt: now, serverTimestamp: now)

        try FileManager.default.createDirectory(
            at: notebookDir(notebookId).appendingPathComponent("pages"),
            withIntermediateDirectories: true)
        try encoder.encode(page).write(to: pageURL(notebookId: notebookId, pageId: pageId))
        try writeManifest(manifest)
        refresh()
        return manifest
    }

    func manifest(id: String) -> NotebookManifest? {
        notebooks.first { $0.notebookId == id }
    }

    func loadPage(notebookId: String, pageId: String) throws -> PageFile {
        let data = try Data(contentsOf: pageURL(notebookId: notebookId, pageId: pageId))
        return try decoder.decode(PageFile.self, from: data)
    }

    /// Persists a page and bumps the notebook's `updatedAt` (the sync conflict clock).
    func savePage(_ page: PageFile) throws {
        guard let notebookId = page.notebookId, var manifest = manifest(id: notebookId) else {
            return
        }
        var page = page
        let now = NotableDate.format(Date())
        page.updatedAt = now
        try encoder.encode(page).write(to: pageURL(notebookId: notebookId, pageId: page.id))
        manifest.updatedAt = now
        try writeManifest(manifest)
        refresh()
    }

    func addPage(to notebookId: String) throws -> PageFile {
        guard var manifest = manifest(id: notebookId) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let now = NotableDate.format(Date())
        let page = PageFile(
            id: UUID().uuidString.lowercased(), notebookId: notebookId,
            createdAt: now, updatedAt: now)
        try encoder.encode(page).write(to: pageURL(notebookId: notebookId, pageId: page.id))
        manifest.pageIds.append(page.id)
        manifest.updatedAt = now
        try writeManifest(manifest)
        refresh()
        return page
    }

    private func writeManifest(_ manifest: NotebookManifest) throws {
        try FileManager.default.createDirectory(
            at: notebookDir(manifest.notebookId), withIntermediateDirectories: true)
        try encoder.encode(manifest).write(to: manifestURL(manifest.notebookId))
    }
}
