import NotableKit
import SwiftUI

/// Recently Deleted, for folders and notebooks.
///
/// Everything here is still on this iPad and still on the server: the Trash is a staging area, not
/// a deletion. Restoring puts an item back where it came from — or at the root, if that folder is
/// itself gone — and is the ordinary outcome. Deleting for good is the only irreversible action in
/// the app and the only one here that publishes anything, so it always asks first.
///
/// The twin of Notable's Trash screen on the BOOX.
struct TrashView: View {
    @EnvironmentObject private var store: NotebookStore
    @Environment(\.dismiss) private var dismiss

    @State private var purgingNotebookId: String?
    @State private var purgingFolderId: String?
    @State private var showingEmptyTrash = false
    @State private var actionError: LibraryActionError?

    private var folders: [FolderDTO] { store.trashedFolders }
    private var notebooks: [NotebookManifest] { store.trashedNotebooks }

    var body: some View {
        Group {
            if store.trash.isEmpty {
                ContentUnavailableView(
                    "Trash is empty", systemImage: "trash",
                    description: Text("Deleted folders and notebooks wait here until you empty it."))
            } else {
                List {
                    if !folders.isEmpty {
                        Section("Folders") {
                            ForEach(folders, id: \.id) { folder in
                                row(
                                    title: folder.title,
                                    // Everything under a trashed folder went with it, and this row
                                    // is the only place that is ever said.
                                    subtitle: "Folder, with everything inside it",
                                    deletedAt: store.trashedAt(folderId: folder.id),
                                    restore: {
                                        perform("Restoring the folder", error: $actionError) {
                                            try store.restoreFolder(id: folder.id)
                                        }
                                    },
                                    purge: { purgingFolderId = folder.id })
                            }
                        }
                    }
                    if !notebooks.isEmpty {
                        Section("Notebooks") {
                            ForEach(notebooks, id: \.notebookId) { notebook in
                                row(
                                    title: notebook.title,
                                    subtitle: "\(notebook.pageIds.count) "
                                        + (notebook.pageIds.count == 1 ? "page" : "pages"),
                                    deletedAt: store.trashedAt(notebookId: notebook.notebookId),
                                    restore: {
                                        perform("Restoring the notebook", error: $actionError) {
                                            try store.restoreNotebook(id: notebook.notebookId)
                                        }
                                    },
                                    purge: { purgingNotebookId = notebook.notebookId })
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Trash")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
            ToolbarItem(placement: .destructiveAction) {
                Button("Empty", role: .destructive) { showingEmptyTrash = true }
                    .disabled(store.trash.isEmpty)
                    .accessibilityIdentifier("trash.empty")
            }
        }
        .confirmationDialog(
            "Delete permanently?",
            isPresented: .constant(purgingNotebookId != nil || purgingFolderId != nil),
            titleVisibility: .visible
        ) {
            Button("Delete permanently", role: .destructive) { purgeSelection() }
            Button("Cancel", role: .cancel) { clearSelection() }
        } message: {
            Text(purgeMessage)
        }
        .confirmationDialog(
            "Empty the Trash?", isPresented: $showingEmptyTrash, titleVisibility: .visible
        ) {
            Button("Delete permanently", role: .destructive) {
                perform("Emptying the Trash", error: $actionError) {
                    try store.emptyTrash()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes \(store.trash.count) "
                + (store.trash.count == 1 ? "item" : "items")
                + " and everything inside them, here and on every device you sync with. "
                + "It cannot be undone.")
        }
        .libraryActionAlert($actionError)
        .onAppear { store.refresh() }
    }

    /// Restoring is the row's own tap and its swipe: it is the reversible action, so it should be
    /// the easy one to hit. Deleting for good is behind a swipe *and* a confirmation.
    private func row(
        title: String, subtitle: String, deletedAt: Date?,
        restore: @escaping () -> Void, purge: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.body)
            Text(deletedAt.map { "\(subtitle) · deleted \($0.formatted(.relative(presentation: .named)))" }
                ?? subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: restore)
        .swipeActions(edge: .trailing) {
            Button("Delete", role: .destructive, action: purge)
        }
        .swipeActions(edge: .leading) {
            Button("Restore", action: restore).tint(.blue)
        }
    }

    private var purgeMessage: String {
        if let id = purgingFolderId, let folder = store.folder(id: id) {
            return "\"\(folder.title)\" and everything inside it will be deleted here and on "
                + "every device you sync with. It cannot be undone."
        }
        if let id = purgingNotebookId,
           let notebook = store.notebooks.first(where: { $0.notebookId == id }) {
            return "\"\(notebook.title)\" will be deleted here and on every device you sync with. "
                + "It cannot be undone."
        }
        return ""
    }

    private func purgeSelection() {
        if let id = purgingFolderId {
            perform("Deleting the folder", error: $actionError) {
                try store.purgeFolder(id: id)
            }
        } else if let id = purgingNotebookId {
            perform("Deleting the notebook", error: $actionError) {
                try store.purgeNotebook(id: id)
            }
        }
        clearSelection()
    }

    private func clearSelection() {
        purgingNotebookId = nil
        purgingFolderId = nil
    }
}
