import NotableKit
import SwiftUI

struct JournalLibraryView: View {
    @EnvironmentObject private var store: NotebookStore
    @Environment(\.horizontalSizeClass) private var sizeClass
    let topics: Bool
    var allDates = false
    var initialTopic: String?
    var narrow = false
    var navigationRevision = 0
    let toggleSidebar: () -> Void
    let openNotebook: (String) -> Void
    var selectTopic: ((String) -> Void)?
    var showAllTopics: (() -> Void)?
    @State private var selectedDay = JournalDate.key(Date())
    @State private var showingCalendar = false
    @State private var jumpRevision = 0
    @State private var selectedTopic: String?
    @State private var editing: String?
    @State private var trashTarget: NotebookManifest?
    @State private var showingTrash = false
    @State private var managingTags = false
    @State private var error: String?
    @AppStorage("library.layout") private var layoutKey = "feed"
    @AppStorage("library.previewContent") private var previewContent = "ink"

    private var layout: NotebookBrowserLayout { narrow ? .compact : .resolve(layoutKey, compact: sizeClass == .compact) }
    private var topicNames: [String: String] {
        var names: [String: String] = [:]
        let existing = Set(store.notebooks.map(\.notebookId))
        for entry in store.journalEntries.values where existing.contains(entry.notebookId) {
            for (key, topic) in entry.topics where topic.present {
                if names[key] == nil || topic.name.utf8.lexicographicallyPrecedes(names[key]!.utf8) { names[key] = topic.name }
            }
        }
        return names
    }
    private var allTopics: [String] { topicNames.keys.sorted() }
    private var entries: [NotebookManifest] {
        store.search("").notebooks.filter { notebook in
            guard let entry = store.journalEntries[notebook.notebookId] else { return false }
            if topics { return selectedTopic.map { entry.topics[$0]?.present == true } ?? false }
            return entry.date != nil
        }.sorted {
            let a = store.journalEntries[$0.notebookId]?.createdAt ?? 0, b = store.journalEntries[$1.notebookId]?.createdAt ?? 0
            return a == b ? $0.notebookId < $1.notebookId : a > b
        }
    }
    private var groups: [String: [NotebookManifest]] {
        Dictionary(grouping: entries.filter { store.journalEntries[$0.notebookId]?.date != nil }) {
            store.journalEntries[$0.notebookId]!.date!
        }
    }
    private var dates: [String] { Array(Set(groups.keys).union(topics ? [] : [selectedDay])).sorted(by: >) }
    private var title: String { topics ? selectedTopic.map { "#\(topicNames[$0] ?? $0)" } ?? "Tags" : "Journal" }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: toggleSidebar) { Image(systemName: "sidebar.left").frame(width: 44, height: 44) }.accessibilityLabel("Browse")
                Text(title).font(.title2).frame(maxWidth: .infinity, alignment: .leading).accessibilityIdentifier("journal.title")
                Menu {
                    Button("Manage tags") { managingTags = true }
                    Button("Trash") { showingTrash = true }
                } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                    .accessibilityLabel("Journal actions").accessibilityIdentifier("journal.actions")
                Menu {
                    Picker("Preview layout", selection: $layoutKey) {
                        ForEach(NotebookBrowserLayout.allCases.filter { sizeClass != .compact || $0 != .overview }) { item in
                            Text(item.title).tag(item.rawValue)
                        }
                    }
                    Picker("Content", selection: $previewContent) {
                        Text("Ink").tag("ink"); Text("Text").tag("text")
                    }
                } label: { Image(systemName: "rectangle.grid.2x2").frame(width: 44, height: 44) }
                    .accessibilityLabel("Preview layout")
                Button("Write") {
                    do {
                        let note = try store.createJournalEntry(topic: topics ? selectedTopic.flatMap { topicNames[$0] } : nil)
                        jump(to: JournalDate.key(Date())); openNotebook(note.notebookId)
                    } catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent).tint(Modernist.ink)
            }.padding(.horizontal, 16).padding(.vertical, 8)
            if !topics {
                HStack {
                    Button { showingCalendar = true } label: {
                        Label(selectedDay, systemImage: "calendar").frame(minHeight: 44)
                    }.accessibilityIdentifier("journal.calendar")
                    Spacer()
                    Button("Today") { jump(to: JournalDate.key(Date())) }.frame(minHeight: 44)
                        .accessibilityIdentifier("journal.today")
                }.padding(.horizontal, 20)
            }
            ModernistRule()
            ScrollViewReader { proxy in
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
                            Text(group).font(.subheadline).foregroundStyle(.secondary).id(group)
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16, alignment: .top), count: layout.columns), alignment: .leading, spacing: 16) {
                                ForEach(groups[group] ?? [], id: \.notebookId) { note in
                                    card(note)
                                }
                            }
                            if groups[group]?.isEmpty != false { Text("No notes").foregroundStyle(.secondary) }
                        }
                        // Tagged older notebooks need no journal date to belong to a tag.
                        if topics {
                            ForEach(entries.filter { store.journalEntries[$0.notebookId]?.date == nil }, id: \.notebookId) { note in
                                card(note)
                            }
                        }
                        if entries.isEmpty && topics { Text("No notes").foregroundStyle(.secondary) }
                    }
                    if let message = store.journalError { Text(message).foregroundStyle(.red) }
                }.padding(20)
            }
            .task(id: "\(selectedDay)#\(jumpRevision)") { await Task.yield(); if !topics { proxy.scrollTo(selectedDay, anchor: .top) } }
            .accessibilityIdentifier("journal.timeline")
            .onChange(of: navigationRevision) { _, _ in
                if !topics && !allDates { jump(to: JournalDate.key(Date())) }
            }
            }
        }.background(Modernist.paper)
            .onAppear { selectedTopic = initialTopic }
            .onChange(of: initialTopic) { _, value in selectedTopic = value }
            .alert("Could not save", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") { error = nil } } message: { Text(error ?? "") }
            .sheet(isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
                if let editing { JournalTagsSheet(notebookID: editing) }
            }
            .sheet(isPresented: $showingCalendar) {
                JournalCalendar(counts: groups.mapValues(\.count), selectedDay: selectedDay) {
                    jump(to: $0); showingCalendar = false
                }
            }
            .sheet(isPresented: $managingTags, onDismiss: {
                if let selectedTopic, topicNames[selectedTopic] == nil {
                    self.selectedTopic = nil; showAllTopics?()
                }
            }) { JournalTagManager() }
            .sheet(isPresented: $showingTrash) { NavigationStack { TrashView() } }
            .confirmationDialog("Move to Trash?", isPresented: Binding(get: { trashTarget != nil }, set: { if !$0 { trashTarget = nil } }), titleVisibility: .visible) {
                Button("Move to Trash", role: .destructive) {
                    guard let note = trashTarget else { return }
                    do { try store.trashJournalNotebook(id: note.notebookId) }
                    catch { self.error = error.localizedDescription }
                    trashTarget = nil
                }.accessibilityIdentifier("journal.trashConfirm")
                Button("Cancel", role: .cancel) { trashTarget = nil }
            } message: {
                let count = trashTarget?.pageIds.count ?? 0
                Text("\(trashTarget?.title ?? "Note")\(count > 1 ? " · \(count) pages" : ""). Restore from Trash.")
            }
    }

    private func jump(to day: String) { selectedDay = day; jumpRevision += 1 }

    private func card(_ note: NotebookManifest) -> some View {
        NotebookContentCard(notebook: note, layout: layout, edit: { pageID in
            if let pageID { store.rememberOpenedPage(pageID, in: note.notebookId) }
            openNotebook(note.notebookId)
        }, topic: { if let selectTopic { selectTopic(journalTopicCanonicalKey($0)) } else { selectedTopic = journalTopicCanonicalKey($0) } },
        accessory: AnyView(Menu {
            Button("Edit tags") { editing = note.notebookId }
            Button("Move to Trash", role: .destructive) { trashTarget = note }
        } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
            .accessibilityLabel("Note actions \(note.title)")
            .accessibilityIdentifier("journal.noteMenu.\(note.notebookId)")))
    }
}

struct JournalTagsSheet: View {
    @EnvironmentObject private var store: NotebookStore
    @Environment(\.dismiss) private var dismiss
    let notebookID: String
    @State private var name = ""
    @State private var error: String?

    private var names: [String] {
        var canonical: [String: String] = [:]
        for entry in store.journalEntries.values {
            for (key, topic) in entry.topics where topic.present {
                if canonical[key] == nil || topic.name.utf8.lexicographicallyPrecedes(canonical[key]!.utf8) { canonical[key] = topic.name }
            }
        }
        return canonical.values.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    private func selected(_ name: String) -> Bool {
        store.journalEntries[notebookID]?.visibleTopics.contains {
            journalTopicCanonicalKey($0) == journalTopicCanonicalKey(name)
        } == true
    }
    var body: some View {
        NavigationStack {
            Form {
                HStack {
                    TextField("Find or create a tag", text: $name)
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("tags.name")
                        .onSubmit { if set(name, true) { name = "" } }
                    Button("Add") { if set(name, true) { name = "" } }
                        .disabled(journalTopicName(name).isEmpty)
                        .accessibilityIdentifier("tags.add")
                }
                ForEach(names.filter { name.isEmpty || $0.localizedCaseInsensitiveContains(journalTopicName(name)) }, id: \.self) { topic in
                    Button { if set(topic, !selected(topic)) { name = "" } } label: {
                        HStack { Text("#\(topic)"); Spacer(); if selected(topic) { Image(systemName: "checkmark") } }
                    }
                }
            }.navigationTitle("Tags")
                .toolbar { Button("Done") { dismiss() }.accessibilityIdentifier("tags.edit.done") }
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
