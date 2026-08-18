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
    @State private var resolvingConflict: NotebookConflict?

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
                LibrarySidebar(selection: $selection, openNotebook: open)
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
                    openNotebook: open)
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
        // Presented here rather than in either column, because both open notebooks: the
        // sidebar's tree and the grid's covers go through `open` alike.
        .sheet(item: $resolvingConflict) { conflict in
            ConflictResolutionView(conflict: conflict)
        }
    }

    /// A conflicted notebook opens the chooser, not the editor — editing a copy whose fate
    /// is undecided would just add a third version. Notable does the same on the BOOX.
    private func open(_ notebookId: String) {
        if let conflict = coordinator.conflict(for: notebookId) {
            resolvingConflict = conflict
        } else {
            openNotebook = OpenNotebook(id: notebookId)
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
    @State private var newNotebookPageSize = PageSizePreset.default.size
    @State private var showingNewFolder = false
    @State private var newFolderTitle = ""

    @State private var renamingNotebookId: String?
    @State private var showingRenameNotebook = false
    @State private var renamingFolderId: String?
    @State private var showingRenameFolder = false
    @State private var renameTitle = ""

    @State private var deletingNotebookId: String?
    @State private var showingDeleteNotebook = false
    @State private var deletingFolderId: String?
    @State private var showingDeleteFolder = false
    @State private var showingSyncSettings = false
    @State private var showingTrash = false
    @State private var actionError: LibraryActionError?

    @State private var query = ""
    /// Persisted, because an order is a preference about the library rather than about this
    /// visit to it — coming back to a differently-arranged shelf is its own small confusion.
    @AppStorage("library.sortOrder") private var sortOrderRaw = LibrarySortOrder.updated.rawValue
    @AppStorage("library.sortDescending") private var sortDescending = true

    private var sortOrder: LibrarySortOrder {
        LibrarySortOrder(rawValue: sortOrderRaw) ?? .updated
    }

    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// What throwing away the folder under the open confirmation would take with it.
    private var deletingFolderScope: NotebookStore.DeletionScope? {
        deletingFolderId.map { store.deletionScope(ofFolder: $0) }
    }

    /// A local deletion that failed. Reported rather than swallowed: the notebook is still on the
    /// screen afterwards, and without this the user is left to conclude that Delete does nothing.

    private var trimmedRenameTitle: String {
        renameTitle.trimmingCharacters(in: .whitespaces)
    }

    /// Searching leaves the current folder behind: the reason to search is not knowing where the
    /// thing is, so a search that only looked in the folder you are standing in would answer the
    /// question you did not ask.
    private var subfolders: [FolderDTO] {
        let found = isSearching ? store.search(query).folders : store.folders(in: folderId)
        return LibrarySort.folders(found, by: sortOrder, descending: sortDescending)
    }

    private var notebooks: [NotebookManifest] {
        let found = isSearching ? store.search(query).notebooks : store.notebooks(in: folderId)
        return LibrarySort.notebooks(found, by: sortOrder, descending: sortDescending)
    }

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
        // A sheet rather than an alert: an alert holds text fields and buttons and nothing
        // else, and the paper size has to be chosen here — it is the one moment it can be.
        .sheet(isPresented: $showingNewNotebook) {
            NewNotebookSheet(
                title: $newNotebookTitle,
                pageSize: $newNotebookPageSize,
                create: { title, pageSize in
                    perform("Creating the notebook", error: $actionError) {
                        _ = try store.createNotebook(
                            title: title, parentFolderId: folderId,
                            template: handwriting.config.defaultTemplate,
                            pageSize: pageSize)
                    }
                    // The choice sticks, so a second notebook does not need making again.
                    handwriting.config.defaultPageSize = pageSize
                })
        }
        .alert("New folder", isPresented: $showingNewFolder) {
            TextField("Name", text: $newFolderTitle)
            Button("Create") {
                let title = newFolderTitle.trimmingCharacters(in: .whitespaces)
                perform("Creating the folder", error: $actionError) {
                    _ = try store.createFolder(
                        title: title.isEmpty ? "Untitled" : title, parentFolderId: folderId)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename notebook", isPresented: $showingRenameNotebook) {
            TextField("Title", text: $renameTitle)
            // Disabled rather than a no-op: an alert closes whatever its button does, so a
            // blank title would otherwise dismiss and silently keep the old one.
            Button("Rename") {
                if let id = renamingNotebookId {
                    perform("Renaming the notebook", error: $actionError) {
                        try store.renameNotebook(id: id, title: trimmedRenameTitle)
                    }
                }
            }
            .disabled(trimmedRenameTitle.isEmpty)
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename folder", isPresented: $showingRenameFolder) {
            TextField("Name", text: $renameTitle)
            Button("Rename") {
                if let id = renamingFolderId {
                    perform("Renaming the folder", error: $actionError) {
                        try store.renameFolder(id: id, title: trimmedRenameTitle)
                    }
                }
            }
            .disabled(trimmedRenameTitle.isEmpty)
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Move to Trash?", isPresented: $showingDeleteNotebook, titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                if let id = deletingNotebookId {
                    perform("Moving the notebook to the Trash", error: $actionError) {
                        try store.trashNotebook(id: id)
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            // Says what the other device will do, because it will do it immediately: the Trash is
            // synced. Nothing is destroyed until the Trash is emptied, which is what makes
            // restoring mean anything, and a restore travels the same way.
            Text("The notebook leaves the library on your BOOX too, and stays in the Trash until "
                + "you empty it. Nothing is deleted until then.")
        }
        .confirmationDialog(
            "Move to Trash?", isPresented: $showingDeleteFolder, titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                if let id = deletingFolderId {
                    perform("Moving the folder to the Trash", error: $actionError) {
                        try store.trashFolder(id: id)
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(folderDeletionMessage)
        }
        .sheet(isPresented: $showingTrash) {
            NavigationStack { TrashView() }
        }
        .libraryActionAlert($actionError)
        .onAppear { store.refresh() }
    }

    /// Says what is inside, because the number is the decision: a folder holding forty notebooks
    /// is a different act from an empty one made by accident, and one confirmation cannot tell
    /// them apart without saying so.
    private var folderDeletionMessage: String {
        guard let scope = deletingFolderScope else { return "" }
        let contents: String
        if scope.isEmpty {
            contents = "It is empty."
        } else {
            let parts = [
                scope.childFolderCount > 0
                    ? "\(scope.childFolderCount) folder\(scope.childFolderCount == 1 ? "" : "s")"
                    : nil,
                !scope.notebookIDs.isEmpty
                    ? "\(scope.notebookIDs.count) notebook\(scope.notebookIDs.count == 1 ? "" : "s")"
                    : nil,
                scope.pageCount > 0
                    ? "\(scope.pageCount) page\(scope.pageCount == 1 ? "" : "s")" : nil,
            ].compactMap { $0 }
            contents = "It holds \(parts.formatted(.list(type: .and)))."
        }
        return "\(contents) Everything inside goes with it — on your BOOX as well — and stays in "
            + "the Trash until you empty it."
    }

    // MARK: Header

    /// Kicker, display title and the screen's actions, closed by a heavy rule — the
    /// design's masthead. One solid action per screen (new notebook); everything else is
    /// outlined.
    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .bottom, spacing: 12) {
                titleBlock
                Spacer(minLength: 8)
                Button {
                    toggleSidebar()
                } label: {
                    Image(systemName: "sidebar.leading").font(.system(size: 19, weight: .medium))
                }
                .buttonStyle(.squareOutline)
                .accessibilityLabel("Toggle folders")
                .accessibilityIdentifier("library.toggleSidebar")

                // Only once something is in it: a permanently visible Trash is a permanent
                // reminder of a screen almost nobody needs, while one that appears the moment
                // something is deleted is how you find out deletion was recoverable at all.
                if !store.trash.isEmpty {
                    Button {
                        showingTrash = true
                    } label: {
                        Image(systemName: "trash").font(.system(size: 18, weight: .medium))
                    }
                    .buttonStyle(.squareOutline)
                    .accessibilityLabel("Trash, \(store.trash.count) items")
                    .accessibilityIdentifier("library.trash")
                }

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
                    newNotebookPageSize = handwriting.config.defaultPageSize
                    showingNewNotebook = true
                } label: {
                    Image(systemName: "plus").font(.system(size: 22, weight: .bold))
                }
                .buttonStyle(.squareSolid)
                .accessibilityLabel("New notebook")
                .accessibilityIdentifier("library.add")
            }
            searchRow
            ModernistRule(heavy: true)
        }
        .padding(.horizontal, 22)
        .padding(.top, 8)
    }

    /// Search and sort, on one line under the title.
    ///
    /// Both are about *finding* something, and neither is worth a screen of its own: the library
    /// used to offer no way to look for a notebook by name and no order but the one the store
    /// happened to sort by, which in a library of eighty covers means reading all eighty.
    private var searchRow: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Modernist.neutral600)
                TextField("Search notebooks and folders", text: $query)
                    .font(Modernist.font(13))
                    .foregroundStyle(Modernist.ink)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.search)
                    .accessibilityIdentifier("library.search")
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(Modernist.neutral600)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .overlay { Rectangle().stroke(Modernist.neutral600, lineWidth: Modernist.ruleHair) }

            Menu {
                Picker("Sort by", selection: $sortOrderRaw) {
                    ForEach(LibrarySortOrder.allCases) { order in
                        Label(order.label, systemImage: order.symbolName).tag(order.rawValue)
                    }
                }
                Divider()
                // Named for what the reader gets, not for the direction of the comparison:
                // "descending" says nothing about whether that means newest or Z first.
                Picker("Direction", selection: $sortDescending) {
                    Text(sortOrder == .title ? "A to Z" : "Newest first").tag(true)
                    Text(sortOrder == .title ? "Z to A" : "Oldest first").tag(false)
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 13, weight: .semibold))
                    Text(sortOrder.label).font(Modernist.font(12, .semibold))
                }
                .foregroundStyle(Modernist.ink)
                .padding(.horizontal, 10)
                .frame(height: 34)
                .overlay { Rectangle().stroke(Modernist.ink, lineWidth: Modernist.ruleHair) }
            }
            .accessibilityLabel("Sort")
            .accessibilityIdentifier("library.sort")
        }
        .padding(.top, 2)
    }

    /// Kicker and display title. Inside a folder the whole block is the rename control — the
    /// name you want to change is the one you are already looking at, and the pencil beside it
    /// says so without spending another 48pt square on a header that already carries four.
    @ViewBuilder
    private var titleBlock: some View {
        if let folderId {
            Button {
                beginRenameFolder(folderId)
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Kicker("Folder")
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        titleText
                        Image(systemName: "pencil")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Modernist.neutral700)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Rename folder \(title)")
            .accessibilityIdentifier("library.renameFolder")
        } else {
            VStack(alignment: .leading, spacing: 1) {
                Kicker("Library")
                titleText
            }
        }
    }

    private var titleText: some View {
        Text(title)
            .font(Modernist.display(30))
            .tracking(Modernist.displayTracking(30))
            .foregroundStyle(Modernist.ink)
            .lineLimit(1)
    }

    private func beginRenameFolder(_ id: String) {
        renamingFolderId = id
        renameTitle = store.folder(id: id)?.title ?? ""
        showingRenameFolder = true
    }

    @ViewBuilder
    private var emptyState: some View {
        Group {
            if isSearching {
                ContentUnavailableView.search(text: query)
            } else if folderId == nil {
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
                    SectionHeading(isSearching ? "Folders found" : "Folders")
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
                    SectionHeading(isSearching ? "Notebooks found" : "Notebooks")
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
        // Named so a test can say *which* column it means: since the sidebar became a tree, a
        // notebook's title is on screen twice — once on its card here, once on its row there.
        .accessibilityIdentifier("library.contents")
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
                beginRenameFolder(folder.id)
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            // No longer restricted to empty folders. Refusing to delete a populated one was the
            // only protection there was against losing a subtree; now the Trash is, and it is a
            // better one — a populated folder can be thrown away and brought back.
            Button(role: .destructive) {
                deletingFolderId = folder.id
                showingDeleteFolder = true
            } label: {
                Label("Delete", systemImage: "trash")
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

    /// Opening goes up to `LibraryView`, which owns the conflict chooser: the sidebar's tree
    /// opens notebooks too, and both have to route a conflicted one the same way.
    private func open(_ notebook: NotebookManifest) {
        openNotebook(notebook.notebookId)
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
                perform("Moving the notebook", error: $actionError) {
                    try store.moveNotebook(id: notebook.notebookId, toFolder: nil)
                }
            }
            // Only live folders: `store.folders` is the whole published set, trashed subtrees
            // included, and a notebook moved into one of those is reachable from no surface —
            // then purged for good with the Trash.
            ForEach(store.liveFolders, id: \.id) { folder in
                Button(folder.title) {
                    perform("Moving the notebook", error: $actionError) {
                        try store.moveNotebook(id: notebook.notebookId, toFolder: folder.id)
                    }
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
    ///
    /// While searching it leads with where the notebook was found instead. A result list spanning
    /// the whole library is not much use if every row looks the same as it would in its own
    /// folder — "which of these three is the one from Term 2" is the question a path answers.
    private func notebookSubtitle(_ notebook: NotebookManifest) -> String {
        let edited = NotableDate.parse(notebook.updatedAt)
            .map { $0.formatted(.relative(presentation: .named)) } ?? notebook.updatedAt
        guard isSearching else { return edited }
        let path = store.breadcrumb(of: notebook.parentFolderId).map(\.title)
        return path.isEmpty ? "All Notes · \(edited)" : "\(path.joined(separator: " / ")) · \(edited)"
    }
}

/// The New-notebook form: a title, and the paper size the notebook's pages are laid out on.
///
/// The size is asked for here because here is the only place it can be asked. Both apps read a
/// page's sheet from the page file, so ink is positioned against it from the first stroke;
/// changing it afterwards would slide every stroke on every page relative to the paper.
private struct NewNotebookSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var title: String
    @Binding var pageSize: PageSize
    let create: (String, PageSize) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $title)
                        .accessibilityIdentifier("newNotebook.title")
                }
                Section {
                    PageSizePicker(selection: $pageSize)
                        .accessibilityIdentifier("newNotebook.pageSize")
                } footer: {
                    Text("Every page in this notebook is laid out on this sheet, on the iPad and "
                        + "on the BOOX alike. It is fixed once the notebook exists, so that ink "
                        + "never has to move relative to the paper.")
                }
            }
            .navigationTitle("New notebook")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        let trimmed = title.trimmingCharacters(in: .whitespaces)
                        create(trimmed.isEmpty ? "Untitled" : trimmed, pageSize)
                        dismiss()
                    }
                    .accessibilityIdentifier("newNotebook.create")
                }
            }
        }
    }
}
