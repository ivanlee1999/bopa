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

    /// Re-exports a drawing, reusing the original DTO for any stroke the user did not touch.
    ///
    /// `source` is the page's strokes as they were loaded. PencilKit preserves
    /// `path.creationDate` through an untouched stroke, and import seeds it from `dto.createdAt`
    /// (see `stroke(from:)`), so it re-identifies strokes across the round trip.
    ///
    /// This matters for two reasons. Identity: minting a fresh id per stroke per save made a page
    /// merely opened read as 100% changed, churning its ETag and making any content comparison —
    /// including conflict detection — worthless. Fidelity: re-encoding pushes every stroke through
    /// quantisation and a pressure→width→pressure round trip, so repeatedly opening a BOOX page
    /// used to degrade ink the user never touched.
    static func strokeDTOs(from drawing: PKDrawing, source: [StrokeDTO] = []) -> [StrokeDTO] {
        // Multi-map: two strokes *can* share a creation date, and handing both the same id would
        // be worse than re-encoding one. Entries are consumed on match, so each is claimed once.
        var byCreation: [Date: [StrokeDTO]] = [:]
        for dto in source {
            guard let created = NotableDate.parse(dto.createdAt) else { continue }
            byCreation[created, default: []].append(dto)
        }

        return drawing.strokes.flatMap { stroke -> [StrokeDTO] in
            // Carry the original over only when nothing about the stroke changed:
            // - a mask means the eraser cut into it, and reusing the original DTO there would
            //   save the rubbed-out ink straight back;
            // - a non-identity transform means it was moved (lasso).
            // Either way the geometry really did change, so it goes through `dtos(from:)`, which
            // also expands a part-erased stroke into its surviving pieces.
            let created = stroke.path.creationDate
            if stroke.mask == nil, stroke.transform.isIdentity,
               var candidates = byCreation[created], !candidates.isEmpty
            {
                let original = candidates.removeFirst()
                byCreation[created] = candidates
                return [original]
            }
            return dtos(from: stroke)
        }
    }

    /// One DTO per surviving piece of a stroke.
    ///
    /// The eraser does not shorten a stroke: PencilKit keeps the whole path and records the
    /// rubbed-out parts in `mask`. The Notable wire format has no mask, so the surviving
    /// parametric ranges are resampled into separate strokes — otherwise erasing saves
    /// nothing. A fully erased stroke yields no DTO.
    static func dtos(from stroke: PKStroke) -> [StrokeDTO] {
        guard stroke.mask != nil else { return [dto(from: stroke)].compactMap { $0 } }
        let path = stroke.path
        let ranges = stroke.maskedPathRanges
        // A masked stroke's renderBounds covers the mask rather than the surviving ink, so
        // every branch below derives its own box from the points it exports.
        guard path.count > 1 else {
            // A single-point stroke (a dot) is erased whole or not at all.
            guard !ranges.isEmpty else { return [] }
            return [dto(from: stroke, controlPoints: Array(path), bounds: nil)].compactMap { $0 }
        }
        return ranges.compactMap { range in
            // Untouched by this mask: keep the authored control points exactly.
            let points = range.lowerBound <= 0 && range.upperBound >= CGFloat(path.count - 1)
                ? Array(path)
                : sampled(path, in: range)
            guard points.count > 1 else { return nil }
            return dto(from: stroke, controlPoints: points, bounds: nil)
        }
    }

    /// Parametric samples across `range`: one per original control point, plus the exact
    /// endpoints (the eraser cuts between control points).
    private static func sampled(
        _ path: PKStrokePath, in range: ClosedRange<CGFloat>
    ) -> [PKStrokePoint] {
        var values: [CGFloat] = []
        var value = range.lowerBound
        while value < range.upperBound - 0.001 {
            values.append(value)
            value += 1
        }
        values.append(range.upperBound)
        return values.map { path.interpolatedPoint(at: $0) }
    }

    /// The whole stroke as one DTO, ignoring any eraser mask — use `dtos(from:)` to export
    /// a stroke that may have been erased into.
    static func dto(from stroke: PKStroke) -> StrokeDTO? {
        dto(from: stroke, controlPoints: Array(stroke.path), bounds: stroke.renderBounds)
    }

    /// - Parameter bounds: the stroke's render bounds when the whole stroke is exported;
    ///   nil for an erased segment, whose box is derived from the sampled points instead
    ///   (`renderBounds` covers the mask, not this one piece of the path).
    private static func dto(
        from stroke: PKStroke, controlPoints: [PKStrokePoint], bounds: CGRect?
    ) -> StrokeDTO? {
        let transform = stroke.transform
        guard !controlPoints.isEmpty else { return nil }

        let maxWidth = max(controlPoints.map(\.size.width).max() ?? 1, 0.5)
        let startTime = controlPoints[0].timeOffset

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
                // Rebased on the segment's own start, so a piece cut out of the middle of a
                // stroke still begins at t=0 (and stays inside dt's 16-bit range).
                dt: UInt16(min(max(((sp.timeOffset - startTime) * 1000).rounded(), 0), 65534))))
        }

        guard let blob = try? SBStrokeCodec.encode(points) else { return nil }
        let bounds = bounds ?? Self.bounds(of: controlPoints, transform: transform)
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

    /// Ink box around a run of points: the path's extent grown by half the widest point.
    private static func bounds(
        of controlPoints: [PKStrokePoint], transform: CGAffineTransform
    ) -> CGRect {
        let locations = controlPoints.map { $0.location.applying(transform) }
        let xs = locations.map(\.x)
        let ys = locations.map(\.y)
        let inset = max(controlPoints.map(\.size.width).max() ?? 1, 0.5) / 2
        return CGRect(
            x: (xs.min() ?? 0) - inset,
            y: (ys.min() ?? 0) - inset,
            width: (xs.max() ?? 0) - (xs.min() ?? 0) + inset * 2,
            height: (ys.max() ?? 0) - (ys.min() ?? 0) + inset * 2)
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
