import NotableKit
import SwiftUI

/// A short route between notebooks, without leaving the writing screen for the library.
struct NotebookSwitcherView: View {
    @EnvironmentObject private var store: NotebookStore
    @EnvironmentObject private var coordinator: SyncCoordinator
    @Environment(\.dismiss) private var dismiss
    let currentNotebookID: String
    let select: (String) -> Void
    @State private var query = ""

    private var recent: [NotebookManifest] {
        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? store.recentNotebooks : []
    }

    private var others: [NotebookManifest] {
        let recentIDs = Set(recent.map(\.notebookId))
        return store.search(query).notebooks.filter { !recentIDs.contains($0.notebookId) }
    }

    var body: some View {
        NavigationStack {
            List {
                if !recent.isEmpty {
                    Section("Recently opened") {
                        ForEach(recent, id: \.notebookId) { notebook in row(notebook) }
                    }
                }
                if !others.isEmpty {
                    Section(query.isEmpty ? "All notebooks" : "Search results") {
                        ForEach(others, id: \.notebookId) { notebook in row(notebook) }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Modernist.paper)
            .overlay {
                if recent.isEmpty && others.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .searchable(text: $query, prompt: "Find a notebook")
            .navigationTitle("Switch notebook")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .tint(Modernist.ink)
    }

    private func row(_ notebook: NotebookManifest) -> some View {
        let current = notebook.notebookId == currentNotebookID
        let conflicted = coordinator.conflict(for: notebook.notebookId) != nil
        return Button {
            guard !current && !conflicted else { return }
            select(notebook.notebookId)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: current ? "checkmark" : "doc.text")
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text(notebook.title).foregroundStyle(Modernist.ink)
                    if conflicted {
                        Text("Resolve conflict in Library")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        let path = store.breadcrumb(of: notebook.parentFolderId).map(\.title)
                        Text(path.isEmpty ? "Library" : path.joined(separator: " / "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .disabled(conflicted)
        .accessibilityAddTraits(current ? .isSelected : [])
        .accessibilityIdentifier("switcher.notebook.\(notebook.notebookId)")
        .accessibilityValue(current ? "Current notebook" : conflicted ? "Conflict" : "")
    }
}
