import NotableKit
import SwiftUI

/// The library: a sidebar for folder navigation on the left, the card grid for the
/// selected folder on the right. Selecting a folder — in the sidebar or by tapping a
/// folder row — moves the same selection, so the two columns never disagree.
///
/// Two plain columns rather than a `NavigationSplitView`: the system one draws its
/// sidebar as a floating panel with rounded corners, and this design has neither.
struct LibraryView: View {
    @EnvironmentObject private var store: NotebookStore
    @EnvironmentObject private var coordinator: SyncCoordinator
    @EnvironmentObject private var backendHost: SyncBackendHost
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var selection: LibrarySelection? = .root
    @State private var showsSidebar: Bool?
    @State private var openNotebook: OpenNotebook?

    /// Identifiable wrapper so the editor can be driven by `fullScreenCover(item:)`.
    struct OpenNotebook: Identifiable, Hashable {
        let id: String
    }

    /// Open on a wide screen, closed when there is only room for one column.
    private var sidebarVisible: Bool {
        showsSidebar ?? (horizontalSizeClass != .compact)
    }

    var body: some View {
        HStack(spacing: 0) {
            if sidebarVisible {
                LibrarySidebar(selection: $selection)
                    .frame(width: horizontalSizeClass == .compact ? nil : 300)
                    .overlay(alignment: .trailing) {
                        Rectangle()
                            .fill(Modernist.ink)
                            .frame(width: Modernist.ruleHeavy)
                    }
            }
            if horizontalSizeClass != .compact || !sidebarVisible {
                FolderContentsView(
                    folderId: selection?.folderId,
                    selection: $selection,
                    toggleSidebar: { showsSidebar = !sidebarVisible },
                    openNotebook: { openNotebook = OpenNotebook(id: $0) })
            }
        }
        .background(Modernist.paper)
        // Picking a folder on a one-column screen means "show me that folder".
        .onChange(of: selection) { _, _ in
            if horizontalSizeClass == .compact { showsSidebar = false }
        }
        // The editor is presented, not pushed: presenting gives the canvas the whole
        // screen, which is what you want when you are writing.
        // While a notebook is open the editor, not the disk, holds the truth about it — so sync
        // may push it but must never write to it. Cleared on dismiss, which is also when
        // EditorView's onDisappear has just flushed, so the next run reconciles it for real.
        .onChange(of: openNotebook) { previous, target in
            coordinator.openNotebookId = target?.id
            // Closing lifts the exclusion, so sync straight away rather than leaving whatever the
            // BOOX changed sitting until the next poll. Waiting for the edit-driven push would
            // only cover the case where you actually drew something.
            if previous != nil, target == nil {
                // Through the host, not the coordinator: it is the one thing that knows which
                // backend is selected, so this cannot run a WebDAV sync under CouchDB.
                Task { await backendHost.syncIfAutomatic() }
            }
        }
        // No navigation stack around it: the editor draws its own docked top bar, and a
        // system bar over it would be a second row of chrome saying the same things.
        .fullScreenCover(item: $openNotebook) { target in
            EditorView(notebookId: target.id, onClose: { openNotebook = nil })
                .environmentObject(store)
        }
    }
}

/// One level of the folder hierarchy: subfolders first, then the notebooks at this level.
/// `folderId == nil` is the library root.
private struct FolderContentsView: View {
    @EnvironmentObject private var store: NotebookStore
    @EnvironmentObject private var handwriting: HandwritingSettings
    @EnvironmentObject private var coordinator: SyncCoordinator
    @EnvironmentObject private var backendHost: SyncBackendHost
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    let folderId: String?
    @Binding var selection: LibrarySelection?
    let toggleSidebar: () -> Void
    let openNotebook: (String) -> Void

    @State private var showingNewNotebook = false
    @State private var newNotebookTitle = ""
    @State private var showingNewFolder = false
    @State private var newFolderTitle = ""

    @State private var renamingNotebookId: String?
    @State private var showingRenameNotebook = false
    @State private var renamingFolderId: String?
    @State private var showingRenameFolder = false
    @State private var renameTitle = ""

    @State private var deletingNotebookId: String?
    @State private var showingDeleteNotebook = false
    @State private var showingSyncSettings = false
    @State private var resolvingConflict: NotebookConflict?

    private var subfolders: [FolderDTO] { store.folders(in: folderId) }
    private var notebooks: [NotebookManifest] { store.notebooks(in: folderId) }

    private var title: String {
        folderId.flatMap { store.folder(id: $0)?.title } ?? "All Notes"
    }

    /// The design's one-handed layout: notebooks become a list of cover chips rather than
    /// a grid, so a title never truncates to fit a column.
    private var isCompact: Bool { horizontalSizeClass == .compact }

    var body: some View {
        VStack(spacing: 0) {
            header
            if subfolders.isEmpty && notebooks.isEmpty {
                emptyState
            } else {
                contents
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Modernist.paper)
        // Presented rather than pushed, for the same reason as the editor.
        .sheet(isPresented: $showingSyncSettings) {
            NavigationStack {
                SettingsView(backendHost: backendHost)
            }
        }
        .sheet(item: $resolvingConflict) { conflict in
            ConflictResolutionView(conflict: conflict)
        }
        .alert("New notebook", isPresented: $showingNewNotebook) {
            TextField("Title", text: $newNotebookTitle)
            Button("Create") {
                let title = newNotebookTitle.trimmingCharacters(in: .whitespaces)
                _ = try? store.createNotebook(
                    title: title.isEmpty ? "Untitled" : title, parentFolderId: folderId,
                    template: handwriting.config.defaultTemplate)
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("New folder", isPresented: $showingNewFolder) {
            TextField("Name", text: $newFolderTitle)
            Button("Create") {
                let title = newFolderTitle.trimmingCharacters(in: .whitespaces)
                _ = try? store.createFolder(
                    title: title.isEmpty ? "Untitled" : title, parentFolderId: folderId)
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename notebook", isPresented: $showingRenameNotebook) {
            TextField("Title", text: $renameTitle)
            Button("Rename") {
                let title = renameTitle.trimmingCharacters(in: .whitespaces)
                if let id = renamingNotebookId, !title.isEmpty {
                    try? store.renameNotebook(id: id, title: title)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename folder", isPresented: $showingRenameFolder) {
            TextField("Name", text: $renameTitle)
            Button("Rename") {
                let title = renameTitle.trimmingCharacters(in: .whitespaces)
                if let id = renamingFolderId, !title.isEmpty {
                    try? store.renameFolder(id: id, title: title)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Delete this notebook?", isPresented: $showingDeleteNotebook, titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let id = deletingNotebookId {
                    // Recorded before the files go, and persisted, so the tombstone still gets
                    // pushed if this happened offline or the app is killed before the next sync.
                    backendHost.noteDeleted(notebookId: id)
                    try? store.deleteNotebook(id: id)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The notebook is removed from this iPad and deleted from the server on the next sync.")
        }
        .onAppear { store.refresh() }
    }

    // MARK: Header

    /// Kicker, display title and the screen's actions, closed by a heavy rule — the
    /// design's masthead. One solid action per screen (new notebook); everything else is
    /// outlined.
    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Kicker(folderId == nil ? "Library" : "Folder")
                    Text(title)
                        .font(Modernist.display(30))
                        .tracking(Modernist.displayTracking(30))
                        .foregroundStyle(Modernist.ink)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Button {
                    toggleSidebar()
                } label: {
                    Image(systemName: "sidebar.leading").font(.system(size: 19, weight: .medium))
                }
                .buttonStyle(.squareOutline)
                .accessibilityLabel("Toggle folders")
                .accessibilityIdentifier("library.toggleSidebar")

                Button {
                    showingSyncSettings = true
                } label: {
                    Image(systemName: "gearshape").font(.system(size: 19, weight: .medium))
                }
                .buttonStyle(.squareOutline)
                .accessibilityLabel("Settings")
                .accessibilityIdentifier("library.settings")

                Button {
                    newFolderTitle = ""
                    showingNewFolder = true
                } label: {
                    Image(systemName: "folder.badge.plus").font(.system(size: 19, weight: .medium))
                }
                .buttonStyle(.squareOutline)
                .accessibilityLabel("New folder")
                .accessibilityIdentifier("library.addFolder")

                Button {
                    newNotebookTitle = ""
                    showingNewNotebook = true
                } label: {
                    Image(systemName: "plus").font(.system(size: 22, weight: .bold))
                }
                .buttonStyle(.squareSolid)
                .accessibilityLabel("New notebook")
                .accessibilityIdentifier("library.add")
            }
            ModernistRule(heavy: true)
        }
        .padding(.horizontal, 22)
        .padding(.top, 8)
    }

    @ViewBuilder
    private var emptyState: some View {
        Group {
            if folderId == nil {
                ContentUnavailableView(
                    "No notebooks yet", systemImage: "pencil.and.scribble",
                    description: Text("Create a notebook, or sync from your BOOX."))
            } else {
                ContentUnavailableView(
                    "Empty folder", systemImage: "folder",
                    description: Text("Create a notebook or folder here with the buttons above."))
            }
        }
        .frame(maxHeight: .infinity)
    }

    /// Folders as full-width rows, notebooks as covers — the design's two blocks, each
    /// under its own kicker and heavy rule.
    private var contents: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if !subfolders.isEmpty {
                    SectionHeading("Folders")
                        .padding(.bottom, 10)
                    // Rows stack flush so their hairlines read as one ruled column;
                    // the gap belongs under the block, not under each row.
                    VStack(spacing: 0) {
                        ForEach(subfolders, id: \.id) { folder in
                            folderRow(folder)
                        }
                    }
                    .padding(.bottom, 22)
                }
                if !notebooks.isEmpty {
                    SectionHeading("Notebooks")
                        .padding(.bottom, isCompact ? 4 : 14)
                    if isCompact {
                        VStack(spacing: 0) {
                            ForEach(notebooks, id: \.notebookId) { notebook in
                                notebookRow(notebook)
                            }
                        }
                    } else {
                        LazyVGrid(
                            columns: [
                                GridItem(
                                    .adaptive(minimum: 170, maximum: 250), spacing: 14,
                                    alignment: .top)
                            ],
                            alignment: .leading, spacing: 20
                        ) {
                            ForEach(notebooks, id: \.notebookId) { notebook in
                                notebookCard(notebook)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 16)
            .padding(.bottom, 40)
        }
    }

    // MARK: Rows and cards

    /// Opening a subfolder moves the sidebar selection rather than pushing, so the two
    /// columns can never disagree about where the user is.
    private func folderRow(_ folder: FolderDTO) -> some View {
        Button {
            selection = .folder(folder.id)
        } label: {
            HStack(spacing: 12) {
                Rectangle()
                    .fill(Modernist.fill(for: folder.id))
                    .frame(width: 22, height: 22)
                Text(folder.title)
                    .font(Modernist.font(15, .semibold))
                    .foregroundStyle(Modernist.ink)
                    .lineLimit(1)
                Spacer(minLength: 8)
                ProvenanceBadge(provenance: store.provenance(ofFolder: folder.id), size: 12)
                Text("\(store.itemCount(in: folder.id))")
                    .font(Modernist.font(11).monospacedDigit())
                    .foregroundStyle(Modernist.neutral700)
                    .accessibilityLabel("\(store.itemCount(in: folder.id)) items")
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Modernist.neutral600)
            }
            .frame(height: Modernist.hit)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) { ModernistRule() }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                renamingFolderId = folder.id
                renameTitle = folder.title
                showingRenameFolder = true
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            if store.isFolderEmpty(folder.id) {
                Button(role: .destructive) {
                    try? store.deleteFolder(id: folder.id)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    /// One-handed variant: the covers shrink to chips and the grid becomes a list, so a
    /// title never has to truncate to fit a column.
    private func notebookRow(_ notebook: NotebookManifest) -> some View {
        Button {
            open(notebook)
        } label: {
            HStack(spacing: 12) {
                cover(for: notebook)
                    .frame(width: 34, height: 46)
                VStack(alignment: .leading, spacing: 1) {
                    Text(notebook.title)
                        .font(Modernist.font(14, .bold))
                        .foregroundStyle(Modernist.ink)
                        .lineLimit(1)
                    Text("\(notebook.pageIds.count) p · \(notebookSubtitle(notebook))")
                        .font(Modernist.font(10))
                        .foregroundStyle(Modernist.neutral700)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Modernist.neutral600)
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) { ModernistRule() }
        }
        .buttonStyle(.plain)
        .contextMenu { notebookMenu(notebook) }
    }

    /// A conflicted notebook opens the chooser, not the editor — editing a copy whose fate
    /// is undecided would just add a third version. Notable does the same on the BOOX.
    private func open(_ notebook: NotebookManifest) {
        if let conflict = coordinator.conflict(for: notebook.notebookId) {
            resolvingConflict = conflict
        } else {
            openNotebook(notebook.notebookId)
        }
    }

    private func notebookCard(_ notebook: NotebookManifest) -> some View {
        Button {
            open(notebook)
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                cover(for: notebook)
                Text(notebook.title)
                    .font(Modernist.font(13, .semibold))
                    .foregroundStyle(Modernist.ink)
                    .lineLimit(1)
                Text(notebookSubtitle(notebook))
                    .font(Modernist.font(10))
                    .foregroundStyle(Modernist.neutral700)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .contextMenu { notebookMenu(notebook) }
    }

    /// Shared by the card and the row: same actions whichever way the notebook is drawn.
    @ViewBuilder
    private func notebookMenu(_ notebook: NotebookManifest) -> some View {
        Button {
            renamingNotebookId = notebook.notebookId
            renameTitle = notebook.title
            showingRenameNotebook = true
        } label: {
            Label("Rename", systemImage: "pencil")
        }
        Menu {
            Button("No folder") {
                try? store.moveNotebook(id: notebook.notebookId, toFolder: nil)
            }
            ForEach(store.folders, id: \.id) { folder in
                Button(folder.title) {
                    try? store.moveNotebook(id: notebook.notebookId, toFolder: folder.id)
                }
            }
        } label: {
            Label("Move to folder", systemImage: "folder")
        }
        Button(role: .destructive) {
            deletingNotebookId = notebook.notebookId
            showingDeleteNotebook = true
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    /// Nothing floats in this system, so the cover has an edge rather than a shadow.
    private func cover(for notebook: NotebookManifest) -> some View {
        NotebookCoverView(
            seed: notebook.notebookId,
            title: notebook.title,
            pageCount: notebook.pageIds.count,
            thumbnail: ThumbnailRenderer.thumbnail(for: notebook, store: store)
        )
        .overlay(alignment: .topTrailing) {
            if coordinator.conflict(for: notebook.notebookId) != nil {
                ConflictCoverBadge()
            } else {
                ProvenanceCoverBadge(
                    provenance: store.provenance(ofNotebook: notebook.notebookId))
            }
        }
    }

    // MARK: Subtitles

    /// Just the edit time: the page count is set into the cover itself.
    private func notebookSubtitle(_ notebook: NotebookManifest) -> String {
        NotableDate.parse(notebook.updatedAt)
            .map { $0.formatted(.relative(presentation: .named)) } ?? notebook.updatedAt
    }
}
