import Foundation

/// Existing notes_text projection. These fields never become part of the canonical page.
public struct ScribePageText: Codable, Sendable {
    public var pageId: String
    public var notebookId: String?
    public var pageTitle: String?
    public var text: String
    public var format: String?
    public var engine: String?
    public var language: String?
    public var recognizedClock: String?
    public var updatedAt: String?
    public var updatedBy: String?
    public var sourceRev: String?
    public var sourceFingerprint: String?
    public var pipelineVersion: String?

    public init(pageId: String, notebookId: String?, text: String, sourceRev: String? = nil,
                sourceFingerprint: String? = nil, pipelineVersion: String? = nil, format: String? = nil) {
        self.pageId = pageId; self.notebookId = notebookId; self.text = text
        self.sourceRev = sourceRev; self.sourceFingerprint = sourceFingerprint; self.pipelineVersion = pipelineVersion
        self.format = format
    }

    public var hasSourceIdentity: Bool {
        guard let sourceRev, !sourceRev.isEmpty,
              let sourceFingerprint, sourceFingerprint.hasPrefix("sha256:"),
              let pipelineVersion, pipelineVersion.hasPrefix("scribe-v2:") else { return false }
        func hex(_ value: Substring) -> Bool {
            value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }
        return hex(sourceFingerprint.dropFirst(7)) && hex(pipelineVersion.dropFirst(10))
    }
}

/// Device ids are informational and reconstructed on import; every ink field and ordering,
/// deletion marker and declared dimension must still agree. This is not the Go fingerprint.
public struct ScribeInkSnapshot: Codable, Equatable, Sendable {
    public var strokes: [CouchStroke]
    public var deletedStrokes: [CouchTombstone]
    public var width: Int?
    public var height: Int?

    public init(_ page: CouchPage) {
        strokes = page.strokes.map { var stroke = $0; stroke.deviceId = ""; return stroke }
        deletedStrokes = page.deletedStrokes
        width = page.pageWidth; height = page.pageHeight
    }

    public init(_ page: PageFile) {
        strokes = page.strokes.map { CouchMapping.couchStroke(from: $0, deviceID: "") }
        deletedStrokes = page.deletedStrokes
        width = page.pageWidth; height = page.pageHeight
    }
}

public struct VerifiedScribeText: Sendable {
    public var result: ScribePageText
    public var ink: ScribeInkSnapshot
    public init(result: ScribePageText, ink: ScribeInkSnapshot) { self.result = result; self.ink = ink }
}

public enum ScribeTextReader {
    /// GET-only, bounded to the selected preview page. The second page read fences a result
    /// whose canonical source changed while notes_text was being read.
    public static func read(client: CouchDBClient, notebookID: String, pageID: String,
                            localInk: ScribeInkSnapshot, textDatabase: String = "notes_text") async throws -> VerifiedScribeText? {
        let transport = ReadTransport(base: client.transport)
        let pages = CouchDBClient(transport: transport, database: client.database)
        let texts = CouchDBClient(transport: transport, database: textDatabase)
        guard let first = try await pages.get(CouchDocID.page(pageID), as: CouchPage.self), !first.deleted,
              first.body.type == CouchDocType.page, first.body.schema == couchSchemaVersion,
              first.body.notebookId == notebookID, ScribeInkSnapshot(first.body) == localInk,
              let text = try await texts.get("pagetext:\(pageID)", as: ScribePageText.self), !text.deleted,
              text.body.pageId == pageID, text.body.notebookId == notebookID,
              text.body.hasSourceIdentity, text.body.sourceRev == first.rev,
              let last = try await pages.get(CouchDocID.page(pageID), as: CouchPage.self), !last.deleted,
              last.rev == first.rev, last.body.type == CouchDocType.page, last.body.schema == couchSchemaVersion,
              last.body.notebookId == notebookID,
              ScribeInkSnapshot(last.body) == localInk else { return nil }
        try Task.checkCancellation()
        return VerifiedScribeText(result: text.body, ink: localInk)
    }

    private struct ReadTransport: HTTPTransport {
        var base: HTTPTransport
        func send(_ request: HTTPRequest) async throws -> HTTPResponse {
            var request = request; request.timeout = 8
            request.headers["Cache-Control"] = "no-cache, no-store"
            return try await base.send(request)
        }
    }
}
