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
}

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
        case type, schema, notebookId, background, backgroundType
        case strokes, deletedStrokes, images, deletedImages
        case createdAt, updatedAt, updatedBy
    }

    public var type: String
    public var schema: Int
    public var notebookId: String?
    public var background: String
    public var backgroundType: String
    public var strokes: [CouchStroke]
    public var deletedStrokes: [CouchTombstone]
    public var images: [CouchImage]
    public var deletedImages: [CouchTombstone]
    public var createdAt: String
    public var updatedAt: String
    public var updatedBy: String

    public init(
        type: String = CouchDocType.page, schema: Int = couchSchemaVersion,
        notebookId: String?, background: String = "blank", backgroundType: String = "native",
        strokes: [CouchStroke] = [], deletedStrokes: [CouchTombstone] = [],
        images: [CouchImage] = [], deletedImages: [CouchTombstone] = [],
        createdAt: String, updatedAt: String, updatedBy: String
    ) {
        self.type = type
        self.schema = schema
        self.notebookId = notebookId
        self.background = background
        self.backgroundType = backgroundType
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
        background = try c.decodeIfPresent(String.self, forKey: .background) ?? "blank"
        backgroundType = try c.decodeIfPresent(String.self, forKey: .backgroundType) ?? "native"
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
        try c.encode(background, forKey: .background)
        try c.encode(backgroundType, forKey: .backgroundType)
        try c.encode(strokes, forKey: .strokes)
        try c.encode(deletedStrokes, forKey: .deletedStrokes)
        try c.encode(images, forKey: .images)
        try c.encode(deletedImages, forKey: .deletedImages)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(updatedBy, forKey: .updatedBy)
    }
}

public struct CouchNotebook: Codable, Equatable, Sendable {
    enum CodingKeys: String, CodingKey {
        case type, schema, title, pageIds, deletedPageIds, parentFolderId
        case defaultBackground, defaultBackgroundType
        case createdAt, updatedAt, updatedBy
    }

    public var type: String
    public var schema: Int
    public var title: String
    public var pageIds: [String]
    public var deletedPageIds: [CouchTombstone]
    public var parentFolderId: String?
    public var defaultBackground: String
    public var defaultBackgroundType: String
    public var createdAt: String
    public var updatedAt: String
    public var updatedBy: String

    public init(
        type: String = CouchDocType.notebook, schema: Int = couchSchemaVersion,
        title: String, pageIds: [String] = [], deletedPageIds: [CouchTombstone] = [],
        parentFolderId: String? = nil,
        defaultBackground: String = "blank", defaultBackgroundType: String = "native",
        createdAt: String, updatedAt: String, updatedBy: String
    ) {
        self.type = type
        self.schema = schema
        self.title = title
        self.pageIds = pageIds
        self.deletedPageIds = deletedPageIds
        self.parentFolderId = parentFolderId
        self.defaultBackground = defaultBackground
        self.defaultBackgroundType = defaultBackgroundType
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
        defaultBackground = try c.decodeIfPresent(String.self, forKey: .defaultBackground) ?? "blank"
        defaultBackgroundType =
            try c.decodeIfPresent(String.self, forKey: .defaultBackgroundType) ?? "native"
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
        try c.encode(defaultBackground, forKey: .defaultBackground)
        try c.encode(defaultBackgroundType, forKey: .defaultBackgroundType)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(updatedBy, forKey: .updatedBy)
    }
}

public struct CouchFolder: Codable, Equatable, Sendable {
    enum CodingKeys: String, CodingKey {
        case type, schema, title, parentFolderId, createdAt, updatedAt, updatedBy
    }

    public var type: String
    public var schema: Int
    public var title: String
    public var parentFolderId: String?
    public var createdAt: String
    public var updatedAt: String
    public var updatedBy: String

    public init(
        type: String = CouchDocType.folder, schema: Int = couchSchemaVersion,
        title: String, parentFolderId: String? = nil,
        createdAt: String, updatedAt: String, updatedBy: String
    ) {
        self.type = type
        self.schema = schema
        self.title = title
        self.parentFolderId = parentFolderId
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
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(updatedBy, forKey: .updatedBy)
    }
}
