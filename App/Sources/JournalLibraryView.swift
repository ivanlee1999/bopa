import NotableKit
import SwiftUI

struct JournalLibraryView: View {
    @EnvironmentObject private var store: NotebookStore
    @Environment(\.horizontalSizeClass) private var sizeClass
    let topics: Bool
    var allDates = false
    var initialTopic: String?
    var narrow = false
    let toggleSidebar: () -> Void
    let openNotebook: (String) -> Void
    var selectTopic: ((String) -> Void)?
    @State private var date = Date()
    @State private var selectedTopic: String?
    @State private var editing: String?
    @State private var error: String?
    @AppStorage("library.layout") private var layoutKey = "feed"

    private var layout: NotebookBrowserLayout { narrow ? .compact : .resolve(layoutKey, compact: sizeClass == .compact) }
    private var topicNames: [String: String] {
        var names: [String: String] = [:]
        for entry in store.journalEntries.values {
            for (key, topic) in entry.topics where topic.present {
                if names[key] == nil || names[key]!.utf8.lexicographicallyPrecedes(topic.name.utf8) { names[key] = topic.name }
            }
        }
        return names
    }
    private var allTopics: [String] { topicNames.keys.sorted() }
    private var day: String {
        let format = DateFormatter(); format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd"; return format.string(from: date)
    }
    private var entries: [NotebookManifest] {
        store.search("").notebooks.filter { notebook in
            guard let entry = store.journalEntries[notebook.notebookId] else { return false }
            if topics { return selectedTopic.map { entry.topics[$0]?.present == true } ?? false }
            return entry.date != nil && (allDates || entry.date == day)
        }.sorted { (store.journalEntries[$0.notebookId]?.createdAt ?? 0) > (store.journalEntries[$1.notebookId]?.createdAt ?? 0) }
    }
    private var dates: [String] { Array(Set(entries.compactMap { store.journalEntries[$0.notebookId]?.date })).sorted(by: >) }
    private var title: String { topics ? selectedTopic.map { "#\(topicNames[$0] ?? $0)" } ?? "Tags" : allDates ? "Journal" : "Today" }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: toggleSidebar) { Image(systemName: "sidebar.left").frame(width: 44, height: 44) }.accessibilityLabel("Browse")
                Text(title).font(.title2).frame(maxWidth: .infinity, alignment: .leading)
                Menu {
                    Picker("Preview layout", selection: $layoutKey) {
                        ForEach(NotebookBrowserLayout.allCases.filter { sizeClass != .compact || $0 != .overview }) { item in
                            Text(item.title).tag(item.rawValue)
                        }
                    }
                } label: { Image(systemName: "rectangle.grid.2x2").frame(width: 44, height: 44) }
                    .accessibilityLabel("Preview layout")
                Button("Write") {
                    do {
                        let note = try store.createJournalEntry(topic: topics ? selectedTopic.flatMap { topicNames[$0] } : nil)
                        date = Date(); openNotebook(note.notebookId)
                    } catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent).tint(Modernist.ink)
            }.padding(.horizontal, 16).padding(.vertical, 8)
            if !topics && !allDates {
                DatePicker("Journal date", selection: $date, displayedComponents: .date)
                    .padding(.horizontal, 20).padding(.bottom, 10)
            }
            ModernistRule()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if topics && selectedTopic == nil {
                        ForEach(allTopics, id: \.self) { topic in
                            Button("#\(topicNames[topic] ?? topic)") { selectedTopic = topic }
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        }
                    } else {
                        if topics { Button("All tags") { selectedTopic = nil } }
                        ForEach(dates, id: \.self) { group in
                            if allDates || topics { Text(group).font(.subheadline).foregroundStyle(.secondary) }
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16, alignment: .top), count: layout.columns), alignment: .leading, spacing: 16) {
                                ForEach(entries.filter { store.journalEntries[$0.notebookId]?.date == group }, id: \.notebookId) { note in
                                    NotebookContentCard(notebook: note, layout: layout, edit: { pageID in
                                        if let pageID { store.rememberOpenedPage(pageID, in: note.notebookId) }
                                        openNotebook(note.notebookId)
                                    }, topic: { if let selectTopic { selectTopic(journalTopicKey($0)) } else { selectedTopic = journalTopicKey($0) } },
                                    accessory: AnyView(Button { editing = note.notebookId } label: { Image(systemName: "number").frame(width: 44, height: 44) }.accessibilityLabel("Edit tags")))
                                }
                            }
                        }
                        // Tagged older notebooks need no journal date to belong to a tag.
                        if topics {
                            ForEach(entries.filter { store.journalEntries[$0.notebookId]?.date == nil }, id: \.notebookId) { note in
                                NotebookContentCard(notebook: note, layout: layout, edit: { pageID in
                                    if let pageID { store.rememberOpenedPage(pageID, in: note.notebookId) }; openNotebook(note.notebookId)
                                })
                            }
                        }
                        if entries.isEmpty { Text("No notes").foregroundStyle(.secondary) }
                    }
                    if let message = store.journalError { Text(message).foregroundStyle(.red) }
                }.padding(20)
            }
        }.background(Modernist.paper)
            .onAppear { selectedTopic = initialTopic }
            .onChange(of: initialTopic) { _, value in selectedTopic = value }
            .alert("Could not save", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") { error = nil } } message: { Text(error ?? "") }
            .sheet(isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
                if let editing { JournalTagsSheet(notebookID: editing) }
            }
    }
}

struct JournalTagsSheet: View {
    @EnvironmentObject private var store: NotebookStore
    @Environment(\.dismiss) private var dismiss
    let notebookID: String
    @State private var name = ""
    @State private var error: String?

    private var names: [String] {
        Array(Set(store.journalEntries.values.flatMap(\.visibleTopics)))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    private func selected(_ name: String) -> Bool {
        store.journalEntries[notebookID]?.visibleTopics.contains {
            journalTopicKey($0) == journalTopicKey(name)
        } == true
    }
    var body: some View {
        NavigationStack {
            Form {
                ForEach(names, id: \.self) { topic in
                    Button { set(topic, !selected(topic)) } label: {
                        HStack { Text("#\(topic)"); Spacer(); if selected(topic) { Image(systemName: "checkmark") } }
                    }
                }
                HStack {
                    TextField("Find or create a tag", text: $name)
                        .textInputAutocapitalization(.never)
                        .onSubmit { if set(name, true) { name = "" } }
                    Button("Add") { if set(name, true) { name = "" } }
                        .disabled(journalTopicName(name).isEmpty)
                }
            }.navigationTitle("Tags")
                .toolbar { Button("Done") { dismiss() } }
                .alert("Could not save tag", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                    Button("OK") { error = nil }
                } message: { Text(error ?? "") }
        }
    }
    @discardableResult private func set(_ name: String, _ present: Bool) -> Bool {
        do { try store.setJournalTopic(notebookID: notebookID, name: name, present: present); return true }
        catch { self.error = error.localizedDescription; return false }
    }
}
