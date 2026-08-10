import NotableKit
import SwiftUI

/// Which node of the library the sidebar has selected. `root` is the library root;
/// `server` is the WebDAV share itself rather than anything in the local library.
enum LibrarySelection: Hashable {
    case root
    case server
    case folder(String)

    var folderId: String? {
        if case .folder(let id) = self { return id }
        return nil
    }
}

/// One node of the sidebar's folder tree, resolved out of `folders.json` ahead of
/// rendering so row bodies never have to walk the store.
struct FolderNode: Identifiable, Hashable {
    let id: String
    let title: String
    let itemCount: Int
    let provenance: SyncProvenance
    /// `nil` (not `[]`) for leaves — that is what suppresses the disclosure triangle.
    var children: [FolderNode]?

    /// Builds the root-level nodes. A `parentFolderId` cycle (possible in a hand-edited or
    /// half-merged folders.json) is broken by tracking the ids already on the path.
    @MainActor
    static func tree(from store: NotebookStore) -> [FolderNode] {
        func build(parent: String?, ancestors: Set<String>) -> [FolderNode] {
            store.folders(in: parent).compactMap { folder in
                guard !ancestors.contains(folder.id) else { return nil }
                let children = build(
                    parent: folder.id, ancestors: ancestors.union([folder.id]))
                return FolderNode(
                    id: folder.id,
                    title: folder.title,
                    itemCount: store.itemCount(in: folder.id),
                    provenance: store.provenance(ofFolder: folder.id),
                    children: children.isEmpty ? nil : children)
            }
        }
        return build(parent: nil, ancestors: [])
    }
}

/// Left column of the library: the root item, then the nesting folder tree. Each row
/// carries its item count and a provenance glyph (on server / local only).
struct LibrarySidebar: View {
    @EnvironmentObject private var store: NotebookStore
    @Binding var selection: LibrarySelection?

    /// Only for the row's subtitle — the browser itself re-reads the settings when it opens.
    @State private var settings = SyncSettings.load()

    var body: some View {
        List(selection: $selection) {
            Section {
                row(
                    title: "All Notes", systemImage: "tray.full",
                    count: store.totalNotebookCount, provenance: .unknown)
                    .tag(LibrarySelection.root)
                    .accessibilityIdentifier("sidebar.allNotes")
                serverRow
                    .tag(LibrarySelection.server)
                    .accessibilityIdentifier("sidebar.server")
            }

            let tree = FolderNode.tree(from: store)
            if !tree.isEmpty {
                Section("Folders") {
                    OutlineGroup(tree, children: \.children) { node in
                        row(
                            title: node.title, systemImage: "folder",
                            count: node.itemCount, provenance: node.provenance)
                            .tag(LibrarySelection.folder(node.id))
                    }
                }
            }

            if store.hasSyncedAtLeastOnce {
                legend
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("bopa")
        .onAppear { settings = SyncSettings.load() }
        .onReceive(NotificationCenter.default.publisher(for: SyncSettings.didChangeNotification)) { _ in
            settings = SyncSettings.load()
        }
    }

    /// Opens the WebDAV share itself. The right-hand text is the folder sync is pointed at,
    /// which is the first thing to check when the library looks emptier than the server.
    private var serverRow: some View {
        HStack(spacing: 8) {
            Label("Server", systemImage: "externaldrive.connected.to.line.below")
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(settings.remotePathDisplay)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
        }
    }

    private func row(
        title: String, systemImage: String, count: Int, provenance: SyncProvenance
    ) -> some View {
        HStack(spacing: 8) {
            Label(title, systemImage: systemImage)
                .lineLimit(1)
            Spacer(minLength: 4)
            ProvenanceBadge(provenance: provenance, size: 11)
            Text("\(count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityLabel("\(count) items")
        }
    }

    /// Two lines, only once a sync has happened — otherwise there are no glyphs to explain.
    /// Headed "Key" because unlabelled it reads as two more rows to tap, and it is inert.
    private var legend: some View {
        Section("Key") {
            legendRow(.onServer, text: "On server")
            legendRow(.localOnly, text: "Local only")
        }
        .selectionDisabled()
    }

    private func legendRow(_ provenance: SyncProvenance, text: String) -> some View {
        HStack(spacing: 8) {
            ProvenanceBadge(provenance: provenance, size: 11)
                .accessibilityHidden(true)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
