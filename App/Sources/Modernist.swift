import SwiftUI
import UIKit

/// The "Modernist" design language, ported from the Bopa BOOX design project.
///
/// Flat, architectural, zero corner radius. Structure is carried by 2pt ink rules and
/// 44/48pt rows rather than by tint, so the layout survives an e-ink panel washing the
/// colour layer out — the same reason colour only ever appears as a large saturated fill
/// (a spine, a chip, one ink) and never as a hairline or as small type.
///
/// Every value here comes from the design system's `styles.css` token sheet; nothing
/// downstream should hard-code a hex or a px the tokens already carry.
enum Modernist {

    // MARK: Ground

    /// Page ground behind the library.
    static let bg = Color(hex: 0xF3F2F2)
    /// Paper: the surface a device screen is drawn on.
    static let paper = Color(hex: 0xF6F5F3)
    /// Slightly recessed paper, for chrome that sits over content (bars, the tool rail).
    static let rail = Color(hex: 0xEEECE9)
    /// The writing surface itself — the brightest thing in the app.
    static let canvas = Color(hex: 0xFBFAF8)
    static let ink = Color(hex: 0x201E1D)

    // MARK: Accent ramp

    static let accent500 = Color(hex: 0xFF563C)
    /// Coral — the ramp step above the base red.
    static let accent600 = Color(hex: 0xDD2B0F)
    /// The red. Deep enough to carry paragraph-size type on this ground.
    static let accent700 = Color(hex: 0xAE1800)
    static let accent800 = Color(hex: 0x7C1405)

    // MARK: Neutral ramp

    static let neutral300 = Color(hex: 0xD7D3D3)
    /// Row separators — the hairline weight.
    static let neutral400 = Color(hex: 0xBAB6B6)
    static let neutral500 = Color(hex: 0x9B9797)
    /// Borders that need to read as a drawn edge rather than a divider.
    static let neutral600 = Color(hex: 0x7D7979)
    /// Kickers, counts, secondary meta.
    static let neutral700 = Color(hex: 0x605D5D)
    static let neutral800 = Color(hex: 0x444141)

    // MARK: Metrics

    /// Regular-width touch target. The design's e-ink build never goes below this.
    static let hit: CGFloat = 48
    /// Compact-width touch target (the one-handed layout).
    static let hitCompact: CGFloat = 44
    /// A section rule: heavy enough to organise without tint.
    static let ruleHeavy: CGFloat = 2
    static let ruleHair: CGFloat = 1
    /// Radius is 0 on purpose, everywhere. Named so the intent survives a refactor.
    static let radius: CGFloat = 0

    // MARK: Type

    /// The system face stands in for Archivo, which isn't bundled. Centralised here so
    /// dropping the real family in is a one-line change rather than a sweep.
    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    /// Display headings: heaviest weight, tight tracking (the design's -0.03em).
    static func display(_ size: CGFloat) -> Font { font(size, .heavy) }

    /// Tracking for a display heading at `size`, in points.
    static func displayTracking(_ size: CGFloat) -> CGFloat { -0.03 * size }

    // MARK: Inks

    /// The four inks the tool rail offers. Deliberately few and deliberately saturated:
    /// on Kaleido a pale ink is indistinguishable from grey, so a wide picker would be
    /// lying about what the BOOX can show.
    struct Ink: Identifiable, Hashable {
        let id: Int
        let name: String
        let color: Color
        let uiColor: UIColor
    }

    static let inks: [Ink] = [
        Ink(id: 0, name: "Ink", color: ink, uiColor: UIColor(hex: 0x201E1D)),
        Ink(id: 1, name: "Red", color: accent700, uiColor: UIColor(hex: 0xAE1800)),
        Ink(id: 2, name: "Coral", color: accent600, uiColor: UIColor(hex: 0xDD2B0F)),
        Ink(id: 3, name: "Grey", color: Color(hex: 0x888888), uiColor: UIColor(hex: 0x888888)),
    ]

    /// Index of the ink whose colour matches `uiColor`, if it is one of ours. Used to
    /// mirror a tool chosen in PencilKit's own palette back onto the rail.
    static func inkIndex(matching uiColor: UIColor) -> Int? {
        var (r, g, b, a) = (CGFloat(0), CGFloat(0), CGFloat(0), CGFloat(0))
        guard uiColor.getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
        return inks.first { candidate in
            var (cr, cg, cb, ca) = (CGFloat(0), CGFloat(0), CGFloat(0), CGFloat(0))
            guard candidate.uiColor.getRed(&cr, green: &cg, blue: &cb, alpha: &ca) else {
                return false
            }
            return abs(r - cr) < 0.02 && abs(g - cg) < 0.02 && abs(b - cb) < 0.02
        }?.id
    }

    /// A stable index into `count` derived from a string, so a notebook keeps the same
    /// spine colour across launches. `hashValue` is seeded per process and would not.
    static func stableIndex(_ seed: String, count: Int) -> Int {
        guard count > 0 else { return 0 }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in seed.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x1000_0000_01b3
        }
        return Int(hash % UInt64(count))
    }

    /// The saturated fills a cover spine or a folder chip may take. Ink is in the set on
    /// purpose: the design leans on black as much as on red.
    static let fills: [Color] = [accent700, ink, accent600, neutral600]

    static func fill(for seed: String) -> Color {
        fills[stableIndex(seed, count: fills.count)]
    }
}

// MARK: - Primitives

/// A section rule. Heavy (2pt ink) separates major blocks; hair (1pt) separates rows.
struct ModernistRule: View {
    var heavy = false

    var body: some View {
        Rectangle()
            .fill(heavy ? Modernist.ink : Modernist.neutral400)
            .frame(height: heavy ? Modernist.ruleHeavy : Modernist.ruleHair)
    }
}

/// The uppercase micro-label that titles every block. 10pt, wide tracking, neutral.
struct Kicker: View {
    let text: String
    var color: Color = Modernist.neutral700

    init(_ text: String, color: Color = Modernist.neutral700) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text.uppercased())
            .font(Modernist.font(10, .semibold))
            .tracking(1.6)
            .foregroundStyle(color)
    }
}

/// A kicker over a heavy rule: the header of a list section.
struct SectionHeading: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Kicker(text)
            ModernistRule(heavy: true)
        }
    }
}

/// A square action. `solid` is the one primary per screen (ink fill, paper glyph);
/// `outline` is everything else. Never rounded, never floating.
struct SquareActionStyle: ButtonStyle {
    enum Fill { case solid, outline }

    var fill: Fill = .outline
    var size: CGFloat = Modernist.hit

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        return configuration.label
            .frame(width: size, height: size)
            .foregroundStyle(fill == .solid ? Modernist.paper : Modernist.ink)
            .background(background(pressed: pressed))
            .overlay {
                if fill == .outline {
                    Rectangle().stroke(Modernist.ink, lineWidth: Modernist.ruleHair)
                }
            }
            .contentShape(Rectangle())
    }

    private func background(pressed: Bool) -> Color {
        switch fill {
        case .solid: pressed ? Modernist.accent700 : Modernist.ink
        case .outline: pressed ? Modernist.neutral300 : .clear
        }
    }
}

extension ButtonStyle where Self == SquareActionStyle {
    static var squareOutline: SquareActionStyle { SquareActionStyle(fill: .outline) }
    static var squareSolid: SquareActionStyle { SquareActionStyle(fill: .solid) }
}

// MARK: - Colour helpers

extension Color {
    /// 0xRRGGBB, in sRGB. The tokens are authored as hex and stay readable that way.
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255)
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1)
    }
}
