import Foundation
import NotableKit

/// A `pagetext:` document, as it travels. The shape is the contract in `docs/recognized-text.md`,
/// which the BOOX and the Obsidian plugin implement against too.
struct PageTextDocument: Codable, Equatable, Sendable {
    var _id: String
    var _rev: String?
    var pageId: String
    var notebookId: String?
    var pageTitle: String?
    var text: String
    var engine: String
    var language: String?
    /// The page's `updatedAt` the recognition ran against, copied verbatim.
    var recognizedClock: String
    var updatedAt: String
    var updatedBy: String

    init(
        id: String,
        rev: String? = nil,
        pageId: String,
        notebookId: String?,
        pageTitle: String?,
        text: String,
        engine: String,
        language: String?,
        recognizedClock: String,
        updatedAt: String,
        updatedBy: String
    ) {
        self._id = id
        self._rev = rev
        self.pageId = pageId
        self.notebookId = notebookId
        self.pageTitle = pageTitle
        self.text = text
        self.engine = engine
        self.language = language
        self.recognizedClock = recognizedClock
        self.updatedAt = updatedAt
        self.updatedBy = updatedBy
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        _id = try container.decodeIfPresent(String.self, forKey: ._id) ?? ""
        _rev = try container.decodeIfPresent(String.self, forKey: ._rev)
        pageId = try container.decodeIfPresent(String.self, forKey: .pageId) ?? ""
        notebookId = try container.decodeIfPresent(String.self, forKey: .notebookId)
        pageTitle = try container.decodeIfPresent(String.self, forKey: .pageTitle)
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        engine = try container.decodeIfPresent(String.self, forKey: .engine) ?? ""
        language = try container.decodeIfPresent(String.self, forKey: .language)
        recognizedClock = try container.decodeIfPresent(String.self, forKey: .recognizedClock) ?? ""
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt) ?? ""
        updatedBy = try container.decodeIfPresent(String.self, forKey: .updatedBy) ?? ""
    }
}

/// What a publish attempt did, so callers know whether the text is settled.
enum PublishOutcome: Equatable, Sendable {
    /// The server now holds this text.
    case published
    /// The server already held this text, or newer. Nothing to do, and nothing wrong.
    case alreadyCurrent
    /// The attempt failed. The text stays pending and is retried later.
    case failed
}

/// Publishes recognized text to the text database.
///
/// The write is guarded rather than blind: the two devices recognize the same ink with different
/// engines, and without a guard each would keep overwriting the other's result forever. Reading
/// the current document first, and standing down when it describes newer ink, bounds that race to
/// a single round. `docs/recognized-text.md` states the rule this implements.
///
/// Nothing here deletes. Text outliving its page is inert — nothing reads text for a page it does
/// not have — and the Obsidian plugin, which holds the whole library, prunes it.
struct PageTextPublisher: Sendable {
    let transport: any HTTPTransport
    let database: String
    let deviceID: String

    static func documentID(pageId: String) -> String { "pagetext:\(pageId)" }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    func publish(
        _ text: PageTextFile,
        notebookId: String?,
        pageTitle: String?
    ) async -> PublishOutcome {
        let documentID = Self.documentID(pageId: text.pageId)

        let remote: PageTextDocument?
        do {
            remote = try await fetch(documentID)
        } catch {
            return .failed
        }

        let local = PageTextDocument(
            id: documentID,
            rev: remote?._rev,
            pageId: text.pageId,
            notebookId: notebookId,
            pageTitle: pageTitle,
            text: text.text,
            engine: text.engine,
            language: text.language,
            recognizedClock: text.recognizedClock,
            updatedAt: text.updatedAt,
            updatedBy: deviceID)

        if let remote, !Self.supersedes(local, remote) { return .alreadyCurrent }

        do {
            let status = try await put(local)
            switch status {
            case 200...299:
                return .published
            case 409:
                // Someone wrote between the read and the write. Re-reading re-applies the guard,
                // and if their text describes newer ink this device stops rather than fighting.
                return try await retry(local)
            default:
                return .failed
            }
        } catch {
            return .failed
        }
    }

    private func retry(_ local: PageTextDocument) async throws -> PublishOutcome {
        guard let remote = try await fetch(local._id) else { return .failed }
        if !Self.supersedes(local, remote) { return .alreadyCurrent }

        var replacement = local
        replacement._rev = remote._rev
        let status = try await put(replacement)
        return (200...299).contains(status) ? .published : .failed
    }

    private func fetch(_ documentID: String) async throws -> PageTextDocument? {
        let response = try await transport.send(
            HTTPRequest(method: "GET", path: "/\(database)/\(documentID)"))
        switch response.status {
        case 200...299:
            return try JSONDecoder().decode(PageTextDocument.self, from: response.body)
        case 404:
            return nil
        default:
            throw WebDAVError.unexpectedStatus(response.status, path: documentID)
        }
    }

    private func put(_ document: PageTextDocument) async throws -> Int {
        // JSONEncoder omits nil optionals, which matters more than it looks: a `"_rev": null` in
        // the body is a revision *claim* to CouchDB, and it answers 409 to every create.
        let data = try encoder.encode(document)
        let response = try await transport.send(
            HTTPRequest(
                method: "PUT",
                path: "/\(database)/\(document._id)",
                headers: ["Content-Type": "application/json"],
                body: data))
        return response.status
    }

    /// Whether [local] should replace [remote].
    ///
    /// Text describing newer ink always wins, whichever engine produced it and whenever it ran.
    /// Only when both describe the same ink does it come down to which recognition is newer — and
    /// identical text is not republished at all, since a write that changes nothing would still
    /// wake every reader of the change feed.
    static func supersedes(_ local: PageTextDocument, _ remote: PageTextDocument) -> Bool {
        let localInk = PageTextClock.millis(local.recognizedClock) ?? Int64.min
        let remoteInk = PageTextClock.millis(remote.recognizedClock) ?? Int64.min
        if localInk != remoteInk { return localInk > remoteInk }

        let unchanged = local.text == remote.text
            && local.engine == remote.engine
            && local.language == remote.language
        if unchanged { return false }

        let localRun = PageTextClock.millis(local.updatedAt) ?? Int64.min
        let remoteRun = PageTextClock.millis(remote.updatedAt) ?? Int64.min
        return localRun > remoteRun
    }
}
