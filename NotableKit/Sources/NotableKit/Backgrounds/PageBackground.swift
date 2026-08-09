import Foundation

/// The `background` / `backgroundType` pair as it appears in `manifest.json` and page JSON.
public struct BackgroundFields: Hashable, Sendable {
    public var background: String
    public var backgroundType: String

    public init(background: String, backgroundType: String) {
        self.background = background
        self.backgroundType = backgroundType
    }
}

/// A page background, decoded from the two wire fields.
///
/// Parity with Notable's `BackgroundType` (`data/model/BackgroundType.kt`): the type keys are
/// `native`, `image`, `imagerepeating`, `coverImage`, `autoPdf` and `pdf<N>` (N is a **0-based**
/// PDF page index).
public enum PageBackground: Hashable, Sendable {
    case native(NativeTemplate)
    /// A single image, scaled to page width and anchored at the top of the page.
    case image(TemplateRef)
    /// An image tiled down the (infinitely scrolling) page.
    case repeatingImage(TemplateRef)
    /// Notebook cover art; Notable overlays a title box on it.
    case coverImage(TemplateRef)
    /// One fixed page of a PDF. `index` is 0-based.
    case pdfPage(TemplateRef, index: Int)
    /// A PDF whose displayed page follows the page's position in its notebook.
    case autoPDF(TemplateRef)

    public static let blank = PageBackground.native(.blank)

    /// Decode a page's two background fields. Total: anything unrecognized degrades to a native
    /// background, matching Notable's own `BackgroundType.fromKey` fallback.
    public init(fields: BackgroundFields) {
        self.init(background: fields.background, backgroundType: fields.backgroundType)
    }

    public init(background: String, backgroundType: String) {
        func ref(_ folder: TemplateFolder) -> TemplateRef? {
            TemplateRef.parse(background, impliedFolder: folder)
        }

        switch backgroundType {
        case "native":
            self = background.isEmpty ? .blank : .native(NativeTemplate(name: background))
        case "image":
            self = ref(.images).map { .image($0) } ?? .blank
        case "imagerepeating":
            self = ref(.images).map { .repeatingImage($0) } ?? .blank
        case "coverImage":
            self = ref(.covers).map { .coverImage($0) } ?? .blank
        case "autoPdf":
            self = ref(.pdfs).map { .autoPDF($0) } ?? .blank
        default:
            if backgroundType.hasPrefix("pdf"), let index = Int(backgroundType.dropFirst("pdf".count)) {
                self = ref(.pdfs).map { .pdfPage($0, index: index) } ?? .blank
            } else if background.isEmpty {
                self = .blank
            } else {
                self = .native(NativeTemplate(name: background))
            }
        }
    }

    /// The `backgroundType` value.
    public var typeKey: String {
        switch self {
        case .native: "native"
        case .image: "image"
        case .repeatingImage: "imagerepeating"
        case .coverImage: "coverImage"
        case .pdfPage(_, let index): "pdf\(index)"
        case .autoPDF: "autoPdf"
        }
    }

    /// The asset this background needs, if any.
    public var templateRef: TemplateRef? {
        switch self {
        case .native: nil
        case .image(let ref), .repeatingImage(let ref), .coverImage(let ref), .autoPDF(let ref):
            ref
        case .pdfPage(let ref, _): ref
        }
    }

    /// Encode back to the two wire fields.
    public func fields(pathStyle: BackgroundPathStyle = .relative) -> BackgroundFields {
        switch self {
        case .native(let template):
            BackgroundFields(background: template.name, backgroundType: typeKey)
        default:
            BackgroundFields(
                background: templateRef?.wirePath(pathStyle) ?? NativeTemplate.blank.name,
                backgroundType: templateRef == nil ? "native" : typeKey
            )
        }
    }
}
