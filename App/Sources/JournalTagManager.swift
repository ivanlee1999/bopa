import NotableKit
import SwiftUI

struct JournalTagManager: View {
    @EnvironmentObject private var store: NotebookStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage("journal.automaticTags") private var automaticTags = true
    @State private var search = ""
    @State private var renaming: Topic?
    @State private var removing: Topic?
    @State private var error: String?

    private struct Topic: Identifiable {
        var id: String; var name: String; var count = 0; var trashed = 0
    }
    private var topics: [Topic] {
        let existing = Set(store.notebooks.map(\.notebookId))
        let hidden = existing.subtracting(store.search("").notebooks.map(\.notebookId))
        var result: [String: Topic] = [:]
        for entry in store.journalEntries.values where existing.contains(entry.notebookId) {
            for (key, value) in entry.topics where value.present {
                var topic = result[key] ?? Topic(id: key, name: value.name)
                if value.name.utf8.lexicographicallyPrecedes(topic.name.utf8) { topic.name = value.name }
                topic.count += 1
                if hidden.contains(entry.notebookId) { topic.trashed += 1 }
                result[key] = topic
            }
        }
        return result.values.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("Automatic tags", isOn: $automaticTags).accessibilityIdentifier("tags.automatic")
                } footer: { Text("On this device. Matches tag names and #hashtags in text and recognized handwriting.") }
                ForEach(topics) { topic in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("#\(topic.name)")
                            Text((topic.count == 1 ? "1 note" : "\(topic.count) notes") + (topic.trashed > 0 ? " · \(topic.trashed) in Trash" : ""))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Menu {
                            Button("Rename or merge") { renaming = topic }
                            Button("Remove from all notes", role: .destructive) { removing = topic }
                        } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                            .accessibilityLabel("Manage \(topic.name)")
                            .accessibilityIdentifier("tags.menu.\(topic.id)")
                    }
                }
            }.searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Find a tag")
                .onChange(of: automaticTags) { _, enabled in store.setAutomaticTagsEnabled(enabled) }
                .navigationTitle("Manage tags")
                .toolbar { Button("Done") { dismiss() }.accessibilityIdentifier("tags.done") }
                .sheet(item: $renaming) { RenameJournalTagSheet(key: $0.id, name: $0.name) }
                .confirmationDialog("Remove tag from all notes?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
                    Button("Remove tag", role: .destructive) {
                        guard let topic = removing else { return }
                        perform { try store.removeJournalTopic(key: topic.id) }; removing = nil
                    }.accessibilityIdentifier("tags.removeConfirm")
                    Button("Cancel", role: .cancel) { removing = nil }
                } message: { Text("Remove #\(removing?.name ?? "") from every note, including Trash. Your notes stay intact.") }
                .alert("Could not save tags", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                    Button("OK") { error = nil }
                } message: { Text(error ?? "") }
        }
    }

    private func perform(_ action: () throws -> Void) {
        do { try action() } catch { self.error = error.localizedDescription }
    }
}

private struct RenameJournalTagSheet: View {
    @EnvironmentObject private var store: NotebookStore
    @Environment(\.dismiss) private var dismiss
    let key: String
    @State private var name: String
    @State private var error: String?

    init(key: String, name: String) {
        self.key = key
        _name = State(initialValue: name.hasPrefix("#") ? "#" + name : name)
    }
    private var merges: Bool {
        let target = journalTopicKey(name), existing = Set(store.notebooks.map(\.notebookId))
        return target != key && store.journalEntries.values.contains {
            existing.contains($0.notebookId) && $0.topics[target]?.present == true
        }
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Tag name", text: $name).textInputAutocapitalization(.never)
                        .accessibilityIdentifier("tags.rename").onSubmit(save)
                } footer: { Text(merges ? "Combine these tags on every note, including Trash." : "Update this tag on every note, including Trash.") }
            }.navigationTitle("Rename tag")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(merges ? "Merge" : "Rename", action: save)
                            .disabled(journalTopicName(name).isEmpty).accessibilityIdentifier("tags.renameConfirm")
                    }
                }
                .alert("Could not save tags", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                    Button("OK") { error = nil }
                } message: { Text(error ?? "") }
        }.presentationDetents([.medium, .large])
    }
    private func save() {
        guard !journalTopicName(name).isEmpty else { return }
        do { try store.renameJournalTopic(key: key, to: name); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}
