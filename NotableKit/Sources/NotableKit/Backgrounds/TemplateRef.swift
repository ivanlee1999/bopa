import Foundation

/// Sub-directory of the local `backgrounds/` store an asset lives in. Mirrors
/// `BackgroundType.folderName` in Notable.
public enum TemplateFolder: String, CaseIterable, Sendable {
    case images
    case covers
    case pdfs
}

/// How a background asset path is written into page JSON.
public enum BackgroundPathStyle: Hashable, Sendable {
    /// `pdfs/weekly.pdf` — relative to the `backgrounds/` store. This is what Notable's sync
    /// *downloader* expects, and what we always write. See `docs/notable-sync-protocol.md` §7.
    case relative
    /// `<root>/pdfs/weekly.pdf` — an absolute device path, the way Notable's own picker writes it.
    /// Only useful when writing files a specific device will read locally; such a page's asset is
    /// skipped by Notable's sync.
    case absolute(root: String)
}

/// A reference to one asset file in the local `backgrounds/` store.
///
/// On the server the same asset is stored flat, by basename, under the notebook's `backgrounds/`
/// collection — so `fileName` is unique across the whole store, not just its folder.
public struct TemplateRef: Hashable, Sendable {
    public var folder: TemplateFolder
    /// Basename including extension, e.g. `weekly-planner.pdf`.
    public var fileName: String

    public init(folder: TemplateFolder, fileName: String) {
        self.folder = folder
        self.fileName = fileName
    }

    /// Path under the `backgrounds/` store, e.g. `pdfs/weekly-planner.pdf`.
    public var relativePath: String { "\(folder.rawValue)/\(fileName)" }

    /// Name used on the WebDAV server (uploads are flat: `backgrounds/<remoteName>`).
    public var remoteName: String { fileName }

    /// Display name with the extension stripped.
    public var displayName: String { (fileName as NSString).deletingPathExtension }

    public func wirePath(_ style: BackgroundPathStyle = .relative) -> String {
        switch style {
        case .relative:
            return relativePath
        case .absolute(let root):
            let trimmed = root.hasSuffix("/") ? String(root.dropLast()) : root
            return "\(trimmed)/\(relativePath)"
        }
    }

    /// Parse a `background` field written by either side.
    ///
    /// Tolerates every form seen in the wild: a store-relative path (`pdfs/x.pdf`), a bare basename
    /// (`x.pdf`), and the absolute device paths Notable's picker writes
    /// (`/storage/emulated/0/Documents/notabledb/backgrounds/pdfs/x.pdf`). `impliedFolder` comes
    /// from the `backgroundType` and is used when the string carries no folder of its own.
    public static func parse(_ wire: String, impliedFolder: TemplateFolder) -> TemplateRef? {
        let value = wire.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        // Everything after a `backgrounds/` component is store-relative, whatever came before it.
        var path = value
        if let range = value.range(of: "/backgrounds/") {
            path = String(value[range.upperBound...])
        } else if value.hasPrefix("backgrounds/") {
            path = String(value.dropFirst("backgrounds/".count))
        }

        let components = path.split(separator: "/").map(String.init)
        guard let fileName = components.last, !fileName.isEmpty else { return nil }

        let folder = components.dropLast().last.flatMap(TemplateFolder.init(rawValue:)) ?? impliedFolder
        return TemplateRef(folder: folder, fileName: fileName)
    }
}
