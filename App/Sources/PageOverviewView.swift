import NotableKit
import SwiftUI

/// Every page of a notebook at once: a thumbnail grid you can navigate, reorder and edit from.
///
/// The BOOX has had this since its editor existed; bopa had previous, next, add, and a page count,
/// so a notebook of forty pages could only be crossed one tap at a time and a page could not be
/// renamed, duplicated, deleted or moved at all. This is the same set of actions, drawn the way
/// this app draws things.
struct PageOverviewView: View {
    @EnvironmentObject private var store: NotebookStore
    @Environment(\.dismiss) private var dismiss

    let notebookId: String
    /// The page the editor currently has open — highlighted, and scrolled to on appear.
    let currentPageId: String?
    /// Tapping a page opens it in the editor and closes this.
    let openPage: (String) -> Void

    @State private var renamingPageId: String?
    @State private var renameTitle = ""
    @State private var showingRename = false
    @State private var deletingPageId: String?
    @State private var actionError: LibraryActionError?

    private var manifest: NotebookManifest? { store.manifest(id: notebookId) }
    private var pageIds: [String] { manifest?.pageIds ?? [] }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 18)],
                    alignment: .leading, spacing: 22
                ) {
                    ForEach(Array(pageIds.enumerated()), id: \.element) { index, pageId in
                        pageCell(pageId: pageId, index: index)
                            .id(pageId)
                    }
                }
                .padding(22)
            }
            .onAppear {
                store.refresh()
                if let currentPageId { proxy.scrollTo(currentPageId, anchor: .center) }
            }
        }
        .background(Modernist.paper)
        .navigationTitle(manifest?.title ?? "Pages")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    perform("Adding a page", error: $actionError) {
                        try store.insertPage(into: notebookId, at: nil)
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add page")
                .accessibilityIdentifier("pages.add")
            }
        }
        .alert("Rename page", isPresented: $showingRename) {
            TextField("Name", text: $renameTitle)
            Button("Rename") {
                guard let pageId = renamingPageId else { return }
                let trimmed = renameTitle.trimmingCharacters(in: .whitespaces)
                perform("Renaming the page", error: $actionError) {
                    // An empty name clears it rather than storing "", so the cell falls back to
                    // "Page 3" instead of showing a blank label.
                    try store.renamePage(
                        in: notebookId, pageId: pageId, title: trimmed.isEmpty ? nil : trimmed)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Delete this page?", isPresented: .constant(deletingPageId != nil),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let pageId = deletingPageId {
                    perform("Deleting the page", error: $actionError) {
                        try store.deletePage(from: notebookId, pageId: pageId)
                    }
                }
                deletingPageId = nil
            }
            Button("Cancel", role: .cancel) { deletingPageId = nil }
        } message: {
            Text("The page and everything on it is deleted here and on every device you sync "
                + "with. It cannot be undone.")
        }
        .libraryActionAlert($actionError)
    }

    // MARK: Cells

    private func pageCell(pageId: String, index: Int) -> some View {
        Button {
            openPage(pageId)
            dismiss()
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                thumbnail(pageId: pageId)
                Text(label(for: pageId, index: index))
                    .font(Modernist.font(12, .semibold))
                    .foregroundStyle(Modernist.ink)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("pages.page.\(pageId)")
        .contextMenu { menu(pageId: pageId, index: index) }
        // Drag to reorder. `onMove` needs a List; the grid is what makes a notebook of forty pages
        // legible, so the drop target is each cell instead.
        .draggable(pageId) {
            thumbnail(pageId: pageId).frame(width: 90)
        }
        .dropDestination(for: String.self) { items, _ in
            guard let dragged = items.first,
                  let from = pageIds.firstIndex(of: dragged),
                  from != index
            else { return false }
            perform("Moving the page", error: $actionError) {
                try store.movePage(in: notebookId, from: from, to: index)
            }
            return true
        }
    }

    private func thumbnail(pageId: String) -> some View {
        let image = store.manifest(id: notebookId).flatMap { manifest in
            ThumbnailRenderer.thumbnail(
                notebookId: notebookId, pageId: pageId,
                revision: manifest.updatedAt, store: store)
        }
        return ZStack {
            Rectangle().fill(.white)
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fit)
            }
        }
        .aspectRatio(3.0 / 4.0, contentMode: .fit)
        // The open page is edged rather than tinted: nothing in this design floats or glows, and
        // the page you came from is the one thing you need to find on this screen.
        .overlay {
            Rectangle()
                .stroke(
                    Modernist.ink,
                    lineWidth: pageId == currentPageId ? Modernist.ruleHeavy : Modernist.ruleHair)
        }
    }

    /// The page's own name if it has one, else its position — the number is what everyone counts
    /// pages by, and a page nobody named has nothing else to say.
    private func label(for pageId: String, index: Int) -> String {
        let title = try? store.loadPage(notebookId: notebookId, pageId: pageId).title
        if let title, !title.isEmpty { return title }
        return "Page \(index + 1)"
    }

    @ViewBuilder
    private func menu(pageId: String, index: Int) -> some View {
        Button {
            renamingPageId = pageId
            renameTitle = (try? store.loadPage(notebookId: notebookId, pageId: pageId).title) ?? ""
            showingRename = true
        } label: {
            Label("Rename", systemImage: "pencil")
        }
        Button {
            perform("Duplicating the page", error: $actionError) {
                try store.duplicatePage(in: notebookId, pageId: pageId)
            }
        } label: {
            Label("Duplicate", systemImage: "plus.square.on.square")
        }
        Button {
            perform("Inserting a page", error: $actionError) {
                try store.insertPage(into: notebookId, at: index + 1)
            }
        } label: {
            Label("Insert after", systemImage: "plus.rectangle")
        }
        Divider()
        Button(role: .destructive) {
            deletingPageId = pageId
        } label: {
            Label("Delete", systemImage: "trash")
        }
        // The last page cannot go: a notebook with none is the empty leftover the library already
        // has to warn about, and arriving there deliberately would be a worse way to get it.
        .disabled(pageIds.count <= 1)
    }
}
