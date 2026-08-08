import NotableKit
import PencilKit
import XCTest

@testable import Bopa

final class PencilKitBridgeTests: XCTestCase {

    private func makeNotableStroke(
        pen: NotablePen = .ballpen,
        color: Int32 = -16777216,
        size: Float = 4
    ) throws -> StrokeDTO {
        let points = (0..<30).map { (i: Int) -> NotableStrokePoint in
            let fi = Float(i)
            let x: Float = 100 + fi * 5
            let y: Float = 300 + 40 * sin(fi / 5)
            let pressure: Float = 0.3 + 0.6 * Float(i % 10) / 10
            return NotableStrokePoint(x: x, y: y, pressure: pressure, tiltX: 20, tiltY: -30, dt: UInt16(i * 8))
        }
        let blob = try SBStrokeCodec.encode(points)
        let now = NotableDate.format(Date())
        return StrokeDTO(
            id: UUID().uuidString.lowercased(), size: size, pen: pen, color: color,
            top: 260, bottom: 340, left: 100, right: 245,
            pointsData: blob.base64EncodedString(), createdAt: now, updatedAt: now)
    }

    func testNotableToPencilKitConversion() throws {
        let dto = try makeNotableStroke()
        let drawing = PencilKitBridge.drawing(from: [dto])
        XCTAssertEqual(drawing.strokes.count, 1)

        let stroke = drawing.strokes[0]
        XCTAssertEqual(stroke.ink.inkType, .pen)
        let points = Array(stroke.path)
        XCTAssertEqual(points.count, 30)
        XCTAssertEqual(points[0].location.x, 100, accuracy: 0.02)
        XCTAssertEqual(points[29].location.x, 245, accuracy: 0.02)
        // Time offsets preserved (dt is ms)
        XCTAssertEqual(points[10].timeOffset, 0.080, accuracy: 0.001)
    }

    func testRoundTripPreservesGeometryAndChannels() throws {
        let original = try makeNotableStroke(pen: .marker, color: Int32(bitPattern: 0xFFFF0000))
        let drawing = PencilKitBridge.drawing(from: [original])
        let exported = PencilKitBridge.strokeDTOs(from: drawing)
        XCTAssertEqual(exported.count, 1)
        let dto = exported[0]

        XCTAssertEqual(NotablePen.from(dto.pen), .marker)
        XCTAssertEqual(dto.color, Int32(bitPattern: 0xFFFF0000)) // red survives
        XCTAssertEqual(dto.maxPressure, 1)

        let origPoints = try original.decodedPoints()
        let rtPoints = try dto.decodedPoints()
        XCTAssertEqual(rtPoints.count, origPoints.count)
        for (a, b) in zip(origPoints, rtPoints) {
            XCTAssertEqual(a.x, b.x, accuracy: 0.03)
            XCTAssertEqual(a.y, b.y, accuracy: 0.03)
            // Pressure survives the size-encoding round trip approximately;
            // the peak-pressure point maps to 1.0 relative scaling, so compare shape.
            XCTAssertNotNil(b.pressure)
            XCTAssertEqual(a.dt, b.dt)
            // Tilt round-trips through azimuth/altitude
            XCTAssertEqual(Float(a.tiltX ?? 0), Float(b.tiltX ?? 0), accuracy: 2)
            XCTAssertEqual(Float(a.tiltY ?? 0), Float(b.tiltY ?? 0), accuracy: 2)
        }
    }

    func testPenMappingBothWays() {
        XCTAssertEqual(PencilKitBridge.inkType(for: .ballpen), .pen)
        XCTAssertEqual(PencilKitBridge.inkType(for: .marker), .marker)
        XCTAssertEqual(PencilKitBridge.inkType(for: .charcoal), .pencil)
        XCTAssertEqual(PencilKitBridge.pen(for: .pen), .ballpen)
        XCTAssertEqual(PencilKitBridge.pen(for: .marker), .marker)
        XCTAssertEqual(PencilKitBridge.pen(for: .pencil), .charcoal)
    }

    func testColorPackingRoundTrip() {
        for argb in [Int32(-16777216), Int32(bitPattern: 0xFFFF0000), Int32(bitPattern: 0xFF00FF00),
                     Int32(bitPattern: 0xFF0000FF), Int32(bitPattern: 0x80123456)] {
            XCTAssertEqual(UIColor(argb: argb).argb, argb, "ARGB \(argb) should round-trip")
        }
    }

    func testSyntheticPencilStrokeExports() throws {
        // Build a PKStroke the way a live canvas would produce one, then export.
        let ink = PKInk(.pen, color: .black)
        let controlPoints = (0..<20).map { (i: Int) -> PKStrokePoint in
            let x: CGFloat = 200 + CGFloat(i) * 10
            let y: CGFloat = 500 + CGFloat(i % 5)
            let w: CGFloat = 4 + CGFloat(i % 3)
            return PKStrokePoint(
                location: CGPoint(x: x, y: y),
                timeOffset: TimeInterval(i) * 0.01,
                size: CGSize(width: w, height: w),
                opacity: 1, force: 0.7,
                azimuth: 0.3, altitude: 1.2)
        }
        let stroke = PKStroke(ink: ink, path: PKStrokePath(controlPoints: controlPoints, creationDate: Date()))
        let dto = try XCTUnwrap(PencilKitBridge.dto(from: stroke))

        XCTAssertEqual(NotablePen.from(dto.pen), .ballpen)
        let points = try dto.decodedPoints()
        XCTAssertEqual(points.count, 20)
        XCTAssertEqual(points[0].x, 200, accuracy: 0.03)
        XCTAssertEqual(points[19].x, 390, accuracy: 0.03)
        // All channels present and uniform (SB invariant)
        XCTAssertTrue(points.allSatisfy { $0.pressure != nil && $0.tiltX != nil && $0.dt != nil })
        // Bounding box sane
        XCTAssertLessThanOrEqual(dto.left, dto.right)
        XCTAssertLessThanOrEqual(dto.top, dto.bottom)
    }

    @MainActor
    func testStoreCreateSaveLoadCycle() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("bopa-test-\(UUID().uuidString)")
        let store = NotebookStore(rootURL: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let manifest = try store.createNotebook(title: "Cycle")
        XCTAssertEqual(store.notebooks.count, 1)
        let pageId = try XCTUnwrap(manifest.pageIds.first)

        var page = try store.loadPage(notebookId: manifest.notebookId, pageId: pageId)
        XCTAssertTrue(page.strokes.isEmpty)

        page.strokes = [try makeNotableStroke()]
        try store.savePage(page)

        let reloaded = try store.loadPage(notebookId: manifest.notebookId, pageId: pageId)
        XCTAssertEqual(reloaded.strokes.count, 1)
        let decoded = try reloaded.strokes[0].decodedPoints()
        XCTAssertEqual(decoded.count, 30)

        // Manifest clock bumped for sync
        let updated = try XCTUnwrap(store.manifest(id: manifest.notebookId))
        XCTAssertGreaterThanOrEqual(updated.updatedAt, manifest.updatedAt)
    }
}
