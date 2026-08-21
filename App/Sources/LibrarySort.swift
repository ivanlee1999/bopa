import Foundation
import NotableKit

/// How the library is ordered.
///
/// The order used to be fixed: `NotebookStore.refresh` sorts by `updatedAt` descending and that was
/// that. Recently-edited-first is a good default and a bad only-option — finding a notebook by name
/// in a library of eighty meant reading eighty covers in the order they happened to be touched.
enum LibrarySortOrder: String, CaseIterable, Identifiable {
    case updated
    case created
    case title

    var id: String { rawValue }

    var label: String {
        switch self {
        case .updated: return "Last edited"
        case .created: return "Date created"
        case .title: return "Title"
        }
    }

    var symbolName: String {
        switch self {
        case .updated: return "clock"
        case .created: return "calendar"
        case .title: return "textformat"
        }
    }

    /// Whether the newest comes first. Only meaningful for the two date orders; a title sort is
    /// A→Z ascending and reversing it is what `descending` means there too.
    var defaultsToDescending: Bool { self != .title }
}

/// Ordering and filtering the library, kept out of the views so both columns — the grid and the
/// sidebar's tree — answer the same way, and so the rules are testable without a screen.
enum LibrarySort {
    static func notebooks(
        _ notebooks: [NotebookManifest], by order: LibrarySortOrder, descending: Bool
    ) -> [NotebookManifest] {
        let sorted: [NotebookManifest]
        switch order {
        case .updated:
            sorted = notebooks.sorted { ($0.updatedAt, $0.title) < ($1.updatedAt, $1.title) }
        case .created:
            sorted = notebooks.sorted { ($0.createdAt, $0.title) < ($1.createdAt, $1.title) }
        case .title:
            sorted = notebooks.sorted { compare($0.title, $1.title, tie: ($0.notebookId, $1.notebookId)) }
        }
        return descending ? sorted.reversed() : sorted
    }

    static func folders(
        _ folders: [FolderDTO], by order: LibrarySortOrder, descending: Bool
    ) -> [FolderDTO] {
        let sorted: [FolderDTO]
        switch order {
        case .updated:
            sorted = folders.sorted { ($0.updatedAt, $0.title) < ($1.updatedAt, $1.title) }
        case .created:
            sorted = folders.sorted { ($0.createdAt, $0.title) < ($1.createdAt, $1.title) }
        case .title:
            sorted = folders.sorted { compare($0.title, $1.title, tie: ($0.id, $1.id)) }
        }
        return descending ? sorted.reversed() : sorted
    }

    /// Orders two titles the way a reader expects.
    ///
    /// `localizedStandardCompare` rather than comparing lowercased strings: `<` on `String` orders
    /// by code point, which files "Éclair" after "zebra" — and it is also what gets "Page 10"
    /// after "Page 2" instead of after "Page 1". The id breaks ties so two notebooks with the same
    /// name do not swap places between launches.
    private static func compare(_ lhs: String, _ rhs: String, tie: (String, String)) -> Bool {
        switch lhs.localizedStandardCompare(rhs) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame: return tie.0 < tie.1
        }
    }

    /// Whether [title] answers [query].
    ///
    /// Diacritic- and case-insensitive substring matching, not prefix: people search for the word
    /// they remember from the middle of a title as readily as for how it starts. The empty query
    /// matches everything.
    ///
    /// Titles only. Handwriting is searched too, but through recognized text
    /// (`NotebookStore.notebooksMatchingText`), which needs a file per page rather than a string.
    static func matches(title: String, query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return true }
        return title.range(
            of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}
