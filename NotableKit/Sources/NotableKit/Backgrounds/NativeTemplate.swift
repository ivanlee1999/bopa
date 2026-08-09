import Foundation

/// A background Notable draws itself, with no asset file: the `background` string of a page whose
/// `backgroundType` is `"native"`.
///
/// The five built-ins are the ones Notable's background picker offers (`BackgroundSelector.kt`).
/// Anything else is preserved verbatim as `.custom` so a round-trip through this app never loses a
/// value a newer Notable may have written — but note that Notable *throws* when asked to draw a
/// native name it doesn't know, so we never emit one ourselves.
public enum NativeTemplate: Hashable, Sendable {
    case blank
    case dotted
    case lined
    case squared
    case hexed
    /// A native name written by some other (newer) Notable build. Rendered as blank.
    case custom(String)

    public static let builtIn: [NativeTemplate] = [.blank, .dotted, .lined, .squared, .hexed]

    public init(name: String) {
        switch name {
        case "blank": self = .blank
        case "dotted": self = .dotted
        case "lined": self = .lined
        case "squared": self = .squared
        case "hexed": self = .hexed
        default: self = .custom(name)
        }
    }

    /// The value written to a page's `background` field.
    public var name: String {
        switch self {
        case .blank: "blank"
        case .dotted: "dotted"
        case .lined: "lined"
        case .squared: "squared"
        case .hexed: "hexed"
        case .custom(let name): name
        }
    }

    public var displayName: String {
        switch self {
        case .blank: "Blank"
        case .dotted: "Dot grid"
        case .lined: "Lines"
        case .squared: "Small squares"
        case .hexed: "Hexagons"
        case .custom(let name): name.capitalized
        }
    }

    /// Whether this app knows how to draw it (see `NativeTemplateRenderer`).
    public var isDrawable: Bool {
        if case .custom = self { return false }
        return true
    }
}
