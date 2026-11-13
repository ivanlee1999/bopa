import Foundation

public struct JournalTopic: Codable, Equatable, Sendable {
    public var name: String
    public var present: Bool
    public var counter: Int64
    public var writer: String

    public init(name: String, present: Bool, counter: Int64, writer: String) {
        self.name = name; self.present = present; self.counter = counter; self.writer = writer
    }
}

public struct JournalOrganization: Codable, Equatable, Sendable {
    public var type = "journal"
    public var schema = 1
    public var notebookId: String
    public var date: String?
    public var createdAt: Int64
    public var topics: [String: JournalTopic]
    private enum CodingKeys: String, CodingKey {
        case type, schema, notebookId, date, createdAt, topics
        case documentID = "_id", deleted = "_deleted"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        type = try values.decode(String.self, forKey: .type)
        schema = try values.decode(Int.self, forKey: .schema)
        notebookId = try values.decode(String.self, forKey: .notebookId)
        guard values.contains(.date) else { throw JournalOrganizationError.invalidRecord }
        date = try values.decodeIfPresent(String.self, forKey: .date)
        createdAt = try values.decode(Int64.self, forKey: .createdAt)
        topics = try values.decode([String: JournalTopic].self, forKey: .topics)
        guard try values.decode(String.self, forKey: .documentID) == documentID else {
            throw JournalOrganizationError.invalidRecord
        }
        if values.contains(.deleted), try values.decode(Bool.self, forKey: .deleted) {
            throw JournalOrganizationError.invalidRecord
        }
        try validate()
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(type, forKey: .type); try values.encode(schema, forKey: .schema)
        try values.encode(documentID, forKey: .documentID)
        try values.encode(notebookId, forKey: .notebookId); try values.encode(createdAt, forKey: .createdAt)
        try values.encode(topics, forKey: .topics)
        if let date { try values.encode(date, forKey: .date) } else { try values.encodeNil(forKey: .date) }
    }

    public init(notebookId: String, date: String?, createdAt: Int64,
                topics: [String: JournalTopic] = [:]) {
        self.notebookId = notebookId; self.date = date; self.createdAt = createdAt; self.topics = topics
    }

    public var documentID: String { "journal:\(notebookId)" }
    public var visibleTopics: [String] {
        topics.sorted { journalLess($0.key, $1.key) }.compactMap { $0.value.present ? $0.value.name : nil }
    }

    public func validate() throws {
        guard type == "journal", schema == 1, journalIdentifier(notebookId),
              createdAt >= 0, createdAt <= journalMaxCounter else {
            throw JournalOrganizationError.invalidRecord
        }
        if let date {
            guard date.utf8.count == 10, let parsed = journalDateParser.date(from: date),
                  journalDateParser.string(from: parsed) == date else { throw JournalOrganizationError.invalidRecord }
        }
        for (key, topic) in topics {
            let clean = topic.name.unicodeScalars.split { [9, 10, 11, 12, 13, 32].contains($0.value) }
                .map(String.init).joined(separator: " ").precomposedStringWithCanonicalMapping
            guard !key.isEmpty, journalEqual(clean, topic.name), journalEqual(journalFold(topic.name), key),
                  topic.counter >= 0, topic.counter <= journalMaxCounter, journalIdentifier(topic.writer) else {
                throw JournalOrganizationError.invalidRecord
            }
        }
    }
}

public enum JournalOrganizationError: Error, LocalizedError {
    case invalidRecord, counterExhausted, missingRecord, server(Int), conflict, deletedRecord
    public var isRetriable: Bool {
        switch self {
        case .server(let status): status >= 500 || [408, 425, 429].contains(status)
        case .conflict: true
        default: false
        }
    }
    public var errorDescription: String? {
        switch self {
        case .invalidRecord: "Journal metadata is unreadable. The original data has been preserved."
        case .counterExhausted: "Journal revision limit reached."
        case .missingRecord: "The journal note could not be found."
        case .server(let status): "Journal sync failed (HTTP \(status)). Check the organization database and permissions."
        case .conflict: "Journal sync changed repeatedly. Your edits are saved and will retry."
        case .deletedRecord: "Journal metadata was deleted on the server. Local dates and tags have been preserved."
        }
    }
}

private let journalMaxCounter: Int64 = 9_007_199_254_740_991
private func journalLess(_ a: String, _ b: String) -> Bool { a.utf8.lexicographicallyPrecedes(b.utf8) }
private func journalEqual(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }
private func journalIdentifier(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0)
        || (97...122).contains($0) || [45, 46, 95].contains($0) }
}
private var journalDateParser: DateFormatter {
    let format = DateFormatter()
    format.locale = Locale(identifier: "en_US_POSIX")
    format.timeZone = TimeZone(secondsFromGMT: 0)
    format.dateFormat = "yyyy-MM-dd"
    format.isLenient = false
    return format
}

public func journalTopicName(_ value: String) -> String {
    let whitespace: Set<UInt32> = [9, 10, 11, 12, 13, 32]
    var value = value.unicodeScalars.split { whitespace.contains($0.value) }.map(String.init).joined(separator: " ")
    if value.hasPrefix("#") { value.removeFirst() }
    return value.unicodeScalars.split { whitespace.contains($0.value) }.map(String.init)
        .joined(separator: " ").precomposedStringWithCanonicalMapping
}

public func journalTopicKey(_ value: String) -> String {
    journalFold(journalTopicName(value))
}

/// A stored canonical label may itself begin with #; only raw tag-field input strips it.
public func journalTopicCanonicalKey(_ name: String) -> String { journalFold(name) }

private func journalFold(_ value: String) -> String {
    String(String.UnicodeScalarView(value.unicodeScalars.map {
        (65...90).contains($0.value) ? UnicodeScalar($0.value + 32)! : $0
    })).precomposedStringWithCanonicalMapping
}

public func mergeJournalOrganization(_ a: JournalOrganization, _ b: JournalOrganization) throws -> JournalOrganization {
    try a.validate(); try b.validate()
    guard a.notebookId == b.notebookId else { throw JournalOrganizationError.invalidRecord }
    var merged = a
    let capture: JournalOrganization
    if a.date == nil && b.date != nil { capture = b }
    else if b.date == nil && a.date != nil { capture = a }
    else if a.createdAt != b.createdAt { capture = a.createdAt < b.createdAt ? a : b }
    else { capture = journalLess(a.date ?? "", b.date ?? "") ? a : b }
    merged.date = capture.date; merged.createdAt = capture.createdAt
    for (key, incoming) in b.topics {
        guard let current = merged.topics[key] else { merged.topics[key] = incoming; continue }
        let incomingWins: Bool
        if current.counter != incoming.counter { incomingWins = current.counter < incoming.counter }
        else if !journalEqual(current.writer, incoming.writer) { incomingWins = journalLess(current.writer, incoming.writer) }
        else if current.present != incoming.present { incomingWins = !incoming.present }
        else { incomingWins = journalLess(current.name, incoming.name) }
        if incomingWins { merged.topics[key] = incoming }
    }
    return merged
}

/// One atomic file is the durable desired state; sync never acknowledges away edits in flight.
public final class JournalOrganizationStore: @unchecked Sendable {
    private struct State: Codable {
        var writer: String
        var counter: Int64
        var entries: [String: JournalOrganization]
    }
    private let url: URL
    private let lock = NSLock()
    private var state: State

    public init(rootURL: URL) throws {
        url = rootURL.appendingPathComponent(".bopa-organization.json")
        if FileManager.default.fileExists(atPath: url.path) {
            state = try JSONDecoder().decode(State.self, from: Data(contentsOf: url))
            guard state.counter >= 0, state.counter <= journalMaxCounter, journalIdentifier(state.writer) else {
                throw JournalOrganizationError.invalidRecord
            }
            for (id, entry) in state.entries {
                try entry.validate()
                guard id == entry.notebookId else { throw JournalOrganizationError.invalidRecord }
            }
        } else {
            state = State(writer: UUID().uuidString.lowercased(), counter: 0, entries: [:])
            try save(state)
        }
    }

    public func entries() -> [String: JournalOrganization] { lock.withLock { state.entries } }

    @discardableResult
    public func merge(_ incoming: JournalOrganization) throws -> JournalOrganization {
        try lock.withLock {
            try incoming.validate()
            var next = state
            let merged = try state.entries[incoming.notebookId].map { try mergeJournalOrganization($0, incoming) } ?? incoming
            next.entries[incoming.notebookId] = merged
            next.counter = max(next.counter, merged.topics.values.map(\.counter).max() ?? 0)
            if next.entries != state.entries || next.counter != state.counter { try save(next); state = next }
            return merged
        }
    }

    public func capture(notebookID: String, at date: Date, timeZone: TimeZone = .current) throws {
        let formatter = journalDateParser; formatter.timeZone = timeZone
        let entry = JournalOrganization(notebookId: notebookID, date: formatter.string(from: date),
                                        createdAt: Int64(date.timeIntervalSince1970 * 1000))
        _ = try merge(entry)
    }

    public func setTopic(notebookID: String, name: String, present: Bool, createdAt: Int64) throws {
        try lock.withLock {
            let existing = state.entries.values.flatMap { Array($0.topics) }.first { $0.value.name == name }
            let name = existing?.value.name ?? journalTopicName(name)
            let key = existing?.key ?? journalFold(name)
            guard !key.isEmpty else { throw JournalOrganizationError.invalidRecord }
            var next = state
            let observed = state.entries.values.flatMap { $0.topics.values }.map(\.counter).max() ?? 0
            guard max(next.counter, observed) < journalMaxCounter else { throw JournalOrganizationError.counterExhausted }
            next.counter = max(next.counter, observed) + 1
            var entry = next.entries[notebookID] ?? JournalOrganization(notebookId: notebookID, date: nil, createdAt: createdAt)
            let knownName = entry.topics[key]?.name ?? name
            entry.topics[key] = JournalTopic(name: knownName, present: present, counter: next.counter, writer: next.writer)
            try entry.validate()
            next.entries[notebookID] = entry
            try save(next); state = next
        }
    }

    /// Revisions are per assignment, including assignments on notes in the Trash. Publish the
    /// complete rename in one atomic write so a failure cannot remove half the old assignments.
    public func renameTopic(key: String, to name: String, notebookIDs: Set<String>? = nil) throws {
        try updateTopic(key: key, replacement: name, notebookIDs: notebookIDs)
    }

    public func removeTopic(key: String, notebookIDs: Set<String>? = nil) throws {
        try updateTopic(key: key, replacement: nil, notebookIDs: notebookIDs)
    }

    /// Automatic suggestions never replace a manual assignment or its removal tombstone.
    @discardableResult
    public func addAutomaticTopics(notebookID: String, names: [String], createdAt: Int64) throws -> Bool {
        try lock.withLock {
            var next = state
            var entry = next.entries[notebookID] ?? JournalOrganization(notebookId: notebookID, date: nil, createdAt: createdAt)
            var additions: [String: String] = [:]
            for raw in names {
                // Matcher output is canonical label text, not raw tag-field input. A leading
                // hash can be part of an existing label and must retain its own synced key.
                let name = raw.unicodeScalars.split { [9, 10, 11, 12, 13, 32].contains($0.value) }
                    .map(String.init).joined(separator: " ").precomposedStringWithCanonicalMapping
                let key = journalFold(name)
                guard !key.isEmpty, entry.topics[key] == nil else { continue }
                additions[key] = name
            }
            guard !additions.isEmpty else { return false }
            let observed = state.entries.values.flatMap { $0.topics.values }.map(\.counter).max() ?? 0
            guard max(next.counter, observed) < journalMaxCounter else { throw JournalOrganizationError.counterExhausted }
            next.counter = max(next.counter, observed) + 1
            for (key, name) in additions {
                entry.topics[key] = JournalTopic(name: name, present: true, counter: next.counter, writer: next.writer)
            }
            try entry.validate(); next.entries[notebookID] = entry
            try save(next); state = next
            return true
        }
    }

    private func updateTopic(key: String, replacement: String?, notebookIDs: Set<String>?) throws {
        try lock.withLock {
            guard !key.isEmpty else { throw JournalOrganizationError.invalidRecord }
            let name = replacement.map(journalTopicName)
            if let name, name.isEmpty { throw JournalOrganizationError.invalidRecord }
            let target = name.map(journalFold)
            let destinationName = target == key ? name : target.flatMap { target in
                state.entries.filter { notebookIDs?.contains($0.key) != false }.values
                    .compactMap { $0.topics[target] }.filter(\.present)
                    .map(\.name).sorted(by: journalLess).first
            } ?? name
            let affected = state.entries.filter { id, entry in
                guard notebookIDs?.contains(id) != false else { return false }
                guard let topic = entry.topics[key], topic.present else { return false }
                return name.map { !journalEqual(topic.name, $0) } ?? true
            }
            guard !affected.isEmpty else { return }
            var next = state
            let observed = state.entries.values.flatMap { $0.topics.values }.map(\.counter).max() ?? 0
            guard max(next.counter, observed) < journalMaxCounter else { throw JournalOrganizationError.counterExhausted }
            next.counter = max(next.counter, observed) + 1
            for (id, original) in affected {
                var entry = original
                if target != key {
                    var removed = entry.topics[key]!
                    removed.present = false; removed.counter = next.counter; removed.writer = next.writer
                    entry.topics[key] = removed
                }
                if let destinationName, let target, target == key || entry.topics[target]?.present != true {
                    entry.topics[target] = JournalTopic(name: destinationName, present: true, counter: next.counter, writer: next.writer)
                }
                try entry.validate()
                next.entries[id] = entry
            }
            try save(next); state = next
        }
    }

    private func save(_ value: State) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}

public actor JournalOrganizationSync {
    private let client: CouchDBClient
    private let store: JournalOrganizationStore
    private var running: Task<Void, Error>?
    private nonisolated let lifetime = JournalSyncLifetime()

    public init(client: CouchDBClient, store: JournalOrganizationStore) {
        self.client = client; self.store = store
    }

    public nonisolated func retire() { lifetime.retire() }

    public func sync() async throws {
        try lifetime.check()
        if let running { try await running.value; return }
        let task = Task { try await self.performSync() }
        running = task
        lifetime.register(task)
        do {
            try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
            running = nil
        }
        catch { running = nil; throw error }
    }

    private func performSync() async throws {
        try lifetime.check()
        let response = try await client.transport.send(HTTPRequest(method: "GET", path: "/\(client.database)/_all_docs",
            query: [HTTPQueryItem("include_docs", "true"), HTTPQueryItem("startkey", "\"journal:\""),
                    HTTPQueryItem("endkey", "\"journal:\u{fff0}\"")]))
        guard response.status == 200 else { throw JournalOrganizationError.server(response.status) }
        struct Row: Decodable { var id: String; var doc: JournalOrganization? }
        struct Rows: Decodable { var rows: [Row] }
        let rows = try JSONDecoder().decode(Rows.self, from: response.body).rows
        try Task.checkCancellation()
        // Validate the complete snapshot before applying any of it.
        for row in rows {
            guard let doc = row.doc, row.id == doc.documentID else { throw JournalOrganizationError.invalidRecord }
            try doc.validate()
        }
        try lifetime.withActive { for row in rows { _ = try store.merge(row.doc!) } }
        for id in try lifetime.withActive({ store.entries().keys.sorted() }) {
            for attempt in 0..<4 {
                try Task.checkCancellation()
                try lifetime.check()
                let remote = try await client.get("journal:\(id)", as: JournalOrganization.self)
                if remote?.deleted == true { throw JournalOrganizationError.deletedRecord }
                let current = try lifetime.withActive {
                    if let remote {
                        guard remote.body.documentID == "journal:\(id)" else { throw JournalOrganizationError.invalidRecord }
                        _ = try store.merge(remote.body)
                    }
                    guard let current = store.entries()[id] else { throw JournalOrganizationError.missingRecord }
                    return current
                }
                if remote?.body == current { break }
                try lifetime.check()
                do { try await client.put(current.documentID, rev: remote?.rev, body: current); break }
                catch CouchError.conflict {
                    if attempt == 3 { throw JournalOrganizationError.conflict }
                }
            }
        }
    }
}

private final class JournalSyncLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    private var task: Task<Void, Error>?
    func retire() { lock.withLock { active = false; task?.cancel() } }
    func register(_ task: Task<Void, Error>) {
        lock.withLock { if active { self.task = task } else { task.cancel() } }
    }
    func check() throws { try withActive {} }
    func withActive<T>(_ body: () throws -> T) throws -> T {
        try lock.withLock {
            guard active else { throw CancellationError() }
            return try body()
        }
    }
}
