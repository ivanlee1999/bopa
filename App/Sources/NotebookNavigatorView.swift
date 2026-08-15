import NotableKit
import SwiftUI

/// The three ways into a long notebook: its pages, its table of contents, and the pages you
/// starred.
///
/// One panel with three tabs rather than three separate screens, because that is what a reader
/// reaches for as one gesture — "where am I, and where do I want to be". Goodnotes' sidebar and the
/// BOOX reader's own TOC panel arrived at the same three independently, which is a strong enough
/// signal to follow rather than invent a fourth arrangement.
struct NotebookNavigatorView: View {
    /// Which way into the notebook is showing.
    enum Tab: String, CaseIterable, Identifiable {
        case pages, outline, bookmarks
        var id: String { rawValue }

        var title: String {
            switch self {
            case .pages: "Pages"
            case .outline: "Outline"
            case .bookmarks: "Bookmarks"
            }
        }
    }

    @EnvironmentObject private var store: NotebookStore
    @Environment(\.dismiss) private var dismiss

    let notebookId: String
    let currentPageId: String?
    let openPage: (String) -> Void

    /// Kept across presentations: a reader who navigates by outline wants the outline again next
    /// time, and re-picking the tab on every open is the kind of small tax that makes a panel
    /// feel like a detour.
    @AppStorage("navigator.tab") private var tab: Tab = .pages
    @State private var actionError: LibraryActionError?
    @State private var outlineTitle = ""
    @State private var showingOutlinePrompt = false

    private var manifest: NotebookManifest? { store.manifest(id: notebookId) }

    private var isCurrentPageBookmarked: Bool {
        guard let currentPageId else { return false }
        return store.isBookmarked(notebookId: notebookId, pageId: currentPageId)
    }

    var body: some View {
        VStack(spacing: 0) {
            picker
            ModernistRule(heavy: true)
            content
        }
        .background(Modernist.paper)
        .navigationTitle(manifest?.title ?? "Notebook")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
            // Starring and outlining are the two things this panel is *for*, and they used to live
            // only in a page's long-press menu — which is to say they could not be found at all.
            // They sit in the header on every tab now: the reader is looking at the page they mean
            // when they reach for the panel, so "this page" is the useful subject.
            ToolbarItem(placement: .primaryAction) {
                Button {
                    toggleBookmark()
                } label: {
                    Image(systemName: isCurrentPageBookmarked ? "bookmark.fill" : "bookmark")
                }
                .disabled(currentPageId == nil)
                .accessibilityLabel(
                    isCurrentPageBookmarked ? "Remove bookmark" : "Bookmark this page")
                .accessibilityIdentifier("navigator.bookmark")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    promptForOutlineEntry()
                } label: {
                    Image(systemName: "list.bullet.indent")
                }
                .disabled(currentPageId == nil)
                .accessibilityLabel("Add this page to the outline")
                .accessibilityIdentifier("navigator.addOutline")
            }
            if tab == .pages {
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
        }
        .alert("Add to outline", isPresented: $showingOutlinePrompt) {
            TextField("Section name", text: $outlineTitle)
            Button("Add") {
                guard let currentPageId else { return }
                let trimmed = outlineTitle.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return }
                perform("Adding the outline entry", error: $actionError) {
                    try store.addOutlineEntry(
                        notebookId: notebookId, pageId: currentPageId, title: trimmed)
                }
                tab = .outline
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The entry jumps to this page. Nest it under another from the Outline tab.")
        }
        .libraryActionAlert($actionError)
    }

    private var picker: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases) { candidate in
                Button {
                    tab = candidate
                } label: {
                    VStack(spacing: 6) {
                        Text(candidate.title.uppercased())
                            .font(Modernist.font(11, .semibold))
                            .tracking(1.4)
                            .foregroundStyle(
                                candidate == tab ? Modernist.ink : Modernist.neutral700)
                        // The selected tab is marked by a rule under it, not by a filled pill:
                        // structure here is carried by ink weight, as everywhere else.
                        Rectangle()
                            .fill(candidate == tab ? Modernist.ink : Color.clear)
                            .frame(height: Modernist.ruleHeavy)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("navigator.tab.\(candidate.rawValue)")
            }
        }
        .padding(.top, 10)
        .background(Modernist.rail)
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .pages:
            PageOverviewView(
                notebookId: notebookId, currentPageId: currentPageId, openPage: open)
        case .outline:
            OutlineTabView(
                notebookId: notebookId, currentPageId: currentPageId, openPage: open)
        case .bookmarks:
            BookmarksTabView(
                notebookId: notebookId, currentPageId: currentPageId, openPage: open)
        }
    }

    private func open(_ pageId: String) {
        openPage(pageId)
        dismiss()
    }

    /// Seeded with the page's own name when it has one: an outline entry for a page called
    /// "Method" almost always wants to be called "Method".
    private func promptForOutlineEntry() {
        outlineTitle = ""
        if let currentPageId,
           let page = try? store.loadPage(notebookId: notebookId, pageId: currentPageId),
           let title = page.title {
            outlineTitle = title
        }
        showingOutlinePrompt = true
    }

    private func toggleBookmark() {
        guard let currentPageId else { return }
        let bookmarked = isCurrentPageBookmarked
        perform(bookmarked ? "Removing the bookmark" : "Bookmarking the page", error: $actionError) {
            try store.setBookmark(
                notebookId: notebookId, pageId: currentPageId, bookmarked: !bookmarked)
        }
    }
}

// MARK: - Outline

/// The notebook's table of contents: named entries, up to three levels deep, each jumping to a
/// page.
///
/// Entries are the reader's own — ink has no headings to extract — so this tab is empty until they
/// name something, and says so rather than showing a blank panel.
struct OutlineTabView: View {
    @EnvironmentObject private var store: NotebookStore

    let notebookId: String
    let currentPageId: String?
    let openPage: (String) -> Void

    @State private var renamingId: String?
    @State private var renameTitle = ""
    @State private var showingRename = false
    @State private var addTitle = ""
    @State private var showingAdd = false
    @State private var actionError: LibraryActionError?

    private var entries: [CouchOutlineEntry] { store.outline(in: notebookId) }
    private var pageNumbers: [String: Int] {
        let ids = store.manifest(id: notebookId)?.pageIds ?? []
        return Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0 + 1) })
    }

    var body: some View {
        Group {
            if entries.isEmpty {
                emptyState
            } else {
                // Deliberately not an editable List. `onMove` only works in edit mode, and edit
                // mode puts a red delete badge and a grabber on every row permanently — the exact
                // floating iOS chrome this design does without, and it would be the loudest thing
                // on the panel. Reordering is a menu action instead, which also survives the
                // reader having a pen in hand rather than a finger.
                List {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        row(entry, index: index)
                    }
                }
                .listStyle(.plain)
            }
        }
        .background(Modernist.paper)
        .alert("Rename entry", isPresented: $showingRename) {
            TextField("Section name", text: $renameTitle)
            Button("Rename") {
                guard let id = renamingId else { return }
                let trimmed = renameTitle.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return }
                perform("Renaming the outline entry", error: $actionError) {
                    try store.updateOutlineEntry(
                        notebookId: notebookId, entryId: id, title: trimmed)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Add to outline", isPresented: $showingAdd) {
            TextField("Section name", text: $addTitle)
            Button("Add") {
                guard let currentPageId else { return }
                let trimmed = addTitle.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return }
                perform("Adding the outline entry", error: $actionError) {
                    try store.addOutlineEntry(
                        notebookId: notebookId, pageId: currentPageId, title: trimmed)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The entry jumps to the page you have open.")
        }
        .libraryActionAlert($actionError)
    }

    private var emptyState: NavigatorEmptyState {
        let hasPage = currentPageId != nil
        var actionTitle: String?
        var action: (() -> Void)?
        if hasPage {
            actionTitle = "Add this page"
            action = { self.addCurrentPage() }
        }
        return NavigatorEmptyState(
            icon: "list.bullet.indent",
            title: "No outline yet",
            detail: "Name a section and it becomes an entry pointing at that page. Swipe an entry "
                + "to indent it, or hold it to rename and reorder.",
            actionTitle: actionTitle,
            action: action)
    }

    private func addCurrentPage() {
        guard let currentPageId else { return }
        addTitle = ""
        if let page = try? store.loadPage(notebookId: notebookId, pageId: currentPageId),
           let title = page.title {
            addTitle = title
        }
        showingAdd = true
    }

    private func row(_ entry: CouchOutlineEntry, index: Int) -> some View {
        Button {
            openPage(entry.pageId)
        } label: {
            HStack(spacing: 10) {
                Text(entry.title)
                    // Depth reads as weight as well as indent: on a washed-out panel an indent
                    // alone is easy to lose, and the heading/subheading distinction is the whole
                    // point of nesting.
                    .font(Modernist.font(entry.depth == 0 ? 15 : 14,
                                         entry.depth == 0 ? .semibold : .regular))
                    .foregroundStyle(Modernist.ink)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let number = pageNumbers[entry.pageId] {
                    Text("\(number)")
                        .font(Modernist.font(12).monospacedDigit())
                        .foregroundStyle(
                            entry.pageId == currentPageId ? Modernist.ink : Modernist.neutral700)
                }
            }
            .padding(.leading, CGFloat(entry.depth) * 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(Modernist.paper)
        .accessibilityIdentifier("outline.entry.\(entry.id)")
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                perform("Removing the outline entry", error: $actionError) {
                    try store.removeOutlineEntry(notebookId: notebookId, entryId: entry.id)
                }
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            // Nesting by drag needs a drop target per row and a gesture that fights the reorder
            // drag this list already uses; two buttons say the same thing and can be reached
            // one-handed on a tablet.
            Button {
                changeDepth(entry, by: 1)
            } label: {
                Label("Indent", systemImage: "arrow.right.to.line")
            }
            .disabled(entry.depth >= CouchOutlineEntry.maxDepth)
            Button {
                changeDepth(entry, by: -1)
            } label: {
                Label("Outdent", systemImage: "arrow.left.to.line")
            }
            .disabled(entry.depth <= 0)
        }
        .contextMenu {
            Button {
                renamingId = entry.id
                renameTitle = entry.title
                showingRename = true
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            Divider()
            Button {
                move(from: index, to: index - 1)
            } label: {
                Label("Move up", systemImage: "arrow.up")
            }
            .disabled(index == 0)
            Button {
                // Past the row below, not onto it — `moveOutlineEntry` removes before inserting,
                // so moving "down one" is an insert two positions along.
                move(from: index, to: index + 2)
            } label: {
                Label("Move down", systemImage: "arrow.down")
            }
            .disabled(index >= entries.count - 1)
            Divider()
            Button(role: .destructive) {
                perform("Removing the outline entry", error: $actionError) {
                    try store.removeOutlineEntry(notebookId: notebookId, entryId: entry.id)
                }
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
    }

    private func move(from source: Int, to destination: Int) {
        perform("Reordering the outline", error: $actionError) {
            try store.moveOutlineEntry(in: notebookId, from: source, to: destination)
        }
    }

    private func changeDepth(_ entry: CouchOutlineEntry, by delta: Int) {
        perform("Changing the outline level", error: $actionError) {
            try store.updateOutlineEntry(
                notebookId: notebookId, entryId: entry.id, depth: entry.depth + delta)
        }
    }
}

// MARK: - Bookmarks

/// The pages the reader starred, in page order.
///
/// Thumbnails rather than a list: a bookmark has no name — it is a page you recognised — so the
/// page itself is the only useful label, which is also why starring needs no prompt.
struct BookmarksTabView: View {
    @EnvironmentObject private var store: NotebookStore

    let notebookId: String
    let currentPageId: String?
    let openPage: (String) -> Void

    @State private var actionError: LibraryActionError?

    private var pageIds: [String] { store.bookmarkedPageIds(in: notebookId) }
    private var pageNumbers: [String: Int] {
        let ids = store.manifest(id: notebookId)?.pageIds ?? []
        return Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0 + 1) })
    }

    var body: some View {
        Group {
            if pageIds.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 18)],
                        alignment: .leading, spacing: 22
                    ) {
                        ForEach(pageIds, id: \.self) { pageId in
                            cell(pageId)
                        }
                    }
                    .padding(22)
                }
            }
        }
        .background(Modernist.paper)
        .libraryActionAlert($actionError)
    }

    private var emptyState: NavigatorEmptyState {
        let hasPage = currentPageId != nil
        var actionTitle: String?
        var action: (() -> Void)?
        if hasPage {
            actionTitle = "Bookmark this page"
            action = { self.bookmarkCurrentPage() }
        }
        return NavigatorEmptyState(
            icon: "bookmark",
            title: "No bookmarks yet",
            detail: "Star a page and it is listed here in page order. Bookmarks sync, so a page "
                + "you star here is starred on the BOOX too.",
            actionTitle: actionTitle,
            action: action)
    }

    private func bookmarkCurrentPage() {
        guard let currentPageId else { return }
        perform("Bookmarking the page", error: $actionError) {
            try store.setBookmark(notebookId: notebookId, pageId: currentPageId, bookmarked: true)
        }
    }

    private func cell(_ pageId: String) -> some View {
        Button {
            openPage(pageId)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    Rectangle().fill(.white)
                    if let image = ThumbnailRenderer.thumbnail(
                        notebookId: notebookId, pageId: pageId,
                        revision: store.manifest(id: notebookId)?.updatedAt ?? "", store: store) {
                        Image(uiImage: image).resizable().aspectRatio(contentMode: .fit)
                    }
                }
                .aspectRatio(3.0 / 4.0, contentMode: .fit)
                .overlay {
                    Rectangle().stroke(
                        Modernist.ink,
                        lineWidth: pageId == currentPageId
                            ? Modernist.ruleHeavy : Modernist.ruleHair)
                }
                Text(label(for: pageId))
                    .font(Modernist.font(12, .semibold))
                    .foregroundStyle(Modernist.ink)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("bookmarks.page.\(pageId)")
        .contextMenu {
            Button(role: .destructive) {
                perform("Removing the bookmark", error: $actionError) {
                    try store.setBookmark(
                        notebookId: notebookId, pageId: pageId, bookmarked: false)
                }
            } label: {
                Label("Remove bookmark", systemImage: "bookmark.slash")
            }
        }
    }

    private func label(for pageId: String) -> String {
        let title = try? store.loadPage(notebookId: notebookId, pageId: pageId).title
        if let title, !title.isEmpty { return title }
        return "Page \(pageNumbers[pageId] ?? 0)"
    }
}

// MARK: - Shared

/// What a tab shows before the reader has put anything in it. Says what to do, not just that
/// there is nothing — an empty outline is the normal starting state, not a fault.
///
/// It carries the action itself rather than describing where to find it. Prose that says "add one
/// from the menu in the Pages tab" is a treasure map, and the reader who is looking at an empty tab
/// is exactly the one who wants the button.
struct NavigatorEmptyState: View {
    let icon: String
    let title: String
    let detail: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Modernist.neutral500)
            Text(title)
                .font(Modernist.font(15, .semibold))
                .foregroundStyle(Modernist.ink)
            Text(detail)
                .font(Modernist.font(13))
                .foregroundStyle(Modernist.neutral700)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle.uppercased())
                        .font(Modernist.font(12, .semibold))
                        .tracking(1.2)
                        .foregroundStyle(Modernist.paper)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(Modernist.ink)
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
                .accessibilityIdentifier("navigator.emptyState.action")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}

extension CouchOutlineEntry: @retroactive Identifiable {}
