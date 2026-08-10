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
    @EnvironmentObject private var coordinator: SyncCoordinator
    @Binding var selection: LibrarySelection?

    /// Cached rather than read per render: `SyncSettings.load()` touches the Keychain. Refreshed on
    /// the settings notification, since the form saves in its own `onDisappear`.
    @State private var serverConfigured = SyncSettings.isServerConfigured

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
        // Outside the List, not Sections in it. The legend rows are not tappable, and a real
        // control sitting among selectable folder rows would be selectable too — the footer is
        // where both belong.
        .safeAreaInset(edge: .bottom) {
            footer
        }
        .onReceive(NotificationCenter.default.publisher(
            for: SyncSettings.didChangeNotification)
        ) { _ in
            serverConfigured = SyncSettings.isServerConfigured
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

    /// Pinned under the tree: the sync control, then what the badges mean.
    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            syncControl
            if store.hasSyncedAtLeastOnce {
                legend
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .padding(.bottom, 10)
        .background(.bar)
    }

    /// Manual sync, next to the tree it refreshes rather than buried in the settings sheet.
    /// `syncNow` is the same call that sheet makes: it bails on its own if a run is already in
    /// flight, so a double tap costs nothing.
    private var syncControl: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                Task { await coordinator.syncNow(store: store) }
            } label: {
                HStack(spacing: 6) {
                    if coordinator.isSyncing {
                        ProgressView()
                            .controlSize(.small)
                        Text("Syncing…")
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                        Text("Sync now")
                    }
                }
                .font(.subheadline.weight(.medium))
            }
            .disabled(!serverConfigured || coordinator.isSyncing)
            .accessibilityIdentifier("sidebar.syncNow")

            // The status capsule fades after ~3s, so the outcome of the last run would otherwise be
            // gone by the time you look for it. An unconfigured server explains the dead button.
            if let detail = syncDetail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var syncDetail: String? {
        guard serverConfigured else { return "Add a server in Settings to sync." }
        // The button already says "Syncing…"; repeating it under itself says nothing.
        return coordinator.isSyncing ? nil : coordinator.statusDetail
    }

    /// What the badges on rows and covers mean. Only once a sync has happened — before that there
    /// are no glyphs to explain.
    private var legend: some View {
        VStack(alignment: .leading, spacing: 4) {
            legendRow(.onServer, text: "On server")
            legendRow(.localOnly, text: "Local only")
        }
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
