import NotableKit
import SwiftUI

struct JournalLibraryView: View {
    @EnvironmentObject private var store: NotebookStore
    let topics: Bool
    let toggleSidebar: () -> Void
    let openNotebook: (String) -> Void
    @State private var date = Date()
    @State private var selectedTopic: String?
    @State private var editing: String?
    @State private var topicName = ""
    @State private var error: String?

    private var topicNames: [String: String] {
        var names: [String: String] = [:]
        for entry in store.journalEntries.values {
            for (key, topic) in entry.topics where topic.present {
                if names[key] == nil || names[key]!.utf8.lexicographicallyPrecedes(topic.name.utf8) {
                    names[key] = topic.name
                }
            }
        }
        return names
    }
    private var allTopics: [String] { topicNames.keys.sorted() }
    private var day: String {
        let format = DateFormatter(); format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd"
        return format.string(from: date)
    }
    private var entries: [NotebookManifest] {
        store.search("").notebooks.filter { notebook in
            guard let entry = store.journalEntries[notebook.notebookId] else { return false }
            if topics { return selectedTopic.map { entry.topics[$0]?.present == true } ?? false }
            return entry.date == day
        }.sorted { (store.journalEntries[$0.notebookId]?.createdAt ?? 0) > (store.journalEntries[$1.notebookId]?.createdAt ?? 0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: toggleSidebar) { Image(systemName: "sidebar.left") }.accessibilityLabel("Folders")
                Text(topics ? selectedTopic.map { "#\(topicNames[$0] ?? $0)" } ?? "Topics" : "Today")
                    .font(.title2).frame(maxWidth: .infinity, alignment: .leading)
                Button("New note") {
                    do {
                        let note = try store.createJournalEntry(topic: topics ? selectedTopic.flatMap { topicNames[$0] } : nil)
                        date = Date(); openNotebook(note.notebookId)
                    } catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent).tint(Modernist.ink)
            }.padding(20)
            if !topics {
                HStack {
                    Button { date = Calendar.current.date(byAdding: .day, value: -1, to: date) ?? date }
                        label: { Image(systemName: "chevron.left") }.accessibilityLabel("Previous day")
                    DatePicker("Journal date", selection: $date, displayedComponents: .date).labelsHidden()
                    Button { date = Calendar.current.date(byAdding: .day, value: 1, to: date) ?? date }
                        label: { Image(systemName: "chevron.right") }.accessibilityLabel("Next day")
                    Spacer()
                    Button("Today") { date = Date() }
                }.padding(.horizontal, 20).padding(.bottom, 12)
            }
            ModernistRule()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if topics && selectedTopic == nil {
                        ForEach(allTopics, id: \.self) { topic in
                            Button("#\(topicNames[topic] ?? topic)") { selectedTopic = topic }
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        }
                    } else {
                        if topics { Button("All topics") { selectedTopic = nil } }
                        ForEach(entries, id: \.notebookId) { note in
                            VStack(alignment: .leading, spacing: 8) {
                                Button { openNotebook(note.notebookId) } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(note.title).font(.headline)
                                        if let date = store.journalEntries[note.notebookId]?.date {
                                            Text(date).font(.caption).foregroundStyle(.secondary)
                                        }
                                    }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                }.buttonStyle(.plain)
                                HStack {
                                    Text((store.journalEntries[note.notebookId]?.visibleTopics ?? []).map { "#\($0)" }.joined(separator: "  "))
                                        .font(.caption).lineLimit(2)
                                    Spacer()
                                    Button("Topics") { editing = note.notebookId }
                                }
                            }
                            ModernistRule()
                        }
                        if entries.isEmpty { Text("No notes").foregroundStyle(.secondary) }
                    }
                    if let message = store.journalError { Text(message).foregroundStyle(.red) }
                }.padding(20)
            }
        }.background(Modernist.paper)
        .alert("Could not save", isPresented: Binding(get: { error != nil && editing == nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
        .sheet(isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            NavigationStack {
                Form {
                    ForEach(allTopics, id: \.self) { topic in
                        let selected = store.journalEntries[editing ?? ""]?.topics[topic]?.present == true
                        Button {
                            setTopic(topicNames[topic] ?? topic, present: !selected)
                        } label: {
                            HStack { Text(topicNames[topic] ?? topic); Spacer(); if selected { Image(systemName: "checkmark") } }
                        }
                    }
                    HStack {
                        TextField("New topic", text: $topicName)
                        Button("Add") { if setTopic(topicName, present: true) { topicName = "" } }
                            .disabled(journalTopicName(topicName).isEmpty)
                    }
                }.navigationTitle("Topics")
                    .toolbar { Button("Done") { editing = nil } }
                    .alert("Could not save", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                        Button("OK") { error = nil }
                    } message: { Text(error ?? "") }
            }
        }
    }

    @discardableResult
    private func setTopic(_ name: String, present: Bool) -> Bool {
        guard let editing else { return false }
        do { try store.setJournalTopic(notebookID: editing, name: name, present: present); return true }
        catch { self.error = error.localizedDescription; return false }
    }
}
