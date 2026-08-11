import SwiftUI

/// A notebook cover in the Modernist language: a square-cornered 3:4 block with a
/// saturated spine down the left edge and the page count set as a micro-label.
///
/// When the notebook has ink on its first page the cover shows that page; when it doesn't,
/// a real preview would be a white rectangle, so the cover falls back to a drawn pattern
/// chosen deterministically from the notebook id. Patterns rather than tints on purpose —
/// a pale fill reads as paper on an e-ink panel, a pattern still reads as a pattern.
struct NotebookCoverView: View {
    /// Stable identity (the notebook id) — picks the spine colour and the pattern.
    let seed: String
    let title: String
    let pageCount: Int
    let thumbnail: UIImage?

    private static let spineWidth: CGFloat = 12

    private var style: CoverStyle { CoverStyle.forSeed(seed) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            base
            Rectangle()
                .fill(style.spine)
                .frame(width: Self.spineWidth)
                .frame(maxHeight: .infinity, alignment: .leading)
        }
        .aspectRatio(3.0 / 4.0, contentMode: .fit)
        .clipped()
        .overlay(
            Rectangle().strokeBorder(Modernist.neutral600, lineWidth: Modernist.ruleHair)
        )
        .overlay(alignment: .bottomLeading) { pageLabel }
    }

    @ViewBuilder
    private var base: some View {
        if let thumbnail {
            Color.white
                .overlay {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                }
        } else {
            ZStack(alignment: .topLeading) {
                style.fill
                CoverPatternView(pattern: style.pattern, color: style.onFill)
                Text(title)
                    .font(Modernist.display(15))
                    .tracking(Modernist.displayTracking(15))
                    .foregroundStyle(style.onFill)
                    .lineLimit(3)
                    .padding(.leading, Self.spineWidth + 10)
                    .padding(.trailing, 12)
                    .padding(.top, 16)
            }
        }
    }

    /// Sits on a paper chip rather than straight on the cover: over a page preview there
    /// is no telling what is underneath it.
    private var pageLabel: some View {
        Kicker("\(pageCount) p", color: Modernist.ink)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Modernist.paper)
            .padding(.leading, Self.spineWidth + 10)
            .padding(.bottom, 10)
    }
}

/// How a coverless notebook is drawn. The six variants mirror the design's cover set.
struct CoverStyle {
    let fill: Color
    let spine: Color
    /// Title and pattern colour — paper on the dark fills, ink on the light ones.
    let onFill: Color
    let pattern: CoverPattern

    static let all: [CoverStyle] = [
        CoverStyle(fill: Modernist.paper, spine: Modernist.accent700, onFill: Modernist.ink,
                   pattern: .ruled),
        CoverStyle(fill: Modernist.accent700, spine: Modernist.ink, onFill: Modernist.paper,
                   pattern: .none),
        CoverStyle(fill: Modernist.paper, spine: Modernist.ink, onFill: Modernist.ink,
                   pattern: .grid),
        CoverStyle(fill: Modernist.ink, spine: Modernist.accent600, onFill: Modernist.paper,
                   pattern: .none),
        CoverStyle(fill: Modernist.paper, spine: Modernist.neutral600, onFill: Modernist.ink,
                   pattern: .dotted),
        CoverStyle(fill: Modernist.paper, spine: Modernist.accent700, onFill: Modernist.ink,
                   pattern: .banded),
    ]

    static func forSeed(_ seed: String) -> CoverStyle {
        all[Modernist.stableIndex(seed, count: all.count)]
    }
}

enum CoverPattern {
    case none
    case ruled
    case grid
    case dotted
    case banded
}

/// Draws a cover pattern at the design's geometry. Cheap enough to run per render — it is
/// a handful of fills over a thumbnail-sized rect.
struct CoverPatternView: View {
    let pattern: CoverPattern
    let color: Color

    var body: some View {
        Canvas { context, size in
            switch pattern {
            case .none:
                break
            case .ruled:
                stripes(in: &context, size: size, thickness: 2, period: 16, opacity: 0.28)
            case .grid:
                stripes(in: &context, size: size, thickness: 1, period: 18, opacity: 0.22)
                stripes(
                    in: &context, size: size, thickness: 1, period: 18, opacity: 0.22,
                    vertical: true)
            case .dotted:
                dots(in: &context, size: size, radius: 1.4, period: 12, opacity: 0.35)
            case .banded:
                stripes(in: &context, size: size, thickness: 5, period: 26, opacity: 0.5)
            }
        }
        .allowsHitTesting(false)
    }

    private func stripes(
        in context: inout GraphicsContext, size: CGSize,
        thickness: CGFloat, period: CGFloat, opacity: Double, vertical: Bool = false
    ) {
        let shading = GraphicsContext.Shading.color(color.opacity(opacity))
        let extent = vertical ? size.width : size.height
        var offset: CGFloat = 0
        while offset < extent {
            let rect = vertical
                ? CGRect(x: offset, y: 0, width: thickness, height: size.height)
                : CGRect(x: 0, y: offset, width: size.width, height: thickness)
            context.fill(Path(rect), with: shading)
            offset += period
        }
    }

    private func dots(
        in context: inout GraphicsContext, size: CGSize,
        radius: CGFloat, period: CGFloat, opacity: Double
    ) {
        let shading = GraphicsContext.Shading.color(color.opacity(opacity))
        var y: CGFloat = period / 2
        while y < size.height {
            var x: CGFloat = period / 2
            while x < size.width {
                let rect = CGRect(
                    x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)
                context.fill(Path(ellipseIn: rect), with: shading)
                x += period
            }
            y += period
        }
    }
}
