import NotableKit
import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var store: NotebookStore
    @State private var showingNewNotebook = false
    @State private var newTitle = ""

    var body: some View {
        Group {
            if store.notebooks.isEmpty {
                ContentUnavailableView(
                    "No notebooks yet", systemImage: "pencil.and.scribble",
                    description: Text("Create a notebook, or sync from your BOOX."))
            } else {
                List(store.notebooks, id: \.notebookId) { notebook in
                    NavigationLink(value: notebook.notebookId) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(notebook.title).font(.headline)
                            Text(subtitle(for: notebook))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("bopa")
        .navigationDestination(for: String.self) { notebookId in
            EditorView(notebookId: notebookId)
        }
        .toolbar {
            Button {
                newTitle = ""
                showingNewNotebook = true
            } label: {
                Image(systemName: "plus")
            }
        }
        .alert("New notebook", isPresented: $showingNewNotebook) {
            TextField("Title", text: $newTitle)
            Button("Create") {
                let title = newTitle.trimmingCharacters(in: .whitespaces)
                _ = try? store.createNotebook(title: title.isEmpty ? "Untitled" : title)
            }
            Button("Cancel", role: .cancel) {}
        }
        .onAppear { store.refresh() }
    }

    private func subtitle(for notebook: NotebookManifest) -> String {
        let pages = notebook.pageIds.count
        let when = NotableDate.parse(notebook.updatedAt)
            .map { $0.formatted(.relative(presentation: .named)) } ?? notebook.updatedAt
        return "\(pages) page\(pages == 1 ? "" : "s") · \(when)"
    }
}
