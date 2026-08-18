import CryptoKit
import Foundation

/// The bytes behind an `asset:<sha256>` document — protocol §3.4.
///
/// Content-addressed, and therefore immutable: two devices holding the same image agree on its id
/// without talking to each other, nobody ever has to merge one, and a `409` on upload means
/// "already there" rather than "someone else wrote this".
public struct CouchAsset: Codable, Equatable, Sendable {
    public var type: String
    public var schema: Int
    public var contentType: String
    public var createdAt: String
    public var updatedAt: String
    public var updatedBy: String
    /// The blob itself. Written inline as `_attachments.blob.data`, so the document and its bytes
    /// land in a single `PUT` — a separate attachment write would need the document's revision
    /// first, which turns one immutable upload into a two-request dance that can half-fail.
    public var data: Data

    public init(
        type: String = CouchDocType.asset, schema: Int = couchSchemaVersion,
        contentType: String, createdAt: String, updatedAt: String, updatedBy: String, data: Data
    ) {
        self.type = type
        self.schema = schema
        self.contentType = contentType
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.updatedBy = updatedBy
        self.data = data
    }

    /// A fresh asset for `data`, with its content type sniffed from the bytes.
    public init(data: Data, at timestamp: String, updatedBy: String) {
        self.init(
            contentType: CouchAssetID.contentType(of: data),
            createdAt: timestamp, updatedAt: timestamp, updatedBy: updatedBy, data: data)
    }

    enum CodingKeys: String, CodingKey {
        case type, schema, contentType, createdAt, updatedAt, updatedBy
        case attachments = "_attachments"
    }

    private struct Attachments: Codable {
        var blob: Blob

        struct Blob: Codable {
            enum CodingKeys: String, CodingKey {
                case contentType = "content_type"
                case data, stub
            }

            var contentType: String
            var data: Data?
            /// CouchDB answers a plain read with `{"stub": true}` and no bytes; the blob is only
            /// inlined when the request asked for it.
            var stub: Bool?
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? CouchDocType.asset
        schema = try c.decodeIfPresent(Int.self, forKey: .schema) ?? couchSchemaVersion
        createdAt = try c.decode(String.self, forKey: .createdAt)
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt) ?? createdAt
        updatedBy = try c.decodeIfPresent(String.self, forKey: .updatedBy) ?? ""
        let attachments = try c.decodeIfPresent(Attachments.self, forKey: .attachments)
        // The document's own `contentType` is the field the protocol defines; the attachment's is
        // the one CouchDB serves the bytes with. They are written together and only the first is
        // guaranteed to survive a stub read.
        contentType = try c.decodeIfPresent(String.self, forKey: .contentType)
            ?? attachments?.blob.contentType ?? "application/octet-stream"
        data = attachments?.blob.data ?? Data()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encode(schema, forKey: .schema)
        try c.encode(contentType, forKey: .contentType)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(updatedBy, forKey: .updatedBy)
        try c.encode(
            Attachments(blob: Attachments.Blob(contentType: contentType, data: data, stub: nil)),
            forKey: .attachments)
    }
}

/// Naming and sniffing for assets. The id *is* the content, so both apps must derive it the same
/// way: lowercase hex SHA-256 of the exact bytes, no framing, no normalization.
public enum CouchAssetID {
    /// The attachment name every asset document uses (protocol §7).
    public static let blobName = "blob"

    public static func sha256Hex(_ data: Data) -> String {
        hex(SHA256.hash(data: data))
    }

    public static func forBytes(_ data: Data) -> String {
        CouchDocID.asset(sha256Hex(data))
    }

    /// The hash a file's bytes carry, read in chunks so a large image never has to be resident.
    /// Nil when the file cannot be read — a dangling reference, which callers treat as "unknown
    /// content" rather than as an error.
    public static func sha256Hex(contentsOf url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var digest = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            digest.update(data: chunk)
        }
        return hex(digest.finalize())
    }

    /// The 64-hex body of an `asset:` id, or nil for anything that is not one. Also the check that
    /// says whether a filename *is* a hash, which is how a device recovers an asset id for an
    /// image whose bytes have not arrived yet.
    public static func sha256Hex(ofAssetID documentID: String) -> String? {
        guard let (type, id) = CouchDocID.split(documentID), type == CouchDocType.asset,
              isSHA256Hex(id)
        else { return nil }
        return id
    }

    public static func isSHA256Hex(_ text: String) -> Bool {
        text.count == 64 && text.allSatisfy { $0.isNumber || ("a"..."f").contains($0) }
    }

    /// Content type from the leading magic bytes. Only the formats a page image can actually be;
    /// anything else is served as opaque bytes, which still renders — both apps sniff the file
    /// rather than trusting the label.
    public static func contentType(of data: Data) -> String {
        func starts(with bytes: [UInt8], at offset: Int = 0) -> Bool {
            guard data.count >= offset + bytes.count else { return false }
            let start = data.index(data.startIndex, offsetBy: offset)
            return Array(data[start..<data.index(start, offsetBy: bytes.count)]) == bytes
        }
        if starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if starts(with: Array("GIF8".utf8)) { return "image/gif" }
        if starts(with: Array("RIFF".utf8)), starts(with: Array("WEBP".utf8), at: 8) {
            return "image/webp"
        }
        if starts(with: Array("ftypheic".utf8), at: 4) { return "image/heic" }
        if starts(with: Array("%PDF".utf8)) { return "application/pdf" }
        return "application/octet-stream"
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// Which backgrounds are files, and how one relates to the asset document carrying it between
/// devices. The twin of notable's `CouchBackgroundFiles` (`sync/couch/CouchAssets.kt`), and it
/// must agree with it.
///
/// A page's `background` is two different things depending on its `backgroundType`: for a native
/// template it is the template's name (`"blank"`, `"lined"`), and for a PDF or a picture it is a
/// path on whichever device wrote it. A path is the one thing that cannot travel — `pdfs/
/// lecture.pdf` names this device's `backgrounds/` store and nothing on the BOOX — so a
/// file-backed background travels as the `asset:<sha256>` id of its bytes, exactly as a placed
/// image does, and each device resolves that id to a path of its own.
///
/// The id goes in the same `background` field rather than beside it, deliberately. Both apps
/// already carry that field through verbatim, so a page that passes through a build which has
/// never heard of background assets comes back with the reference intact; a new field would be
/// dropped on the way and the peer's PDF would come loose from its pages.
public enum CouchBackgroundFiles {
    /// PDFs are told from pictures by their name — see `localPath(forAssetID:backgroundType:)`.
    private static let pdfExtension = ".pdf"

    /// The type keys are Notable's (`BackgroundType.kt`): `native`, `image`, `imagerepeating`,
    /// `coverImage`, `autoPdf` and `pdf<N>`. Everything but `native` is a file.
    public static func isFileBacked(_ backgroundType: String) -> Bool {
        isPDF(backgroundType) || backgroundType.hasPrefix("image")
            || backgroundType == "coverImage"
    }

    public static func isPDF(_ backgroundType: String) -> Bool {
        backgroundType.hasPrefix("pdf") || backgroundType == "autoPdf"
    }

    /// Which folder of the `backgrounds/` store a background of this type lives in.
    public static func folder(for backgroundType: String) -> TemplateFolder {
        if isPDF(backgroundType) { return .pdfs }
        if backgroundType == "coverImage" { return .covers }
        return .images
    }

    /// The local `backgrounds/` store under the app's data root — the same layout `TemplateStore`
    /// owns, restated here so the sync side can name a file without holding a store.
    public static func directory(under rootURL: URL) -> URL {
        rootURL.appendingPathComponent("backgrounds", isDirectory: true)
    }

    /// The asset document a background belongs to, or nil when this device cannot say what bytes
    /// it is showing — a file it does not hold, under a name that says nothing about its content.
    ///
    /// The filename is consulted before the bytes, which is the opposite of a placed image. A
    /// background named after a hash was written by sync and by nothing else — it is
    /// `localPath(forAssetID:)`'s own output — so its name is as good an answer as its content,
    /// and a great deal cheaper: backgrounds are the one asset that is routinely tens of
    /// megabytes and shared by every page of a notebook. Only a file imported under the user's
    /// own name has to be read, and `sha256` is where the caller puts the memory of having done
    /// so.
    public static func assetID(
        forBackground background: String, backgroundType: String, backgroundsDirectory: URL,
        sha256: (URL) -> String? = CouchAssetID.sha256Hex
    ) -> String? {
        guard isFileBacked(backgroundType), !background.isEmpty else { return nil }
        // Already an id: a page received while its bytes were still on their way keeps the
        // reference it arrived with, and must go on naming the same bytes when pushed back.
        if CouchAssetID.sha256Hex(ofAssetID: background) != nil { return background }
        guard let ref = TemplateRef.parse(background, impliedFolder: folder(for: backgroundType))
        else { return nil }
        if let sha = sha256Hex(ofFileName: ref.fileName) { return CouchDocID.asset(sha) }
        return sha256(backgroundsDirectory.appendingPathComponent(ref.relativePath))
            .map(CouchDocID.asset)
    }

    /// Where this device will keep the bytes of `assetID`, as the store-relative path the rest of
    /// the app reads (`pdfs/<sha>.pdf`, `images/<sha>`) — what a page points at while the
    /// download is still outstanding, and what it is drawn from once the bytes land.
    ///
    /// PDFs keep the extension because that is how the renderer tells a document to page through
    /// from a picture to decode; pictures are decoded by content, so a bare hash is enough.
    public static func localPath(forAssetID assetID: String, backgroundType: String) -> String? {
        guard let sha = CouchAssetID.sha256Hex(ofAssetID: assetID) else { return nil }
        let name = isPDF(backgroundType) ? "\(sha)\(pdfExtension)" : sha
        return "\(folder(for: backgroundType).rawValue)/\(name)"
    }

    /// Every name a downloaded background can have been given for `sha256Hex` — the reverse of
    /// `localPath(forAssetID:)`, for a lookup that has the hash but not the type that named it.
    public static func fileNames(forSHA256Hex sha: String) -> [String] {
        [sha, "\(sha)\(pdfExtension)"]
    }

    /// The hash a downloaded background's filename encodes, or nil for a name that is not one.
    public static func sha256Hex(ofFileName fileName: String) -> String? {
        let stem = fileName.hasSuffix(pdfExtension)
            ? String(fileName.dropLast(pdfExtension.count)) : fileName
        return CouchAssetID.isSHA256Hex(stem) ? stem : nil
    }
}
