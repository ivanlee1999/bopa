import Foundation
import NotableKit
import PencilKit
import UIKit

/// Two-way conversion between Notable strokes and PencilKit strokes.
///
/// Fidelity notes:
/// - Coordinates quantize to 0.01 (the wire format's polyline precision) — invisible.
/// - Pressure maps to per-point rendered size; on export, pressure is recovered from the
///   point-size ratio, so it round-trips monotonically.
/// - Tilt (tiltX/tiltY degrees) converts to/from PencilKit azimuth+altitude.
/// - Pen textures are approximated per platform (charcoal renders as Apple pencil ink here,
///   as Onyx charcoal on BOOX); geometry and color are shared exactly.
enum PencilKitBridge {

    /// Rendered width spans base*minWidthFactor ... base at pressure 0...1.
    private static let minWidthFactor: CGFloat = 0.3

    // MARK: Pen <-> Ink

    static func inkType(for pen: NotablePen) -> PKInk.InkType {
        switch pen {
        case .ballpen, .redBallpen, .greenBallpen, .blueBallpen, .dashed:
            return .pen
        case .fountain, .brush, .calligraphy:
            if #available(iOS 17.0, *) { return .fountainPen } else { return .pen }
        case .pencil, .charcoal:
            return .pencil
        case .marker:
            return .marker
        }
    }

    static func pen(for inkType: PKInk.InkType) -> NotablePen {
        if #available(iOS 17.0, *) {
            switch inkType {
            case .fountainPen: return .fountain
            case .watercolor: return .brush
            case .crayon: return .charcoal
            case .monoline: return .ballpen
            default: break
            }
        }
        switch inkType {
        case .pen: return .ballpen
        case .pencil: return .charcoal
        case .marker: return .marker
        default: return .ballpen
        }
    }

    // MARK: Notable -> PencilKit

    static func drawing(from strokes: [StrokeDTO]) -> PKDrawing {
        PKDrawing(strokes: strokes.compactMap { stroke(from: $0) })
    }

    static func stroke(from dto: StrokeDTO) -> PKStroke? {
        guard let points = try? dto.decodedPoints(), !points.isEmpty else { return nil }
        let ink = PKInk(inkType(for: NotablePen.from(dto.pen)), color: UIColor(argb: dto.color))
        let base = CGFloat(dto.size)

        let controlPoints = points.map { p -> PKStrokePoint in
            let pressure = CGFloat(p.pressure ?? 1)
            let width = max(base * (minWidthFactor + (1 - minWidthFactor) * pressure), 0.5)
            let tx = Double(p.tiltX ?? 0)
            let ty = Double(p.tiltY ?? 0)
            let magnitude = min((tx * tx + ty * ty).squareRoot(), 90)
            let azimuth = magnitude > 0 ? atan2(ty, tx) : 0
            let altitude = (Double.pi / 2) * (1 - magnitude / 90)
            return PKStrokePoint(
                location: CGPoint(x: CGFloat(p.x), y: CGFloat(p.y)),
                timeOffset: TimeInterval(p.dt ?? 0) / 1000,
                size: CGSize(width: width, height: width),
                opacity: 1,
                force: pressure,
                azimuth: CGFloat(azimuth),
                altitude: CGFloat(altitude))
        }
        let path = PKStrokePath(
            controlPoints: controlPoints,
            creationDate: NotableDate.parse(dto.createdAt) ?? Date())
        return PKStroke(ink: ink, path: path)
    }

    // MARK: PencilKit -> Notable

    static func strokeDTOs(from drawing: PKDrawing) -> [StrokeDTO] {
        drawing.strokes.compactMap { dto(from: $0) }
    }

    static func dto(from stroke: PKStroke) -> StrokeDTO? {
        let transform = stroke.transform
        let controlPoints = Array(stroke.path)
        guard !controlPoints.isEmpty else { return nil }

        let maxWidth = max(controlPoints.map(\.size.width).max() ?? 1, 0.5)

        var points: [NotableStrokePoint] = []
        points.reserveCapacity(controlPoints.count)
        for sp in controlPoints {
            let loc = sp.location.applying(transform)
            // Invert the width mapping used on import; falls back to full pressure for
            // uniform-width inks.
            let ratio = min(max(sp.size.width / maxWidth, minWidthFactor), 1)
            let pressure = Float((ratio - minWidthFactor) / (1 - minWidthFactor))

            let tiltMagnitude = 90 * (1 - sp.altitude / (.pi / 2))
            let tiltX = Int((cos(sp.azimuth) * tiltMagnitude).rounded())
            let tiltY = Int((sin(sp.azimuth) * tiltMagnitude).rounded())

            points.append(NotableStrokePoint(
                x: Float(loc.x),
                y: Float(max(loc.y, 0)),
                pressure: min(max(pressure, 0), 1),
                tiltX: min(max(tiltX, -90), 90),
                tiltY: min(max(tiltY, -90), 90),
                dt: UInt16(min(max((sp.timeOffset * 1000).rounded(), 0), 65534))))
        }

        guard let blob = try? SBStrokeCodec.encode(points) else { return nil }
        let bounds = stroke.renderBounds
        let now = NotableDate.format(Date())
        return StrokeDTO(
            id: UUID().uuidString.lowercased(),
            size: Float(maxWidth),
            pen: pen(for: stroke.ink.inkType),
            color: stroke.ink.color.argb,
            top: Float(bounds.minY),
            bottom: Float(bounds.maxY),
            left: Float(bounds.minX),
            right: Float(bounds.maxX),
            pointsData: blob.base64EncodedString(),
            createdAt: now,
            updatedAt: now)
    }
}

// MARK: - ARGB color packing

extension UIColor {
    convenience init(argb: Int32) {
        let v = UInt32(bitPattern: argb)
        self.init(
            red: CGFloat((v >> 16) & 0xFF) / 255,
            green: CGFloat((v >> 8) & 0xFF) / 255,
            blue: CGFloat(v & 0xFF) / 255,
            alpha: CGFloat((v >> 24) & 0xFF) / 255)
    }

    var argb: Int32 {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        // Resolve dynamic colors in light mode so both devices see the same ink color.
        let resolved = self.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        resolved.getRed(&r, green: &g, blue: &b, alpha: &a)
        func channel(_ c: CGFloat) -> UInt32 { UInt32((min(max(c, 0), 1) * 255).rounded()) }
        let v = (channel(a) << 24) | (channel(r) << 16) | (channel(g) << 8) | channel(b)
        return Int32(bitPattern: v)
    }
}
