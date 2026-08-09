import CoreGraphics
import Foundation

/// One page template: the thing a page is set up with.
///
/// A template is always a **single page** — a built-in native grid, an imported image, or one page
/// of an imported PDF. Importing a multi-page PDF (an onPlanners planner, say) yields one
/// `Template` per PDF page, all sharing the same underlying file.
public struct Template: Identifiable, Hashable, Sendable {
    public enum Source: Hashable, Sendable {
        case native(NativeTemplate)
        case image(TemplateRef, repeating: Bool)
        /// `pageIndex` is 0-based, matching Notable's `pdf<N>` background type.
        case pdf(TemplateRef, pageIndex: Int)
    }

    public var source: Source
    /// Name to show in a picker.
    public var name: String
    /// Natural size of the template page in points, when known (PDF box / image pixels).
    public var pageSize: CGSize?

    public init(source: Source, name: String, pageSize: CGSize? = nil) {
        self.source = source
        self.name = name
        self.pageSize = pageSize
    }

    public var id: String {
        switch source {
        case .native(let template): "native:\(template.name)"
        case .image(let ref, let repeating): "\(ref.relativePath)\(repeating ? "#repeat" : "")"
        case .pdf(let ref, let pageIndex): "\(ref.relativePath)#\(pageIndex)"
        }
    }

    /// The asset file backing this template, if it isn't a built-in.
    public var ref: TemplateRef? {
        switch source {
        case .native: nil
        case .image(let ref, _): ref
        case .pdf(let ref, _): ref
        }
    }

    /// How this template is written into a page's background fields.
    public var background: PageBackground {
        switch source {
        case .native(let template): .native(template)
        case .image(let ref, let repeating): repeating ? .repeatingImage(ref) : .image(ref)
        case .pdf(let ref, let pageIndex): .pdfPage(ref, index: pageIndex)
        }
    }

    public static func native(_ template: NativeTemplate) -> Template {
        Template(source: .native(template), name: template.displayName)
    }

    /// The five backgrounds Notable can draw without any asset file.
    public static let builtIns: [Template] = NativeTemplate.builtIn.map(Template.native)

    /// Same template, repeated down the page instead of drawn once at the top. Images only —
    /// returns `self` unchanged for PDFs and native grids.
    public func repeatingDownThePage(_ repeating: Bool = true) -> Template {
        guard case .image(let ref, _) = source else { return self }
        var copy = self
        copy.source = .image(ref, repeating: repeating)
        return copy
    }
}
