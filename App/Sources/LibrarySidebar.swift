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
    @EnvironmentObject private var backendHost: SyncBackendHost
    @Binding var selection: LibrarySelection?

    var body: some View {
        VStack(spacing: 0) {
            masthead
            ScrollView {
                VStack(spacing: 0) {
                    row(
                        tag: .root, title: "All Notes", systemImage: "tray.full",
                        count: store.totalNotebookCount, provenance: .unknown)
                        .accessibilityIdentifier("sidebar.allNotes")

                    let tree = FolderNode.tree(from: store)
                    if !tree.isEmpty {
                        SectionHeading("Folders")
                            .padding(.horizontal, 20)
                            .padding(.top, 18)
                            .padding(.bottom, 4)
                        // Plain buttons rather than `List(selection:)`: outside a
                        // NavigationSplitView a list's single selection only responds in
                        // edit mode, and its highlight is a rounded system capsule.
                        OutlineGroup(tree, children: \.children) { node in
                            row(
                                tag: .folder(node.id), title: node.title,
                                systemImage: "folder",
                                count: node.itemCount, provenance: node.provenance)
                        }
                    }
                }
                .padding(.bottom, 16)
            }
            footer
        }
        .background(Modernist.paper)
        .tint(Modernist.ink)
    }

    /// The wordmark, on the design's status strip: a label and a rule, nothing else.
    private var masthead: some View {
        VStack(alignment: .leading, spacing: 5) {
            Kicker("bopa", color: Modernist.ink)
            ModernistRule(heavy: true)
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(Modernist.paper)
    }

    private func row(
        tag: LibrarySelection, title: String, systemImage: String, count: Int,
        provenance: SyncProvenance
    ) -> some View {
        let selected = selection == tag
        return Button {
            selection = tag
        } label: {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 14))
                    .frame(width: 18)
                Text(title)
                    .font(Modernist.font(14, .semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                ProvenanceBadge(
                    provenance: provenance, size: 11,
                    color: selected ? Modernist.paper : nil)
                Text("\(count)")
                    .font(Modernist.font(11).monospacedDigit())
                    .accessibilityLabel("\(count) items")
            }
            .foregroundStyle(selected ? Modernist.paper : Modernist.ink)
            .padding(.horizontal, 20)
            .frame(height: 40)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Modernist.ink : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Pinned under the tree: the sync control, then what the badges mean.
    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            ModernistRule(heavy: true)
            syncControl
            if store.hasSyncedAtLeastOnce {
                legend
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .padding(.bottom, 10)
        .background(Modernist.paper)
    }

    /// Manual sync, next to the tree it refreshes rather than buried in the settings sheet.
    /// `syncNow` is the same call that sheet makes: it bails on its own if a run is already in
    /// flight, so a double tap costs nothing. Routed through the host so the button drives
    /// whichever backend is selected — and does nothing at all when sync is off.
    private var syncControl: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                Task { await backendHost.syncNow() }
            } label: {
                HStack(spacing: 6) {
                    if backendHost.isSyncing {
                        ProgressView()
                            .controlSize(.small)
                        Text("Syncing…")
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                        Text("Sync now")
                    }
                    // Flush left, per the system: a button wider than its label starts the
                    // text at the left padding edge rather than centring it.
                    Spacer(minLength: 0)
                }
                .font(Modernist.font(13, .bold))
                .padding(.horizontal, 10)
                .frame(height: 36)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(Rectangle().stroke(Modernist.ink, lineWidth: Modernist.ruleHair))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(backendHost.canSyncNow ? Modernist.ink : Modernist.neutral500)
            .disabled(!backendHost.canSyncNow || backendHost.isSyncing)
            .accessibilityIdentifier("sidebar.syncNow")

            // The status capsule fades after ~3s, so the outcome of the last run would otherwise be
            // gone by the time you look for it. An unconfigured server explains the dead button.
            if let detail = syncDetail {
                Text(detail)
                    .font(Modernist.font(11))
                    .foregroundStyle(Modernist.neutral700)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var syncDetail: String? {
        if let reason = backendHost.unavailableReason { return reason }
        // The button already says "Syncing…"; repeating it under itself says nothing.
        return backendHost.isSyncing ? nil : backendHost.statusDetail
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
                .font(Modernist.font(11))
                .foregroundStyle(Modernist.neutral700)
        }
    }
}
