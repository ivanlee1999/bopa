import NotableKit
import SwiftUI

/// The library: a sidebar for folder navigation on the left, the card grid for the
/// selected folder on the right. Selecting a folder — in the sidebar or by tapping a
/// folder card — moves the same selection, so the two columns never disagree.
struct LibraryView: View {
    @EnvironmentObject private var store: NotebookStore
    @EnvironmentObject private var coordinator: SyncCoordinator
    @State private var selection: LibrarySelection? = .root
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var openNotebook: OpenNotebook?

    /// Identifiable wrapper so the editor can be driven by `fullScreenCover(item:)`.
    struct OpenNotebook: Identifiable, Hashable {
        let id: String
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            LibrarySidebar(selection: $selection)
        } detail: {
            FolderContentsView(
                folderId: selection?.folderId,
                selection: $selection,
                openNotebook: { openNotebook = OpenNotebook(id: $0) })
        }
        .navigationSplitViewStyle(.balanced)
        // The editor is presented, not pushed: this view lives inside the app's
        // NavigationStack, and a stack nested in a split-view column swallows its pushes.
        // Presenting also gives the canvas the whole screen, which is what you want when
        // you are writing.
        // While a notebook is open the editor, not the disk, holds the truth about it — so sync
        // may push it but must never write to it. Cleared on dismiss, which is also when
        // EditorView's onDisappear has just flushed, so the next run reconciles it for real.
        .onChange(of: openNotebook) { previous, target in
            coordinator.openNotebookId = target?.id
            // Closing lifts the exclusion, so sync straight away rather than leaving whatever the
            // BOOX changed sitting until the next poll. Waiting for the edit-driven push would
            // only cover the case where you actually drew something.
            if previous != nil, target == nil {
                Task { await coordinator.syncIfAutomatic(store: store) }
            }
        }
        .fullScreenCover(item: $openNotebook) { target in
            NavigationStack {
                EditorView(notebookId: target.id)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button {
                                openNotebook = nil
                            } label: {
                                Label("Library", systemImage: "chevron.backward")
                            }
                            .accessibilityIdentifier("editor.close")
                        }
                    }
            }
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
    let folderId: String?
    @Binding var selection: LibrarySelection?
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

    var body: some View {
        Group {
            if subfolders.isEmpty && notebooks.isEmpty {
                if folderId == nil {
                    ContentUnavailableView(
                        "No notebooks yet", systemImage: "pencil.and.scribble",
                        description: Text("Create a notebook, or sync from your BOOX."))
                } else {
                    ContentUnavailableView(
                        "Empty folder", systemImage: "folder",
                        description: Text("Create a notebook or folder here with the toolbar."))
                }
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 190, maximum: 250), spacing: 20, alignment: .top)],
                        alignment: .leading, spacing: 24
                    ) {
                        ForEach(subfolders, id: \.id) { folder in
                            folderCard(folder)
                        }
                        ForEach(notebooks, id: \.notebookId) { notebook in
                            notebookCard(notebook)
                        }
                    }
                    .padding(20)
                }
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(folderId.flatMap { store.folder(id: $0)?.title } ?? "All Notes")
        .toolbar {
            Button {
                showingSyncSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
            .accessibilityIdentifier("library.settings")
            Button {
                newFolderTitle = ""
                showingNewFolder = true
            } label: {
                Image(systemName: "folder.badge.plus")
            }
            .accessibilityIdentifier("library.addFolder")
            Button {
                newNotebookTitle = ""
                showingNewNotebook = true
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityIdentifier("library.add")
        }
        // Presented rather than pushed, for the same reason as the editor.
        .sheet(isPresented: $showingSyncSettings) {
            NavigationStack {
                SettingsView()
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
                    try? store.deleteNotebook(id: id)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The notebook is removed from this iPad and deleted from the server on the next sync.")
        }
        .onAppear { store.refresh() }
    }

    // MARK: Cards

    /// Opening a subfolder moves the sidebar selection rather than pushing, so the two
    /// columns can never disagree about where the user is.
    private func folderCard(_ folder: FolderDTO) -> some View {
        Button {
            selection = .folder(folder.id)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
                    .overlay {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(.tint.opacity(0.8))
                    }
                    .aspectRatio(3.0 / 4.0, contentMode: .fit)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.06)))
                    .overlay(alignment: .topTrailing) {
                        ProvenanceCoverBadge(
                            provenance: store.provenance(ofFolder: folder.id))
                    }
                VStack(alignment: .leading, spacing: 2) {
                    Text(folder.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(folderSubtitle(folder))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 2)
            }
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

    private func notebookCard(_ notebook: NotebookManifest) -> some View {
        Button {
            // A conflicted notebook opens the chooser, not the editor — editing a copy whose fate
            // is undecided would just add a third version. Notable does the same on the BOOX.
            if let conflict = coordinator.conflict(for: notebook.notebookId) {
                resolvingConflict = conflict
            } else {
                openNotebook(notebook.notebookId)
            }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                cover(for: notebook)
                VStack(alignment: .leading, spacing: 2) {
                    Text(notebook.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(notebookSubtitle(notebook))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 2)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
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
    }

    @ViewBuilder
    private func cover(for notebook: NotebookManifest) -> some View {
        Group {
            if let image = ThumbnailRenderer.thumbnail(for: notebook, store: store) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.white
                    Image(systemName: "pencil.and.scribble")
                        .font(.system(size: 36))
                        .foregroundStyle(Color.primary.opacity(0.15))
                }
            }
        }
        .aspectRatio(3.0 / 4.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08)))
        .overlay(alignment: .topTrailing) {
            if coordinator.conflict(for: notebook.notebookId) != nil {
                ConflictCoverBadge()
            } else {
                ProvenanceCoverBadge(
                    provenance: store.provenance(ofNotebook: notebook.notebookId))
            }
        }
        .shadow(color: .black.opacity(0.10), radius: 5, y: 3)
    }

    // MARK: Subtitles

    private func folderSubtitle(_ folder: FolderDTO) -> String {
        let count = store.itemCount(in: folder.id)
        return "\(count) item\(count == 1 ? "" : "s")"
    }

    private func notebookSubtitle(_ notebook: NotebookManifest) -> String {
        let pages = notebook.pageIds.count
        let when = NotableDate.parse(notebook.updatedAt)
            .map { $0.formatted(.relative(presentation: .named)) } ?? notebook.updatedAt
        return "\(pages) page\(pages == 1 ? "" : "s") · \(when)"
    }
}
