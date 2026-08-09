import CoreGraphics
import Foundation

/// Geometry of Notable's built-in grids, in page units, from `editor/drawing/backgrounds.kt`.
public enum NativeTemplateMetrics {
    /// `lineHeight` upstream: spacing of lines, squares and dots.
    public static let gridSpacing: CGFloat = 80
    /// `dotSize` upstream.
    public static let dotDiameter: CGFloat = 6
    public static let lineWidth: CGFloat = 1
    /// Android `Color.GRAY`.
    public static let lineColor = CGColor(red: 0x88 / 255, green: 0x88 / 255, blue: 0x88 / 255, alpha: 1)
    /// `hexVerticalCount` upstream.
    public static let hexVerticalCount: CGFloat = 26
}

/// Draws the native grids so a page looks the same on the iPad as it does on the BOOX.
///
/// Everything is in **page coordinates with y increasing downwards** — the caller sets up the
/// context transform (see `TemplateRenderer`). Notable's grids are anchored to the page origin at
/// multiples of `gridSpacing`, so they line up across devices at any scroll offset.
///
/// Hexagons are the one approximation: upstream derives the hex radius from the live canvas size,
/// which makes the pattern viewport-dependent. We mirror the formula using the rendered viewport,
/// so the two agree at matching viewport sizes and drift apart otherwise.
public enum NativeTemplateRenderer {
    public static func draw(
        _ template: NativeTemplate,
        in context: CGContext,
        viewport: CGRect,
        pageWidth: CGFloat
    ) {
        context.saveGState()
        defer { context.restoreGState() }

        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(viewport)

        context.setStrokeColor(NativeTemplateMetrics.lineColor)
        context.setFillColor(NativeTemplateMetrics.lineColor)
        context.setLineWidth(NativeTemplateMetrics.lineWidth)

        switch template {
        case .blank, .custom:
            break
        case .lined:
            strokeHorizontalLines(in: context, viewport: viewport, pageWidth: pageWidth)
        case .squared:
            strokeHorizontalLines(in: context, viewport: viewport, pageWidth: pageWidth)
            strokeVerticalLines(in: context, viewport: viewport, pageWidth: pageWidth)
        case .dotted:
            fillDots(in: context, viewport: viewport, pageWidth: pageWidth)
        case .hexed:
            strokeHexagons(in: context, viewport: viewport, pageWidth: pageWidth)
        }
    }

    // MARK: - Grids

    /// Grid coordinates are positive multiples of `gridSpacing`, matching upstream (which offsets
    /// its loops by one full step, so nothing is drawn on the page's top/left edge).
    private static func gridLines(from start: CGFloat, to end: CGFloat) -> StrideThrough<CGFloat> {
        let spacing = NativeTemplateMetrics.gridSpacing
        let first = max(spacing, (start / spacing).rounded(.down) * spacing)
        return stride(from: first, through: max(first, end), by: spacing)
    }

    private static func strokeHorizontalLines(in context: CGContext, viewport: CGRect, pageWidth: CGFloat) {
        for y in gridLines(from: viewport.minY, to: viewport.maxY) {
            context.move(to: CGPoint(x: 0, y: y))
            context.addLine(to: CGPoint(x: pageWidth, y: y))
        }
        context.strokePath()
    }

    private static func strokeVerticalLines(in context: CGContext, viewport: CGRect, pageWidth: CGFloat) {
        for x in gridLines(from: 0, to: pageWidth) {
            context.move(to: CGPoint(x: x, y: viewport.minY))
            context.addLine(to: CGPoint(x: x, y: viewport.maxY))
        }
        context.strokePath()
    }

    private static func fillDots(in context: CGContext, viewport: CGRect, pageWidth: CGFloat) {
        let diameter = NativeTemplateMetrics.dotDiameter
        for y in gridLines(from: viewport.minY, to: viewport.maxY) {
            for x in gridLines(from: 0, to: pageWidth) {
                context.fillEllipse(
                    in: CGRect(x: x - diameter / 2, y: y - diameter / 2, width: diameter, height: diameter)
                )
            }
        }
    }

    private static func strokeHexagons(in context: CGContext, viewport: CGRect, pageWidth: CGFloat) {
        let radius = max(pageWidth, viewport.height) / (NativeTemplateMetrics.hexVerticalCount * 1.5)
        guard radius > 0 else { return }
        let hexWidth = radius * 3.0.squareRoot()
        let rowHeight = radius * 2 * 0.75

        let firstRow = Int(((viewport.minY / rowHeight) - 1).rounded(.down))
        let lastRow = Int(((viewport.maxY / rowHeight) + 1).rounded(.up))
        let lastColumn = Int((pageWidth / hexWidth).rounded(.up)) + 1

        for row in firstRow...lastRow {
            let offsetX = row % 2 == 0 ? 0 : hexWidth / 2
            for column in 0...lastColumn {
                addHexagon(
                    to: context,
                    center: CGPoint(x: CGFloat(column) * hexWidth + offsetX, y: CGFloat(row) * rowHeight),
                    radius: radius
                )
            }
        }
        context.strokePath()
    }

    private static func addHexagon(to context: CGContext, center: CGPoint, radius: CGFloat) {
        for corner in 0...5 {
            let angle = CGFloat(30 + 60 * corner) * .pi / 180
            let point = CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
            if corner == 0 {
                context.move(to: point)
            } else {
                context.addLine(to: point)
            }
        }
        context.closePath()
    }
}
