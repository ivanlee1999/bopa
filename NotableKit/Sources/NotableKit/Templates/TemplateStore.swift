import CryptoKit
import Foundation

public enum TemplateError: Error, Equatable {
    /// The file isn't a PDF or a supported image type.
    case unsupportedFileType(String)
    case unreadableFile(URL)
    case invalidPDF(URL)
    case pageOutOfRange(index: Int, pageCount: Int)
    /// A template's asset file isn't in the local store (not synced down yet, or deleted).
    case missingAsset(TemplateRef)
    case renderFailed
}

/// The local `backgrounds/` store: the on-disk home of imported template assets.
///
/// Layout mirrors Notable's (`data/dbUtils.kt`), so the same relative paths appear in page JSON on
/// both devices:
///
/// ```
/// <notableDirectory>/backgrounds/pdfs/<file>.pdf
///                               /images/<file>.png
///                               /covers/<file>.png
/// ```
///
/// File names are unique across the whole store, not per folder: the WebDAV layout puts every
/// asset flat under `backgrounds/<basename>` in a notebook, so two same-named files in different
/// folders would collide on the server.
public struct TemplateStore: Sendable {
    public let backgroundsDirectory: URL

    /// `FileManager.default` is safe to use concurrently for the file operations here.
    private var fileManager: FileManager { .default }

    /// - Parameter notableDirectory: the app's data root; `backgrounds/` is created inside it.
    public init(notableDirectory: URL) {
        self.init(
            backgroundsDirectory: notableDirectory.appending(path: "backgrounds", directoryHint: .isDirectory)
        )
    }

    public init(backgroundsDirectory: URL) {
        self.backgroundsDirectory = backgroundsDirectory
    }

    // MARK: - Locations

    public func directoryURL(for folder: TemplateFolder) -> URL {
        backgroundsDirectory.appending(path: folder.rawValue, directoryHint: .isDirectory)
    }

    public func fileURL(for ref: TemplateRef) -> URL {
        directoryURL(for: ref.folder).appending(path: ref.fileName, directoryHint: .notDirectory)
    }

    public func exists(_ ref: TemplateRef) -> Bool {
        fileManager.fileExists(atPath: fileURL(for: ref).path(percentEncoded: false))
    }

    /// Create the store directories. Safe to call repeatedly.
    public func prepare() throws {
        for folder in TemplateFolder.allCases {
            try fileManager.createDirectory(at: directoryURL(for: folder), withIntermediateDirectories: true)
        }
    }

    // MARK: - Importing

    /// Copy a user-picked file (a downloaded planner PDF, a scanned page, …) into the store.
    ///
    /// The caller is responsible for security-scoped access when the URL comes from a document
    /// picker. Re-importing a byte-identical file returns the existing reference instead of making
    /// a duplicate.
    ///
    /// - Parameters:
    ///   - folder: forced destination; inferred from the file extension when `nil`.
    ///   - preferredName: display name to base the stored file name on; defaults to the source name.
    @discardableResult
    public func install(
        contentsOf sourceURL: URL,
        into folder: TemplateFolder? = nil,
        preferredName: String? = nil
    ) throws -> TemplateRef {
        let fileExtension = sourceURL.pathExtension.lowercased()
        guard let destination = folder ?? Self.folder(forFileExtension: fileExtension) else {
            throw TemplateError.unsupportedFileType(fileExtension)
        }
        guard let data = try? Data(contentsOf: sourceURL) else {
            throw TemplateError.unreadableFile(sourceURL)
        }

        try prepare()

        if let existing = try refWithIdenticalContents(data, in: destination) {
            return existing
        }

        let desired = Self.sanitizedFileName(
            preferredName ?? sourceURL.lastPathComponent,
            defaultExtension: fileExtension.isEmpty ? destination.defaultExtension : fileExtension
        )
        let ref = TemplateRef(folder: destination, fileName: try availableFileName(desired))
        try data.write(to: fileURL(for: ref), options: .atomic)
        return ref
    }

    /// Write an asset pulled from the server. The remote name is authoritative, so this overwrites
    /// rather than renaming — the page JSON already points at this exact name.
    @discardableResult
    public func installDownloaded(
        data: Data,
        fileName: String,
        into folder: TemplateFolder
    ) throws -> TemplateRef {
        try prepare()
        let ref = TemplateRef(folder: folder, fileName: (fileName as NSString).lastPathComponent)
        try data.write(to: fileURL(for: ref), options: .atomic)
        return ref
    }

    public func remove(_ ref: TemplateRef) throws {
        let url = fileURL(for: ref)
        if fileManager.fileExists(atPath: url.path(percentEncoded: false)) {
            try fileManager.removeItem(at: url)
        }
    }

    /// Every asset currently in the store, sorted by name.
    public func storedRefs(in folders: [TemplateFolder] = TemplateFolder.allCases) throws -> [TemplateRef] {
        var refs: [TemplateRef] = []
        for folder in folders {
            let directory = directoryURL(for: folder)
            guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path(percentEncoded: false))
            else { continue }
            refs += names
                .filter { !$0.hasPrefix(".") }
                .map { TemplateRef(folder: folder, fileName: $0) }
        }
        return refs.sorted { ($0.folder.rawValue, $0.fileName) < ($1.folder.rawValue, $1.fileName) }
    }

    // MARK: - Naming

    public static func folder(forFileExtension fileExtension: String) -> TemplateFolder? {
        switch fileExtension.lowercased() {
        case "pdf": .pdfs
        case "png", "jpg", "jpeg", "heic", "heif", "webp", "gif", "bmp", "tif", "tiff": .images
        default: nil
        }
    }

    /// Make a file name that survives a round trip through a WebDAV URL: ASCII-ish, no separators,
    /// no spaces, bounded length.
    public static func sanitizedFileName(_ raw: String, defaultExtension: String) -> String {
        let basename = (raw as NSString).lastPathComponent
        var fileExtension = (basename as NSString).pathExtension.lowercased()
        if fileExtension.isEmpty { fileExtension = defaultExtension.lowercased() }

        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        var stem = ""
        for scalar in (basename as NSString).deletingPathExtension.unicodeScalars {
            stem.unicodeScalars.append(allowed.contains(scalar) ? scalar : "-")
        }
        while stem.contains("--") { stem = stem.replacingOccurrences(of: "--", with: "-") }
        stem = stem.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if stem.isEmpty { stem = "template" }
        if stem.count > 80 { stem = String(stem.prefix(80)) }

        return fileExtension.isEmpty ? stem : "\(stem).\(fileExtension)"
    }

    /// `weekly.pdf` → `weekly-2.pdf` when the name is taken anywhere in the store.
    func availableFileName(_ desired: String) throws -> String {
        let taken = Set(try storedRefs().map(\.fileName))
        guard taken.contains(desired) else { return desired }

        let stem = (desired as NSString).deletingPathExtension
        let fileExtension = (desired as NSString).pathExtension
        for suffix in 2...999 {
            let candidate = fileExtension.isEmpty ? "\(stem)-\(suffix)" : "\(stem)-\(suffix).\(fileExtension)"
            if !taken.contains(candidate) { return candidate }
        }
        return fileExtension.isEmpty
            ? "\(stem)-\(UUID().uuidString)"
            : "\(stem)-\(UUID().uuidString).\(fileExtension)"
    }

    private func refWithIdenticalContents(_ data: Data, in folder: TemplateFolder) throws -> TemplateRef? {
        let digest = Data(SHA256.hash(data: data))
        for ref in try storedRefs(in: [folder]) {
            guard let existing = try? Data(contentsOf: fileURL(for: ref)),
                  existing.count == data.count,
                  Data(SHA256.hash(data: existing)) == digest
            else { continue }
            return ref
        }
        return nil
    }
}

extension TemplateFolder {
    var defaultExtension: String {
        switch self {
        case .pdfs: "pdf"
        case .images, .covers: "png"
        }
    }
}
