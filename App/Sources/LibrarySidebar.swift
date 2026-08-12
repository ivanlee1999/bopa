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

/// One node of the sidebar's library tree — a folder, or a notebook filed inside one — resolved
/// out of the store ahead of rendering so row bodies never have to walk it.
struct LibraryNode: Identifiable, Hashable {
    enum Kind: Hashable {
        case folder
        case notebook
    }

    let kind: Kind
    /// The folder id or the notebook id. Not the row identity: the two id spaces are
    /// independent, so `id` below namespaces them before the tree is diffed.
    let itemId: String
    let title: String
    /// Direct children for a folder, pages for a notebook — whichever number the row shows.
    let count: Int
    let provenance: SyncProvenance
    /// `nil` (not `[]`) for leaves — that is what suppresses the disclosure triangle.
    let children: [LibraryNode]?

    var id: String {
        switch kind {
        case .folder: return "folder:\(itemId)"
        case .notebook: return "notebook:\(itemId)"
        }
    }

    /// Builds the root-level nodes: the folder tree, each folder holding its subfolders and then
    /// its notebooks, followed by the notebooks that sit at the library root. A `parentFolderId`
    /// cycle (possible in a hand-edited or half-merged folders.json) is broken by tracking the ids
    /// already on the path.
    @MainActor
    static func tree(from store: NotebookStore) -> [LibraryNode] {
        func notebooks(in folderId: String?) -> [LibraryNode] {
            store.notebooks(in: folderId).map { notebook in
                LibraryNode(
                    kind: .notebook,
                    itemId: notebook.notebookId,
                    title: notebook.title,
                    count: notebook.pageIds.count,
                    provenance: store.provenance(ofNotebook: notebook.notebookId),
                    children: nil)
            }
        }
        func build(parent: String?, ancestors: Set<String>) -> [LibraryNode] {
            store.folders(in: parent).compactMap { folder in
                guard !ancestors.contains(folder.id) else { return nil }
                let children =
                    build(parent: folder.id, ancestors: ancestors.union([folder.id]))
                    + notebooks(in: folder.id)
                return LibraryNode(
                    kind: .folder,
                    itemId: folder.id,
                    title: folder.title,
                    count: store.itemCount(in: folder.id),
                    provenance: store.provenance(ofFolder: folder.id),
                    children: children.isEmpty ? nil : children)
            }
        }
        return build(parent: nil, ancestors: []) + notebooks(in: nil)
    }

    /// The tree as the flat row list the sidebar draws, depth carried alongside for indentation.
    ///
    /// Flattened here rather than drawn by a recursive view: `OutlineGroup` starts every node
    /// collapsed, and the point of this sidebar is that the folders and their notes are already
    /// on screen. `collapsed` therefore holds what the user has explicitly shut, so a folder that
    /// arrives from a sync shows its contents without being opened first.
    static func flattened(
        _ nodes: [LibraryNode], collapsed: Set<String>, depth: Int = 0
    ) -> [LibraryRow] {
        nodes.flatMap { node -> [LibraryRow] in
            let row = LibraryRow(node: node, depth: depth)
            guard let children = node.children, !collapsed.contains(node.id) else { return [row] }
            return [row] + flattened(children, collapsed: collapsed, depth: depth + 1)
        }
    }
}

/// A node placed at its depth in the flattened tree.
struct LibraryRow: Identifiable {
    let node: LibraryNode
    let depth: Int

    var id: String { node.id }
}

/// Left column of the library: the root item, then the whole library as a tree — every folder,
/// nested, with the notebooks filed in it underneath. Each row carries its count and a provenance
/// glyph (on server / local only); folders and notebooks can be renamed from their own row.
struct LibrarySidebar: View {
    @EnvironmentObject private var store: NotebookStore
    @EnvironmentObject private var backendHost: SyncBackendHost
    @Binding var selection: LibrarySelection?
    /// Tapping a note in the tree opens it, the same as tapping its cover in the grid.
    let openNotebook: (String) -> Void

    /// What the user has explicitly shut. Everything else is open — see `flattened`.
    @State private var collapsed: Set<String> = []
    @State private var renaming: RenameTarget?
    @State private var showingRename = false
    @State private var renameTitle = ""

    /// A local deletion that failed. Reported rather than swallowed: the row is still in the tree
    /// afterwards, and without this the user is left to conclude that Delete does nothing.
    @State private var deletionError: String?

    /// What a rename alert is pointed at. One alert serves both kinds, because at any moment
    /// only one row is being renamed.
    private enum RenameTarget: Hashable {
        case folder(String)
        case notebook(String)
    }

    var body: some View {
        VStack(spacing: 0) {
            masthead
            ScrollView {
                VStack(spacing: 0) {
                    rootRow

                    let tree = LibraryNode.tree(from: store)
                    if !tree.isEmpty {
                        SectionHeading("Library")
                            .padding(.horizontal, 20)
                            .padding(.top, 18)
                            .padding(.bottom, 4)
                        // Plain buttons rather than `List(selection:)`: outside a
                        // NavigationSplitView a list's single selection only responds in
                        // edit mode, and its highlight is a rounded system capsule.
                        ForEach(LibraryNode.flattened(tree, collapsed: collapsed)) { row in
                            treeRow(row)
                        }
                    }
                }
                .padding(.bottom, 16)
            }
            footer
        }
        .background(Modernist.paper)
        .tint(Modernist.ink)
        .alert(renameAlertTitle, isPresented: $showingRename) {
            TextField("Name", text: $renameTitle)
            // Disabled rather than a no-op: an alert closes whatever its button does, so a
            // blank name would otherwise dismiss and silently keep the old one.
            Button("Rename") { commitRename() }
                .disabled(trimmedRenameTitle.isEmpty)
            Button("Cancel", role: .cancel) {}
        }
        .alert("Couldn’t delete that", isPresented: deletionErrorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deletionError ?? "")
        }
    }

    private var deletionErrorBinding: Binding<Bool> {
        Binding(get: { deletionError != nil }, set: { if !$0 { deletionError = nil } })
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

    // MARK: Rows

    private var rootRow: some View {
        let selected = selection == .root
        return Button {
            selection = .root
        } label: {
            rowBody(
                title: "All Notes", systemImage: "tray.full", weight: .semibold,
                count: store.totalNotebookCount,
                countUnit: plural(store.totalNotebookCount, "notebook"),
                provenance: .unknown, selected: selected)
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? Modernist.paper : Modernist.ink)
        .padding(.horizontal, 20)
        .background(selected ? Modernist.ink : .clear)
        .accessibilityIdentifier("sidebar.allNotes")
    }

    @ViewBuilder
    private func treeRow(_ row: LibraryRow) -> some View {
        switch row.node.kind {
        case .folder: folderRow(row)
        case .notebook: notebookRow(row)
        }
    }

    /// A folder. The disclosure triangle is a sibling button rather than part of the row's own
    /// button — a button nested inside another button's label never sees a tap — so collapsing a
    /// folder and selecting it stay separate gestures on the same row.
    private func folderRow(_ row: LibraryRow) -> some View {
        let node = row.node
        let selected = selection == .folder(node.itemId)
        return HStack(spacing: 4) {
            disclosure(for: node)
            Button {
                selection = .folder(node.itemId)
            } label: {
                rowBody(
                    title: node.title, systemImage: "folder", weight: .semibold,
                    count: node.count, countUnit: plural(node.count, "item"),
                    provenance: node.provenance, selected: selected)
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(selected ? Modernist.paper : Modernist.ink)
        .padding(.leading, indent(row.depth))
        .padding(.trailing, 20)
        .background(selected ? Modernist.ink : .clear)
        .accessibilityIdentifier("sidebar.folder.\(node.itemId)")
        .contextMenu {
            Button {
                beginRename(.folder(node.itemId), current: node.title)
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            if store.isFolderEmpty(node.itemId) {
                Button(role: .destructive) {
                    if selection == .folder(node.itemId) { selection = .root }
                    // Reported rather than swallowed: the store records the CouchDB tombstone as
                    // part of a *successful* delete, so a failure here means the folder is still
                    // in the library and nothing has been promised to the server. Saying so is the
                    // difference between that and a Delete that silently does nothing.
                    do {
                        try store.deleteFolder(id: node.itemId)
                    } catch {
                        deletionError = error.localizedDescription
                    }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    /// A notebook, one step further in than the folder holding it. Never selected: tapping it
    /// opens the editor, so the sidebar's selection stays a statement about *where* you are.
    private func notebookRow(_ row: LibraryRow) -> some View {
        let node = row.node
        return HStack(spacing: 4) {
            Spacer().frame(width: disclosureWidth)
            Button {
                openNotebook(node.itemId)
            } label: {
                rowBody(
                    title: node.title, systemImage: "doc.text", weight: .regular,
                    count: node.count, countUnit: plural(node.count, "page"),
                    provenance: node.provenance, selected: false)
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(Modernist.ink)
        .padding(.leading, indent(row.depth))
        .padding(.trailing, 20)
        .accessibilityIdentifier("sidebar.notebook.\(node.itemId)")
        .contextMenu {
            Button {
                beginRename(.notebook(node.itemId), current: node.title)
            } label: {
                Label("Rename", systemImage: "pencil")
            }
        }
    }

    /// The count on a row is read out with its unit, so it has to agree with it: "1 item",
    /// not "1 items".
    private func plural(_ count: Int, _ singular: String) -> String {
        count == 1 ? singular : singular + "s"
    }

    /// Shared row interior, so a folder, a note and the root item line up on the same grid.
    private func rowBody(
        title: String, systemImage: String, weight: Font.Weight, count: Int, countUnit: String,
        provenance: SyncProvenance, selected: Bool
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 14))
                .frame(width: 18)
            Text(title)
                .font(Modernist.font(14, weight))
                .lineLimit(1)
            Spacer(minLength: 4)
            ProvenanceBadge(
                provenance: provenance, size: 11,
                color: selected ? Modernist.paper : nil)
            Text("\(count)")
                .font(Modernist.font(11).monospacedDigit())
                .accessibilityLabel("\(count) \(countUnit)")
        }
        .frame(height: 40)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func disclosure(for node: LibraryNode) -> some View {
        if node.children != nil {
            let shut = collapsed.contains(node.id)
            Button {
                if shut {
                    collapsed.remove(node.id)
                } else {
                    collapsed.insert(node.id)
                }
            } label: {
                Image(systemName: shut ? "chevron.right" : "chevron.down")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: disclosureWidth, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(shut ? "Expand \(node.title)" : "Collapse \(node.title)")
        } else {
            Spacer().frame(width: disclosureWidth)
        }
    }

    private let disclosureWidth: CGFloat = 18

    /// The triangle sits in the 20pt gutter the rest of the panel keeps clear, so the tree's
    /// glyph column stays put whether or not a row can be opened. It is inset by enough that it
    /// still reads as inside the panel rather than clipped to its edge.
    private func indent(_ depth: Int) -> CGFloat {
        10 + CGFloat(depth) * 16
    }

    // MARK: Renaming

    private var renameAlertTitle: String {
        if case .notebook = renaming { return "Rename notebook" }
        return "Rename folder"
    }

    private func beginRename(_ target: RenameTarget, current: String) {
        renaming = target
        renameTitle = current
        showingRename = true
    }

    private var trimmedRenameTitle: String {
        renameTitle.trimmingCharacters(in: .whitespaces)
    }

    private func commitRename() {
        let title = trimmedRenameTitle
        guard !title.isEmpty, let renaming else { return }
        switch renaming {
        case .folder(let id): try? store.renameFolder(id: id, title: title)
        case .notebook(let id): try? store.renameNotebook(id: id, title: title)
        }
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
