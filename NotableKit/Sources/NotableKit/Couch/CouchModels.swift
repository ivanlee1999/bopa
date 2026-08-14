import Foundation

/// CouchDB document bodies. See `docs/couch-sync-protocol.md` — this file and notable's
/// `CouchModels.kt` must stay field-for-field identical.
///
/// Decoding is lenient (missing collections default to empty) because a document written by
/// an older build, or by the other app before it learned a field, must still merge rather
/// than fail. Encoding writes every field explicitly, including nulls, matching the WebDAV
/// DTOs' convention in `WireModels.swift`.

// MARK: - Identifiers

public enum CouchDocID {
    public static func folder(_ id: String) -> String { "folder:\(id)" }
    public static func notebook(_ id: String) -> String { "notebook:\(id)" }
    public static func page(_ id: String) -> String { "page:\(id)" }
    public static func asset(_ sha256Hex: String) -> String { "asset:\(sha256Hex)" }

    /// Splits `"page:abc"` into `("page", "abc")`. Nil when the id carries no known prefix.
    public static func split(_ documentID: String) -> (type: String, id: String)? {
        guard let colon = documentID.firstIndex(of: ":") else { return nil }
        return (String(documentID[documentID.startIndex..<colon]),
                String(documentID[documentID.index(after: colon)...]))
    }
}

public enum CouchDocType {
    public static let folder = "folder"
    public static let notebook = "notebook"
    public static let page = "page"
    public static let asset = "asset"
    /// Protocol bookkeeping, never a library item (§1.1). Reserved as a *prefix* so a client that
    /// meets a `sync-meta:` id it does not know still recognises it as ours and steps past it,
    /// rather than filing it as a document from a future schema.
    public static let syncMeta = "sync-meta"
}

/// Documents the protocol reserves for itself. None of them carry user content, so none of them are
/// enumerated, merged, conflict-copied, or shown.
public enum CouchMetaDocID {
    /// §1.2 — which database this is, and whether this client may sync it.
    public static let database = "sync-meta:database"

    /// Whether an id belongs to the reserved namespace.
    public static func isReserved(_ documentID: String) -> Bool {
        documentID.hasPrefix("\(CouchDocType.syncMeta):")
    }
}

/// §1.2. The identity of the database itself, so a device can tell "the library I have been syncing"
/// from "a new database that happens to have the same name at the same address".
public struct CouchDatabaseMetadata: Codable, Equatable, Sendable {
    public var type: String
    public var protocolVersion: Int
    /// The lowest protocol version allowed to sync this database. A client below it must refuse
    /// rather than guess at documents written by a newer one.
    public var minimumClientProtocol: Int
    /// Minted with the database. Its only job is to be different when the database is not the same.
    public var generation: String
    /// Set while a rebuild is in progress; no client may pull or push ordinary documents.
    public var locked: Bool
    public var lockReason: String?
    public var updatedAt: String

    public init(
        type: String = CouchDatabaseMetadata.documentType,
        protocolVersion: Int = couchProtocolVersion,
        minimumClientProtocol: Int = couchProtocolVersion,
        generation: String,
        locked: Bool = false,
        lockReason: String? = nil,
        updatedAt: String
    ) {
        self.type = type
        self.protocolVersion = protocolVersion
        self.minimumClientProtocol = minimumClientProtocol
        self.generation = generation
        self.locked = locked
        self.lockReason = lockReason
        self.updatedAt = updatedAt
    }

    public static let documentType = "sync-database-metadata"
}

/// The protocol version this build speaks (§1.2). Distinct from `couchSchemaVersion`, which
/// describes one document's shape: this describes the conversation.
public let couchProtocolVersion = 1

/// The schema version this build writes and can merge. A document carrying a higher value is
/// handled by the conflict-copy path (protocol §6.5) rather than merged on guesswork.
public let couchSchemaVersion = 1

// MARK: - Shared records

/// A removed stroke/image/page. Deletions are permanent facts, so merging keeps the
/// *earliest* `deletedAt` — see `CouchMerge.unionTombstones`.
public struct CouchTombstone: Codable, Equatable, Sendable {
    public var id: String
    public var deletedAt: String

    public init(id: String, deletedAt: String) {
        self.id = id
        self.deletedAt = deletedAt
    }
}

/// One ink stroke. Geometry fields carry the same semantics as the WebDAV `StrokeDTO`:
/// `color` is a signed Android ARGB int, `pointsData` is base64 of the SB binary encoding.
public struct CouchStroke: Codable, Equatable, Sendable {
    enum CodingKeys: String, CodingKey {
        case id, createdAt, updatedAt, deviceId, pen, color, size, maxPressure
        case top, bottom, left, right, pointsData
    }

    public var id: String
    public var createdAt: String
    public var updatedAt: String
    /// Which device drew it. Informational plus a tiebreak when the same id somehow differs.
    public var deviceId: String
    public var pen: String
    public var color: Int32
    public var size: Float
    public var maxPressure: Int
    public var top: Float
    public var bottom: Float
    public var left: Float
    public var right: Float
    public var pointsData: String

    public init(
        id: String, createdAt: String, updatedAt: String, deviceId: String,
        pen: String, color: Int32, size: Float, maxPressure: Int = 1,
        top: Float, bottom: Float, left: Float, right: Float, pointsData: String
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deviceId = deviceId
        self.pen = pen
        self.color = color
        self.size = size
        self.maxPressure = maxPressure
        self.top = top
        self.bottom = bottom
        self.left = left
        self.right = right
        self.pointsData = pointsData
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        createdAt = try c.decode(String.self, forKey: .createdAt)
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt) ?? createdAt
        deviceId = try c.decodeIfPresent(String.self, forKey: .deviceId) ?? ""
        pen = try c.decodeIfPresent(String.self, forKey: .pen) ?? NotablePen.ballpen.rawValue
        color = try c.decodeIfPresent(Int32.self, forKey: .color) ?? -16_777_216
        size = try c.decodeIfPresent(Float.self, forKey: .size) ?? 3
        maxPressure = try c.decodeIfPresent(Int.self, forKey: .maxPressure) ?? 1
        top = try c.decodeIfPresent(Float.self, forKey: .top) ?? 0
        bottom = try c.decodeIfPresent(Float.self, forKey: .bottom) ?? 0
        left = try c.decodeIfPresent(Float.self, forKey: .left) ?? 0
        right = try c.decodeIfPresent(Float.self, forKey: .right) ?? 0
        pointsData = try c.decodeIfPresent(String.self, forKey: .pointsData) ?? ""
    }

    /// Decoded points, with legacy raw pressure normalized to [0,1] — same rule as `StrokeDTO`.
    public func decodedPoints() throws -> [NotableStrokePoint] {
        guard let data = Data(base64Encoded: pointsData) else {
            throw SBCodecError.truncated("pointsData is not valid base64")
        }
        var points = try SBStrokeCodec.decode(data)
        if maxPressure != 1, maxPressure > 0 {
            let max = Float(maxPressure)
            for i in points.indices where points[i].pressure != nil {
                points[i].pressure = min(Swift.max(points[i].pressure! / max, 0), 1)
            }
        }
        return points
    }
}

/// A placed image. `assetId` is the `asset:<sha256>` document holding the bytes.
public struct CouchImage: Codable, Equatable, Sendable {
    enum CodingKeys: String, CodingKey {
        case id, assetId, x, y, width, height, createdAt, updatedAt
    }

    public var id: String
    public var assetId: String?
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int
    public var createdAt: String
    public var updatedAt: String

    public init(
        id: String, assetId: String?, x: Int, y: Int, width: Int, height: Int,
        createdAt: String, updatedAt: String
    ) {
        self.id = id
        self.assetId = assetId
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        assetId = try c.decodeIfPresent(String.self, forKey: .assetId)
        x = try c.decodeIfPresent(Int.self, forKey: .x) ?? 0
        y = try c.decodeIfPresent(Int.self, forKey: .y) ?? 0
        width = try c.decodeIfPresent(Int.self, forKey: .width) ?? 0
        height = try c.decodeIfPresent(Int.self, forKey: .height) ?? 0
        createdAt = try c.decode(String.self, forKey: .createdAt)
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt) ?? createdAt
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(assetId, forKey: .assetId)
        try c.encode(x, forKey: .x)
        try c.encode(y, forKey: .y)
        try c.encode(width, forKey: .width)
        try c.encode(height, forKey: .height)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
    }
}

// MARK: - Documents

public struct CouchPage: Codable, Equatable, Sendable {
    enum CodingKeys: String, CodingKey {
        case type, schema, notebookId, title, background, backgroundType
        case pageWidth, pageHeight
        case strokes, deletedStrokes, images, deletedImages
        case createdAt, updatedAt, updatedBy
    }

    public var type: String
    public var schema: Int
    public var notebookId: String?
    /// The page's name, or nil for a page nobody has named.
    ///
    /// bopa has no UI for setting this — the BOOX does. It is carried anyway, because dropping a
    /// field this side does not understand would erase the peer's work on the next merge; the same
    /// reason `CouchMapping.strokeDTO` preserves an unrecognized pen name.
    public var title: String?
    public var background: String
    public var backgroundType: String
    /// The sheet this page's coordinates are laid out on, in page units; nil for a page written
    /// before page sizes existed. Mirrors `PageFile.pageWidth`/`pageHeight` — see there.
    public var pageWidth: Int?
    public var pageHeight: Int?
    public var strokes: [CouchStroke]
    public var deletedStrokes: [CouchTombstone]
    public var images: [CouchImage]
    public var deletedImages: [CouchTombstone]
    public var createdAt: String
    public var updatedAt: String
    public var updatedBy: String

    public init(
        type: String = CouchDocType.page, schema: Int = couchSchemaVersion,
        notebookId: String?, title: String? = nil,
        background: String = "blank", backgroundType: String = "native",
        pageWidth: Int? = nil, pageHeight: Int? = nil,
        strokes: [CouchStroke] = [], deletedStrokes: [CouchTombstone] = [],
        images: [CouchImage] = [], deletedImages: [CouchTombstone] = [],
        createdAt: String, updatedAt: String, updatedBy: String
    ) {
        self.type = type
        self.schema = schema
        self.notebookId = notebookId
        self.title = title
        self.background = background
        self.backgroundType = backgroundType
        self.pageWidth = pageWidth
        self.pageHeight = pageHeight
        self.strokes = strokes
        self.deletedStrokes = deletedStrokes
        self.images = images
        self.deletedImages = deletedImages
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.updatedBy = updatedBy
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? CouchDocType.page
        schema = try c.decodeIfPresent(Int.self, forKey: .schema) ?? couchSchemaVersion
        notebookId = try c.decodeIfPresent(String.self, forKey: .notebookId)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        background = try c.decodeIfPresent(String.self, forKey: .background) ?? "blank"
        backgroundType = try c.decodeIfPresent(String.self, forKey: .backgroundType) ?? "native"
        // Non-positive is treated as no declaration, matching `PageFile`.
        pageWidth = try c.decodeIfPresent(Int.self, forKey: .pageWidth).flatMap { $0 > 0 ? $0 : nil }
        pageHeight = try c.decodeIfPresent(Int.self, forKey: .pageHeight)
            .flatMap { $0 > 0 ? $0 : nil }
        strokes = try c.decodeIfPresent([CouchStroke].self, forKey: .strokes) ?? []
        deletedStrokes = try c.decodeIfPresent([CouchTombstone].self, forKey: .deletedStrokes) ?? []
        images = try c.decodeIfPresent([CouchImage].self, forKey: .images) ?? []
        deletedImages = try c.decodeIfPresent([CouchTombstone].self, forKey: .deletedImages) ?? []
        createdAt = try c.decode(String.self, forKey: .createdAt)
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt) ?? createdAt
        updatedBy = try c.decodeIfPresent(String.self, forKey: .updatedBy) ?? ""
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encode(schema, forKey: .schema)
        try c.encode(notebookId, forKey: .notebookId)
        try c.encode(title, forKey: .title)
        try c.encode(background, forKey: .background)
        try c.encode(backgroundType, forKey: .backgroundType)
        try c.encode(pageWidth, forKey: .pageWidth)
        try c.encode(pageHeight, forKey: .pageHeight)
        try c.encode(strokes, forKey: .strokes)
        try c.encode(deletedStrokes, forKey: .deletedStrokes)
        try c.encode(images, forKey: .images)
        try c.encode(deletedImages, forKey: .deletedImages)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(updatedBy, forKey: .updatedBy)
    }
}

/// A page the reader starred, or the record of it being un-starred — protocol §3.2.1.
///
/// Deliberately *not* a list of ids plus a `CouchTombstone` list, which is how every other removal
/// in this protocol is expressed. That pattern makes removal permanent, and it is sound everywhere
/// it is used because the thing removed never comes back under the same id: a redrawn stroke is a
/// new stroke with a new id. A bookmark is the exception — the page keeps its id, so starring the
/// same page again is a thing users do routinely, and "remove wins forever" would make the second
/// star impossible to express. Carrying `removed` on the entry instead lets whichever write came
/// last say either thing, which is what last-writer-wins per `pageId` needs.
public struct CouchBookmark: Codable, Equatable, Sendable {
    enum CodingKeys: String, CodingKey {
        case pageId, updatedAt, removed
    }

    public var pageId: String
    public var updatedAt: String
    /// True for a page that was bookmarked and then un-bookmarked. Kept rather than dropped so the
    /// un-starring propagates to a peer that still holds the star.
    public var removed: Bool

    public init(pageId: String, updatedAt: String, removed: Bool = false) {
        self.pageId = pageId
        self.updatedAt = updatedAt
        self.removed = removed
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pageId = try c.decode(String.self, forKey: .pageId)
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt) ?? ""
        removed = try c.decodeIfPresent(Bool.self, forKey: .removed) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(pageId, forKey: .pageId)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(removed, forKey: .removed)
    }
}

/// One line of a notebook's outline — its table of contents, protocol §3.2.2.
///
/// An entry points at a *page*, not at a position on one. Both apps this protocol has to satisfy
/// anchor the same way (Goodnotes' outline and the BOOX reader's TOC), and a page anchor is the
/// only one that survives the page being written on: ink has no headings to re-find, so an offset
/// anchor would drift the moment the page was edited on the other device.
public struct CouchOutlineEntry: Codable, Equatable, Sendable {
    enum CodingKeys: String, CodingKey {
        case id, pageId, title, depth, updatedAt, removed
    }

    /// The entry's own id, not the page's. A page is allowed to appear in the outline more than
    /// once — both reference apps allow it, and it is how a page that opens one section and closes
    /// another gets to say so — which rules out keying entries by page.
    public var id: String
    public var pageId: String
    public var title: String
    /// 0, 1 or 2: heading, subheading, sub-subheading. Three levels is what both reference apps
    /// settled on. Clamped rather than rejected on decode, so a document from a build that one day
    /// allows four levels degrades to a flatter outline instead of failing to merge.
    public var depth: Int
    public var updatedAt: String
    /// True for a deleted entry, kept for the same reason as `CouchBookmark.removed`.
    public var removed: Bool

    /// The deepest `depth` this build understands.
    public static let maxDepth = 2

    public init(
        id: String, pageId: String, title: String, depth: Int = 0,
        updatedAt: String, removed: Bool = false
    ) {
        self.id = id
        self.pageId = pageId
        self.title = title
        self.depth = Swift.min(Swift.max(depth, 0), CouchOutlineEntry.maxDepth)
        self.updatedAt = updatedAt
        self.removed = removed
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        pageId = try c.decodeIfPresent(String.self, forKey: .pageId) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        let rawDepth = try c.decodeIfPresent(Int.self, forKey: .depth) ?? 0
        depth = Swift.min(Swift.max(rawDepth, 0), CouchOutlineEntry.maxDepth)
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt) ?? ""
        removed = try c.decodeIfPresent(Bool.self, forKey: .removed) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(pageId, forKey: .pageId)
        try c.encode(title, forKey: .title)
        try c.encode(depth, forKey: .depth)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(removed, forKey: .removed)
    }
}

public struct CouchNotebook: Codable, Equatable, Sendable {
    enum CodingKeys: String, CodingKey {
        case type, schema, title, pageIds, deletedPageIds, parentFolderId
        case bookmarks, outline
        case defaultBackground, defaultBackgroundType
        case defaultPageWidth, defaultPageHeight
        case deletedAt
        case createdAt, updatedAt, updatedBy
    }

    public var type: String
    public var schema: Int
    public var title: String
    public var pageIds: [String]
    public var deletedPageIds: [CouchTombstone]
    public var parentFolderId: String?
    /// Starred pages, including the un-starred ones — see `CouchBookmark`. Sorted by `pageId` in a
    /// merged document so the encoded body is byte-stable across devices.
    public var bookmarks: [CouchBookmark]
    /// The notebook's table of contents, in reading order. Order is carried by the array itself,
    /// the way `pageIds` carries page order, and merged the same way.
    public var outline: [CouchOutlineEntry]
    public var defaultBackground: String
    public var defaultBackgroundType: String
    /// Sheet size for new pages here, in page units; nil for a notebook created before page
    /// sizes existed. Mirrors `NotebookManifest.defaultPageWidth`/`defaultPageHeight`.
    public var defaultPageWidth: Int?
    public var defaultPageHeight: Int?
    /// In the Trash since — protocol §3.2. Nil is a notebook in the library.
    ///
    /// The Trash is a *state of the notebook*, not a fact about one device: it is staged deletion,
    /// so it hides the notebook everywhere and can be undone from anywhere. Only emptying the Trash
    /// deletes for good, and that is a `_deleted` tombstone (§6.4), not this.
    public var deletedAt: String?
    public var createdAt: String
    public var updatedAt: String
    public var updatedBy: String

    public init(
        type: String = CouchDocType.notebook, schema: Int = couchSchemaVersion,
        title: String, pageIds: [String] = [], deletedPageIds: [CouchTombstone] = [],
        parentFolderId: String? = nil,
        bookmarks: [CouchBookmark] = [], outline: [CouchOutlineEntry] = [],
        defaultBackground: String = "blank", defaultBackgroundType: String = "native",
        defaultPageWidth: Int? = nil, defaultPageHeight: Int? = nil,
        deletedAt: String? = nil,
        createdAt: String, updatedAt: String, updatedBy: String
    ) {
        self.type = type
        self.schema = schema
        self.title = title
        self.pageIds = pageIds
        self.deletedPageIds = deletedPageIds
        self.parentFolderId = parentFolderId
        self.bookmarks = bookmarks
        self.outline = outline
        self.defaultBackground = defaultBackground
        self.defaultBackgroundType = defaultBackgroundType
        self.defaultPageWidth = defaultPageWidth
        self.defaultPageHeight = defaultPageHeight
        self.deletedAt = deletedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.updatedBy = updatedBy
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? CouchDocType.notebook
        schema = try c.decodeIfPresent(Int.self, forKey: .schema) ?? couchSchemaVersion
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        pageIds = try c.decodeIfPresent([String].self, forKey: .pageIds) ?? []
        deletedPageIds = try c.decodeIfPresent([CouchTombstone].self, forKey: .deletedPageIds) ?? []
        parentFolderId = try c.decodeIfPresent(String.self, forKey: .parentFolderId)
        bookmarks = try c.decodeIfPresent([CouchBookmark].self, forKey: .bookmarks) ?? []
        outline = try c.decodeIfPresent([CouchOutlineEntry].self, forKey: .outline) ?? []
        defaultBackground = try c.decodeIfPresent(String.self, forKey: .defaultBackground) ?? "blank"
        defaultBackgroundType =
            try c.decodeIfPresent(String.self, forKey: .defaultBackgroundType) ?? "native"
        defaultPageWidth = try c.decodeIfPresent(Int.self, forKey: .defaultPageWidth)
            .flatMap { $0 > 0 ? $0 : nil }
        defaultPageHeight = try c.decodeIfPresent(Int.self, forKey: .defaultPageHeight)
            .flatMap { $0 > 0 ? $0 : nil }
        // Empty reads as absent: a peer that writes "" means "not in the Trash", and letting the
        // empty string through would make `deletedAt != nil` — trashed with no date — everywhere.
        deletedAt = try c.decodeIfPresent(String.self, forKey: .deletedAt)
            .flatMap { $0.isEmpty ? nil : $0 }
        createdAt = try c.decode(String.self, forKey: .createdAt)
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt) ?? createdAt
        updatedBy = try c.decodeIfPresent(String.self, forKey: .updatedBy) ?? ""
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encode(schema, forKey: .schema)
        try c.encode(title, forKey: .title)
        try c.encode(pageIds, forKey: .pageIds)
        try c.encode(deletedPageIds, forKey: .deletedPageIds)
        try c.encode(parentFolderId, forKey: .parentFolderId)
        try c.encode(bookmarks, forKey: .bookmarks)
        try c.encode(outline, forKey: .outline)
        try c.encode(defaultBackground, forKey: .defaultBackground)
        try c.encode(defaultBackgroundType, forKey: .defaultBackgroundType)
        try c.encode(defaultPageWidth, forKey: .defaultPageWidth)
        try c.encode(defaultPageHeight, forKey: .defaultPageHeight)
        try c.encode(deletedAt, forKey: .deletedAt)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(updatedBy, forKey: .updatedBy)
    }
}

public struct CouchFolder: Codable, Equatable, Sendable {
    enum CodingKeys: String, CodingKey {
        case type, schema, title, parentFolderId, deletedAt, createdAt, updatedAt, updatedBy
    }

    public var type: String
    public var schema: Int
    public var title: String
    public var parentFolderId: String?
    /// In the Trash since; see `CouchNotebook.deletedAt`. A trashed folder hides its whole subtree
    /// without touching it, so only this document carries the state.
    public var deletedAt: String?
    public var createdAt: String
    public var updatedAt: String
    public var updatedBy: String

    public init(
        type: String = CouchDocType.folder, schema: Int = couchSchemaVersion,
        title: String, parentFolderId: String? = nil, deletedAt: String? = nil,
        createdAt: String, updatedAt: String, updatedBy: String
    ) {
        self.type = type
        self.schema = schema
        self.title = title
        self.parentFolderId = parentFolderId
        self.deletedAt = deletedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.updatedBy = updatedBy
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? CouchDocType.folder
        schema = try c.decodeIfPresent(Int.self, forKey: .schema) ?? couchSchemaVersion
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        parentFolderId = try c.decodeIfPresent(String.self, forKey: .parentFolderId)
        deletedAt = try c.decodeIfPresent(String.self, forKey: .deletedAt)
            .flatMap { $0.isEmpty ? nil : $0 }
        createdAt = try c.decode(String.self, forKey: .createdAt)
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt) ?? createdAt
        updatedBy = try c.decodeIfPresent(String.self, forKey: .updatedBy) ?? ""
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encode(schema, forKey: .schema)
        try c.encode(title, forKey: .title)
        try c.encode(parentFolderId, forKey: .parentFolderId)
        try c.encode(deletedAt, forKey: .deletedAt)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(updatedBy, forKey: .updatedBy)
    }
}
