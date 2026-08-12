import CoreGraphics
import Foundation

/// The coordinate space a page's ink, images and paper template all live in, on both apps.
///
/// One unit is exactly 0.15 mm (≈169.3 dpi). That constant is not arbitrary:
///
/// - A4 lands on 1400 × 1980 units, within 0.3% of the 1404 bopa hardcoded as "the page width"
///   before page sizes existed — so a notebook written before this type reads as it always did.
/// - Notable's 80-unit ruled-line spacing reads as 12 mm, which is ruled-paper spacing.
/// - `pointsPerUnit` converts to PostScript points, so A4 exports as 595.3 × 841.9 pt: the same
///   A4 box PDF, Xournal++ and Notable's own PDF export already use.
///
/// A unit is deliberately **not** a device pixel. A page whose width is the screen's width — what
/// Notable used, and what bopa's 1404 was copied from — is a *different page on every device*, so
/// ink written past the narrower device's edge is off-page there. That is the bug this type exists
/// to remove: the page is declared by the document, and each device scales to fit it.
public enum PageUnits {
    /// Millimetres per page unit. The definition everything else here derives from.
    public static let millimetresPerUnit = 0.15
    /// PostScript points (1/72 in) per page unit, for PDF and `.xopp` export.
    public static let pointsPerUnit = millimetresPerUnit / 25.4 * 72

    public static func points(fromUnits units: Double) -> Double { units * pointsPerUnit }
    public static func millimetres(fromUnits units: Double) -> Double {
        units * millimetresPerUnit
    }
}

/// A page's sheet size, in page units.
///
/// Portrait by convention (`width <= height`) and stored that way: turning a device sideways
/// changes how much of the sheet is on screen, not how big the sheet is. "Landscape" is a fit,
/// not a size.
///
/// Height is the *sheet* height, not a limit on writing: both apps keep scrolling past the
/// bottom of the sheet as they always have. It is what pagination and export divide by.
public struct PageSize: Equatable, Hashable, Sendable, Codable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    /// What bopa lays out for a page that declares no size: the 1404-wide page it hardcoded,
    /// with the 1872 sheet height its 3744-unit initial scroll extent was two of.
    ///
    /// Notable's fallback for the same page is its own screen width instead, which is exactly
    /// why the two apps disagree about notebooks predating this field and agree about the rest.
    /// Nothing retrofits it — an existing notebook keeps the geometry it was written with.
    public static let legacyUndeclared = PageSize(width: 1404, height: 1872)

    public var widthInPoints: Double { PageUnits.points(fromUnits: Double(width)) }
    public var heightInPoints: Double { PageUnits.points(fromUnits: Double(height)) }
}

/// A named paper size offered when a notebook is created.
///
/// The unit dimensions are written out rather than computed from `millimetres`, because the same
/// table has to exist in Kotlin: a rounding rule that differs by a single unit between the two
/// languages would put the two apps back to disagreeing about the page, which is the whole bug.
/// `docs/notable-sync-protocol.md` §3 holds the normative copy of this table.
public struct PageSizePreset: Equatable, Hashable, Sendable, Identifiable {
    /// Stable key, lowercase. Never localized — it is what a peer matches on.
    public let id: String
    /// Display name for the picker.
    public let name: String
    /// Nominal paper size in millimetres, for the picker's subtitle and for export.
    public let millimetres: CGSize
    public let size: PageSize

    public static let a3 = PageSizePreset(
        id: "a3", name: "A3", millimetres: CGSize(width: 297, height: 420),
        size: PageSize(width: 1980, height: 2800))
    public static let a4 = PageSizePreset(
        id: "a4", name: "A4", millimetres: CGSize(width: 210, height: 297),
        size: PageSize(width: 1400, height: 1980))
    public static let a5 = PageSizePreset(
        id: "a5", name: "A5", millimetres: CGSize(width: 148, height: 210),
        size: PageSize(width: 987, height: 1400))
    public static let letter = PageSizePreset(
        id: "letter", name: "Letter", millimetres: CGSize(width: 215.9, height: 279.4),
        size: PageSize(width: 1439, height: 1863))
    public static let legal = PageSizePreset(
        id: "legal", name: "Legal", millimetres: CGSize(width: 215.9, height: 355.6),
        size: PageSize(width: 1439, height: 2371))

    /// Picker order: the sizes people reach for most, largest-to-smallest within each family.
    public static let all: [PageSizePreset] = [a4, a5, a3, letter, legal]

    /// What a new notebook gets when nobody chooses. A4 rather than Letter because it is what
    /// the BOOX's own export path already assumes (`A4_WIDTH`/`A4_HEIGHT` in Notable).
    public static let `default` = a4

    /// The preset with these exact dimensions, or nil for a size no preset names — a notebook
    /// from a build that knows a size this one does not, which still renders from its own
    /// declared dimensions.
    public static func matching(_ size: PageSize) -> PageSizePreset? {
        all.first { $0.size == size }
    }

    /// How a size reads in the UI: the preset's name, or the millimetre size it works out to.
    public static func label(for size: PageSize) -> String {
        if let preset = matching(size) { return preset.name }
        let width = PageUnits.millimetres(fromUnits: Double(size.width)).rounded()
        let height = PageUnits.millimetres(fromUnits: Double(size.height)).rounded()
        return "\(Int(width))×\(Int(height)) mm"
    }
}

// MARK: - Reading a size off the wire models

/// Pairs the two optional dimensions back into one size. Both must be present to count: half a
/// declaration is not a sheet, and guessing the other half from an aspect ratio would put the two
/// apps back to laying out different pages.
private func declaredSize(_ width: Int?, _ height: Int?) -> PageSize? {
    guard let width, let height, width > 0, height > 0 else { return nil }
    return PageSize(width: width, height: height)
}

extension PageFile {
    /// The sheet this page declares, or nil for one written before page sizes existed.
    public var declaredPageSize: PageSize? { declaredSize(pageWidth, pageHeight) }

    /// The sheet to lay this page out on: its own declaration, or what bopa has always used.
    public var pageSize: PageSize { declaredPageSize ?? .legacyUndeclared }

    public mutating func setPageSize(_ size: PageSize) {
        pageWidth = size.width
        pageHeight = size.height
    }
}

extension NotebookManifest {
    /// The sheet new pages here are created with, or nil for a notebook created before page
    /// sizes existed — whose pages then declare none either, and so keep rendering as they did.
    public var declaredDefaultPageSize: PageSize? {
        declaredSize(defaultPageWidth, defaultPageHeight)
    }

    public mutating func setDefaultPageSize(_ size: PageSize) {
        defaultPageWidth = size.width
        defaultPageHeight = size.height
    }
}

extension CouchPage {
    public var declaredPageSize: PageSize? { declaredSize(pageWidth, pageHeight) }
}

extension CouchNotebook {
    public var declaredDefaultPageSize: PageSize? {
        declaredSize(defaultPageWidth, defaultPageHeight)
    }
}
