import Foundation

/// DTOs matching Notable's WebDAV sync JSON (`NotebookSerializer.kt`, `FolderSerializer.kt`).
///
/// Encoding note: Notable parses with kotlinx.serialization, which requires nullable fields
/// without defaults to be PRESENT (as explicit `null`). Swift's synthesized Codable omits nil
/// optionals, so every DTO with optionals implements `encode(to:)` manually and writes
/// explicit nulls. Decoding stays lenient (`decodeIfPresent`).
///
/// Timestamps are kept as ISO-8601 UTC strings (`java.time.Instant` style) to round-trip
/// byte-faithfully; use `NotableDate` to convert.

public struct NotebookManifest: Codable, Equatable, Sendable {
    enum CodingKeys: String, CodingKey {
        case version, notebookId, title, pageIds, openPageId, parentFolderId
        case defaultBackground, defaultBackgroundType, linkedExternalUri
        case createdAt, updatedAt, serverTimestamp, deletedPageIds, updatedBy
    }

    public var version: Int
    public var notebookId: String
    public var title: String
    public var pageIds: [String]
    public var openPageId: String?
    public var parentFolderId: String?
    public var defaultBackground: String
    public var defaultBackgroundType: String
    public var linkedExternalUri: String?
    public var createdAt: String
    public var updatedAt: String
    public var serverTimestamp: String
    /// Pages removed here, so a peer that still lists them does not re-add them on merge.
    public var deletedPageIds: [CouchTombstone]
    /// Which device last wrote this notebook. Breaks scalar ties in the merge.
    public var updatedBy: String

    public init(
        version: Int = 1,
        notebookId: String,
        title: String,
        pageIds: [String],
        openPageId: String? = nil,
        parentFolderId: String? = nil,
        defaultBackground: String = "blank",
        defaultBackgroundType: String = "native",
        linkedExternalUri: String? = nil,
        createdAt: String,
        updatedAt: String,
        serverTimestamp: String,
        deletedPageIds: [CouchTombstone] = [],
        updatedBy: String = ""
    ) {
        self.deletedPageIds = deletedPageIds
        self.updatedBy = updatedBy
        self.version = version
        self.notebookId = notebookId
        self.title = title
        self.pageIds = pageIds
        self.openPageId = openPageId
        self.parentFolderId = parentFolderId
        self.defaultBackground = defaultBackground
        self.defaultBackgroundType = defaultBackgroundType
        self.linkedExternalUri = linkedExternalUri
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.serverTimestamp = serverTimestamp
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        notebookId = try c.decode(String.self, forKey: .notebookId)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        pageIds = try c.decodeIfPresent([String].self, forKey: .pageIds) ?? []
        openPageId = try c.decodeIfPresent(String.self, forKey: .openPageId)
        parentFolderId = try c.decodeIfPresent(String.self, forKey: .parentFolderId)
        defaultBackground = try c.decodeIfPresent(String.self, forKey: .defaultBackground) ?? "blank"
        defaultBackgroundType =
            try c.decodeIfPresent(String.self, forKey: .defaultBackgroundType) ?? "native"
        linkedExternalUri = try c.decodeIfPresent(String.self, forKey: .linkedExternalUri)
        createdAt = try c.decode(String.self, forKey: .createdAt)
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt) ?? createdAt
        serverTimestamp = try c.decodeIfPresent(String.self, forKey: .serverTimestamp) ?? updatedAt
        deletedPageIds = try c.decodeIfPresent([CouchTombstone].self, forKey: .deletedPageIds) ?? []
        updatedBy = try c.decodeIfPresent(String.self, forKey: .updatedBy) ?? ""
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(notebookId, forKey: .notebookId)
        try c.encode(title, forKey: .title)
        try c.encode(pageIds, forKey: .pageIds)
        try c.encode(openPageId, forKey: .openPageId)
        try c.encode(parentFolderId, forKey: .parentFolderId)
        try c.encode(defaultBackground, forKey: .defaultBackground)
        try c.encode(defaultBackgroundType, forKey: .defaultBackgroundType)
        try c.encode(linkedExternalUri, forKey: .linkedExternalUri)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(serverTimestamp, forKey: .serverTimestamp)
        try c.encode(deletedPageIds, forKey: .deletedPageIds)
        try c.encode(updatedBy, forKey: .updatedBy)
    }
}

public struct PageFile: Codable, Equatable, Sendable {
    enum CodingKeys: String, CodingKey {
        case version, id, notebookId, background, backgroundType, parentFolderId, scroll
        case createdAt, updatedAt, strokes, images, deletedStrokes, updatedBy
    }

    public var version: Int
    public var id: String
    public var notebookId: String?
    public var background: String
    public var backgroundType: String
    public var parentFolderId: String?
    public var scroll: Int
    public var createdAt: String
    public var updatedAt: String
    public var strokes: [StrokeDTO]
    public var images: [ImageDTO]
    /// Strokes erased here, kept so a peer that still holds them does not bring them back on the
    /// next merge (`docs/couch-sync-protocol.md` §6.6). Absent from files written before CouchDB
    /// sync and ignored by WebDAV readers, which parse with unknown keys allowed.
    public var deletedStrokes: [CouchTombstone]
    /// Which device last wrote this page. Breaks scalar ties in the merge.
    public var updatedBy: String

    public init(
        version: Int = 1,
        id: String,
        notebookId: String?,
        background: String = "blank",
        backgroundType: String = "native",
        parentFolderId: String? = nil,
        scroll: Int = 0,
        createdAt: String,
        updatedAt: String,
        strokes: [StrokeDTO] = [],
        images: [ImageDTO] = [],
        deletedStrokes: [CouchTombstone] = [],
        updatedBy: String = ""
    ) {
        self.version = version
        self.id = id
        self.notebookId = notebookId
        self.background = background
        self.backgroundType = backgroundType
        self.parentFolderId = parentFolderId
        self.scroll = scroll
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.strokes = strokes
        self.images = images
        self.deletedStrokes = deletedStrokes
        self.updatedBy = updatedBy
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        id = try c.decode(String.self, forKey: .id)
        notebookId = try c.decodeIfPresent(String.self, forKey: .notebookId)
        background = try c.decodeIfPresent(String.self, forKey: .background) ?? "blank"
        backgroundType = try c.decodeIfPresent(String.self, forKey: .backgroundType) ?? "native"
        parentFolderId = try c.decodeIfPresent(String.self, forKey: .parentFolderId)
        scroll = try c.decodeIfPresent(Int.self, forKey: .scroll) ?? 0
        createdAt = try c.decode(String.self, forKey: .createdAt)
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt) ?? createdAt
        strokes = try c.decodeIfPresent([StrokeDTO].self, forKey: .strokes) ?? []
        images = try c.decodeIfPresent([ImageDTO].self, forKey: .images) ?? []
        deletedStrokes = try c.decodeIfPresent([CouchTombstone].self, forKey: .deletedStrokes) ?? []
        updatedBy = try c.decodeIfPresent(String.self, forKey: .updatedBy) ?? ""
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(id, forKey: .id)
        try c.encode(notebookId, forKey: .notebookId)
        try c.encode(background, forKey: .background)
        try c.encode(backgroundType, forKey: .backgroundType)
        try c.encode(parentFolderId, forKey: .parentFolderId)
        try c.encode(scroll, forKey: .scroll)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(strokes, forKey: .strokes)
        try c.encode(images, forKey: .images)
        try c.encode(deletedStrokes, forKey: .deletedStrokes)
        try c.encode(updatedBy, forKey: .updatedBy)
    }
}

public struct StrokeDTO: Codable, Equatable, Sendable {
    public var id: String
    public var size: Float
    /// Pen enum name; parse with `NotablePen.from(_:)`, write only known raw values.
    public var pen: String
    /// Android ARGB packed into a SIGNED 32-bit int (e.g. 0xFF000000 black = -16777216).
    public var color: Int32
    /// 1 = pressures normalized to [0,1]; legacy rows carry the raw digitizer max.
    public var maxPressure: Int
    public var top: Float
    public var bottom: Float
    public var left: Float
    public var right: Float
    /// Base64 of the SB binary (`SBStrokeCodec`).
    public var pointsData: String
    public var createdAt: String
    public var updatedAt: String

    public init(
        id: String,
        size: Float,
        pen: NotablePen,
        color: Int32,
        maxPressure: Int = 1,
        top: Float,
        bottom: Float,
        left: Float,
        right: Float,
        pointsData: String,
        createdAt: String,
        updatedAt: String
    ) {
        self.id = id
        self.size = size
        self.pen = pen.rawValue
        self.color = color
        self.maxPressure = maxPressure
        self.top = top
        self.bottom = bottom
        self.left = left
        self.right = right
        self.pointsData = pointsData
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Decoded points, with legacy raw pressure normalized to [0,1]
    /// (mirrors `Stroke.withNormalizedPressure`).
    public func decodedPoints() throws -> [NotableStrokePoint] {
        guard let data = Data(base64Encoded: pointsData) else {
            throw SBCodecError.truncated("pointsData is not valid base64")
        }
        var points = try SBStrokeCodec.decode(data)
        if maxPressure != 1, maxPressure > 0 {
            let max = Float(maxPressure)
            for i in points.indices {
                if let p = points[i].pressure {
                    points[i].pressure = min(Swift.max(p / max, 0), 1)
                }
            }
        }
        return points
    }
}

public struct ImageDTO: Codable, Equatable, Sendable {
    public var id: String
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int
    /// Relative path under the notebook directory, e.g. "images/abc.jpg".
    public var uri: String?
    public var createdAt: String
    public var updatedAt: String

    public init(
        id: String, x: Int, y: Int, width: Int, height: Int,
        uri: String?, createdAt: String, updatedAt: String
    ) {
        self.id = id
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.uri = uri
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(x, forKey: .x)
        try c.encode(y, forKey: .y)
        try c.encode(width, forKey: .width)
        try c.encode(height, forKey: .height)
        try c.encode(uri, forKey: .uri)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
    }
}

public struct FoldersFile: Codable, Equatable, Sendable {
    public var version: Int
    public var folders: [FolderDTO]
    public var serverTimestamp: String

    public init(version: Int = 1, folders: [FolderDTO], serverTimestamp: String) {
        self.version = version
        self.folders = folders
        self.serverTimestamp = serverTimestamp
    }
}

public struct FolderDTO: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    /// Has a default upstream, so may be omitted — but we still write it explicitly.
    public var parentFolderId: String?
    public var createdAt: String
    public var updatedAt: String

    public init(id: String, title: String, parentFolderId: String? = nil, createdAt: String, updatedAt: String) {
        self.id = id
        self.title = title
        self.parentFolderId = parentFolderId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(parentFolderId, forKey: .parentFolderId)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
    }
}

// MARK: - Dates

/// ISO-8601 UTC timestamps in `java.time.Instant.toString()` style: fractional seconds are
/// printed only when non-zero, and both variants must parse.
public enum NotableDate {
    private static func formatter(fractional: Bool) -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = fractional
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        return f
    }

    public static func parse(_ string: String) -> Date? {
        formatter(fractional: true).date(from: string)
            ?? formatter(fractional: false).date(from: string)
    }

    public static func format(_ date: Date) -> String {
        // `java.time.Instant.toString()` prints fractional seconds only when they are
        // non-zero; match that so timestamps we write are shaped like Notable's own.
        let millis = Int64((date.timeIntervalSince1970 * 1000).rounded())
        return formatter(fractional: millis % 1000 != 0).string(from: date)
    }
}

// MARK: - Server paths

/// Mirrors `SyncPaths.kt`. All paths are relative to the WebDAV base URL — which must therefore
/// name the *parent* of the shared tree, not the tree itself. Both clients append `notable/`
/// themselves; a base that already ends in it syncs to `<base>/notable/notable`.
public enum NotableSyncPaths {
    /// The one folder both clients share, as a bare segment. Callers resolving a user-chosen
    /// folder against the rule above need the name without the leading slash.
    public static let rootName = "notable"
    public static let root = "/notable"
    public static let notebooksDir = "/notable/notebooks"
    public static let tombstonesDir = "/notable/deletions"
    public static let foldersFile = "/notable/folders.json"

    public static func notebookDir(_ notebookId: String) -> String {
        "\(notebooksDir)/\(notebookId)"
    }
    public static func manifestFile(_ notebookId: String) -> String {
        "\(notebookDir(notebookId))/manifest.json"
    }
    public static func pagesDir(_ notebookId: String) -> String {
        "\(notebookDir(notebookId))/pages"
    }
    public static func pageFile(_ notebookId: String, _ pageId: String) -> String {
        "\(pagesDir(notebookId))/\(pageId).json"
    }
    public static func imagesDir(_ notebookId: String) -> String {
        "\(notebookDir(notebookId))/images"
    }
    public static func imageFile(_ notebookId: String, _ imageName: String) -> String {
        "\(imagesDir(notebookId))/\(imageName)"
    }
    public static func backgroundsDir(_ notebookId: String) -> String {
        "\(notebookDir(notebookId))/backgrounds"
    }
    public static func backgroundFile(_ notebookId: String, _ bgName: String) -> String {
        "\(backgroundsDir(notebookId))/\(bgName)"
    }
    public static func tombstone(_ notebookId: String) -> String {
        "\(tombstonesDir)/\(notebookId)"
    }
}
