import NotableKit
import SwiftUI

/// Which node of the library the sidebar has selected. `root` is the library root.
///
/// There is deliberately no "server" node: a synced WebDAV folder is not a place of its own, it is
/// where these folders and notes came from. Its contents appear below like any other.
enum LibrarySelection: Hashable {
    case root
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

    var body: some View {
        List(selection: $selection) {
            Section {
                row(
                    title: "All Notes", systemImage: "tray.full",
                    count: store.totalNotebookCount, provenance: .unknown)
                    .tag(LibrarySelection.root)
                    .accessibilityIdentifier("sidebar.allNotes")
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

        }
        .listStyle(.sidebar)
        .navigationTitle("bopa")
        // Outside the List, not a Section in it. As rows — even selection-disabled ones, even under
        // a "Key" header — these read as two more things to tap, and tapping them does nothing.
        .safeAreaInset(edge: .bottom) {
            if store.hasSyncedAtLeastOnce {
                legend
            }
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

    /// What the badges on rows and covers mean. Only once a sync has happened — before that there
    /// are no glyphs to explain.
    private var legend: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            legendRow(.onServer, text: "On server")
            legendRow(.localOnly, text: "Local only")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
        .padding(.top, 4)
        .background(.bar)
        .accessibilityElement(children: .combine)
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
