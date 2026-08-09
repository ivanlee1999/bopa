import CoreGraphics
import Foundation

/// Import templates and list what's available to write on.
///
/// The typical flow for a planner downloaded from onplanners.com:
///
/// ```swift
/// let library = TemplateLibrary(notableDirectory: appSupport)
/// let pages = try library.importTemplates(from: downloadedPDF)   // one Template per PDF page
/// let daily = pages[2]                                           // pick the page you want
/// let fields = TemplateApplication.pageFields(for: daily)        // -> page JSON background fields
/// ```
public struct TemplateLibrary: Sendable {
    public let store: TemplateStore

    public init(store: TemplateStore) {
        self.store = store
    }

    public init(notableDirectory: URL) {
        self.init(store: TemplateStore(notableDirectory: notableDirectory))
    }

    // MARK: - Import

    /// Copy a PDF or image into the store and return the page templates it contains.
    ///
    /// A multi-page PDF yields one single-page template per page — nothing is split on disk, the
    /// templates just carry different page indices into the same file. A byte-identical re-import
    /// reuses the stored file.
    ///
    /// - Parameter name: display name to base the stored file name on; defaults to the file's own.
    public func importTemplates(from url: URL, named name: String? = nil) throws -> [Template] {
        let ref = try store.install(contentsOf: url, preferredName: name)
        return try templates(for: ref, displayName: name.map { ($0 as NSString).deletingPathExtension })
    }

    /// The page templates an already-stored asset provides.
    public func templates(for ref: TemplateRef, displayName: String? = nil) throws -> [Template] {
        let url = store.fileURL(for: ref)
        guard store.exists(ref) else { throw TemplateError.missingAsset(ref) }
        let base = displayName ?? ref.displayName

        switch ref.folder {
        case .pdfs:
            let document = try PDFSupport.document(at: url)
            let pageCount = document.numberOfPages
            return (0..<pageCount).map { index in
                let size = document.page(at: index + 1).map(PDFSupport.displaySize(of:))
                return Template(
                    source: .pdf(ref, pageIndex: index),
                    name: pageCount == 1 ? base : "\(base) · page \(index + 1)",
                    pageSize: size
                )
            }
        case .images, .covers:
            return [
                Template(
                    source: .image(ref, repeating: false),
                    name: base,
                    pageSize: ImageSupport.pixelSize(at: url)
                )
            ]
        }
    }

    /// Every imported page template in the store (covers excluded — they're notebook art, not
    /// something you write on).
    public func importedTemplates() throws -> [Template] {
        try store.storedRefs(in: [.pdfs, .images]).flatMap { ref in
            (try? templates(for: ref)) ?? []
        }
    }

    /// Built-in native grids first, then everything imported.
    public func allTemplates() throws -> [Template] {
        Template.builtIns + (try importedTemplates())
    }

    /// Delete the asset file behind a template. Every template sharing that file (the other pages
    /// of a PDF) goes with it, so check `templatesSharingAsset(with:)` first if that matters.
    public func remove(_ template: Template) throws {
        guard let ref = template.ref else { return }
        try store.remove(ref)
    }

    public func templatesSharingAsset(with template: Template) throws -> [Template] {
        guard let ref = template.ref else { return [] }
        return try templates(for: ref)
    }

    /// Number of page templates an asset provides, without building them all.
    public func pageCount(of ref: TemplateRef) throws -> Int {
        guard store.exists(ref) else { throw TemplateError.missingAsset(ref) }
        switch ref.folder {
        case .pdfs: return try PDFSupport.document(at: store.fileURL(for: ref)).numberOfPages
        case .images, .covers: return 1
        }
    }
}
