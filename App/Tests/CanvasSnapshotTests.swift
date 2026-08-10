import NotableKit
import PencilKit
import SnapshotTesting
import XCTest

@testable import Bopa

/// Pixel references for what Notable strokes look like once bridged into PencilKit — the visual
/// half of the round-trip that PencilKitBridgeTests verifies numerically. A regression in pen
/// mapping, pressure-to-width scaling, or colour unpacking shows up here as an image diff,
/// without a UI test.
///
/// After an intentional visual change, re-record with `RECORD=1 ./scripts/test.sh app` and
/// eyeball the diff before committing.
final class CanvasSnapshotTests: XCTestCase {

    // Tolerances absorb GPU/OS antialiasing drift between the local simulator and CI's,
    // without letting a real rendering change through.
    private let strategy = Snapshotting<UIImage, UIImage>.image(
        precision: 0.99, perceptualPrecision: 0.97)

    private func stroke(
        pen: NotablePen,
        color: Int32,
        size: Float,
        baseY: Float,
        pressure: (Int) -> Float
    ) throws -> StrokeDTO {
        let points = (0..<40).map { (i: Int) -> NotableStrokePoint in
            let fi = Float(i)
            return NotableStrokePoint(
                x: 20 + fi * 6,
                y: baseY + 25 * sin(fi / 4),
                pressure: pressure(i),
                tiltX: 20, tiltY: -30,
                dt: UInt16(i * 8))
        }
        let blob = try SBStrokeCodec.encode(points)
        return StrokeDTO(
            id: "snapshot-\(pen.rawValue)-\(baseY)", size: size, pen: pen, color: color,
            top: baseY - 30, bottom: baseY + 30, left: 20, right: 260,
            pointsData: blob.base64EncodedString(),
            createdAt: "2026-01-01 00:00:00", updatedAt: "2026-01-01 00:00:00")
    }

    private func image(of strokes: [StrokeDTO]) -> UIImage {
        let drawing = PencilKitBridge.drawing(from: strokes)
        return drawing.image(from: CGRect(x: 0, y: 0, width: 280, height: 260), scale: 2)
    }

    func testPressureShapesTheBallpenStroke() throws {
        // Pressure ramps 0.2 → 1.0 along the stroke; the rendered width must follow it.
        let dto = try stroke(
            pen: .ballpen, color: -16777216, size: 5, baseY: 60,
            pressure: { 0.2 + 0.8 * Float($0) / 39 })
        assertSnapshot(of: image(of: [dto]), as: strategy)
    }

    func testEachPenRendersItsOwnInk() throws {
        // One stroke per pen family on one page: ballpen (black), marker (red), fountain (blue).
        let strokes = [
            try stroke(pen: .ballpen, color: -16777216, size: 4, baseY: 50, pressure: { _ in 0.7 }),
            try stroke(
                pen: .marker, color: Int32(bitPattern: 0xFFFF0000), size: 10, baseY: 125,
                pressure: { _ in 0.7 }),
            try stroke(
                pen: .fountain, color: Int32(bitPattern: 0xFF0000FF), size: 5, baseY: 200,
                pressure: { 0.3 + 0.6 * Float($0 % 10) / 10 }),
        ]
        assertSnapshot(of: image(of: strokes), as: strategy)
    }
}
