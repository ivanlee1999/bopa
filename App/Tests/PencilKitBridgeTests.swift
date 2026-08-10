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

    // MARK: - Eraser

    /// A horizontal stroke from (0,100) to (100,100), 11 control points one parametric
    /// step apart — the shape the eraser tests cut pieces out of.
    private func straightStroke(
        transform: CGAffineTransform = .identity,
        mask: UIBezierPath? = nil,
        ink: PKInk = PKInk(.pen, color: .black)
    ) -> PKStroke {
        let controlPoints = (0...10).map { i -> PKStrokePoint in
            PKStrokePoint(
                location: CGPoint(x: CGFloat(i) * 10, y: 100),
                timeOffset: TimeInterval(i) * 0.01,
                size: CGSize(width: 5, height: 5),
                opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(
            ink: ink,
            path: PKStrokePath(controlPoints: controlPoints, creationDate: Date()),
            transform: transform,
            mask: mask)
    }

    /// A band tall enough to cover the test stroke, spanning `x` horizontally.
    private func mask(keepingX x: ClosedRange<CGFloat>) -> UIBezierPath {
        UIBezierPath(rect: CGRect(x: x.lowerBound, y: 50, width: x.upperBound - x.lowerBound, height: 100))
    }

    func testEraserTrimsTheSavedStroke() throws {
        // Rub out everything past x=45. PencilKit keeps the full path and records a mask;
        // the saved stroke must be the surviving piece, not the original.
        let stroke = straightStroke(mask: mask(keepingX: -10...45))
        let dtos = PencilKitBridge.dtos(from: stroke)
        XCTAssertEqual(dtos.count, 1)

        let points = try dtos[0].decodedPoints()
        XCTAssertEqual(points.first?.x ?? 0, 0, accuracy: 0.03)
        XCTAssertEqual(points.last?.x ?? 0, 45, accuracy: 0.03)
        // Bounding box follows the surviving ink, not the mask.
        XCTAssertEqual(dtos[0].left, -2.5, accuracy: 0.03)
        XCTAssertEqual(dtos[0].right, 47.5, accuracy: 0.03)
    }

    func testEraserSplitsAStrokeIntoSurvivingSegments() throws {
        // Erase the middle: two separate strokes must be saved.
        let holes = mask(keepingX: -10...22)
        holes.append(mask(keepingX: 68...128))
        let dtos = PencilKitBridge.dtos(from: straightStroke(mask: holes))
        XCTAssertEqual(dtos.count, 2)

        let first = try dtos[0].decodedPoints()
        let second = try dtos[1].decodedPoints()
        XCTAssertEqual(first.first?.x ?? 0, 0, accuracy: 0.03)
        XCTAssertEqual(first.last?.x ?? 0, 22, accuracy: 0.03)
        XCTAssertEqual(second.first?.x ?? 0, 68, accuracy: 0.03)
        XCTAssertEqual(second.last?.x ?? 0, 100, accuracy: 0.03)
        // Each piece is a stroke in its own right: its clock starts at zero.
        XCTAssertEqual(second.first?.dt, 0)
        XCTAssertEqual(dtos[0].size, dtos[1].size)
    }

    func testFullyErasedStrokeIsNotSaved() {
        let elsewhere = UIBezierPath(rect: CGRect(x: 500, y: 500, width: 10, height: 10))
        XCTAssertTrue(PencilKitBridge.dtos(from: straightStroke(mask: elsewhere)).isEmpty)
    }

    func testUntouchedStrokeKeepsItsAuthoredPoints() throws {
        // A mask that covers the whole stroke (the eraser passed nearby, hit nothing).
        let covering = UIBezierPath(rect: CGRect(x: -500, y: -500, width: 2000, height: 2000))
        let dtos = PencilKitBridge.dtos(from: straightStroke(mask: covering))
        XCTAssertEqual(dtos.count, 1)
        XCTAssertEqual(try dtos[0].decodedPoints().count, 11)
    }

    /// The lasso moves a selection by setting a transform rather than rewriting the path,
    /// so the export has to bake it in or the stroke saves back at its old position.
    func testLassoMoveIsSavedAtTheNewPosition() throws {
        let moved = straightStroke(transform: CGAffineTransform(translationX: 30, y: 20))
        let dto = try XCTUnwrap(PencilKitBridge.dtos(from: moved).first)
        let points = try dto.decodedPoints()
        XCTAssertEqual(points.first?.x ?? 0, 30, accuracy: 0.03)
        XCTAssertEqual(points.last?.x ?? 0, 130, accuracy: 0.03)
        XCTAssertEqual(points.first?.y ?? 0, 120, accuracy: 0.03)
    }

    func testErasingAfterALassoMoveUsesDrawingCoordinates() throws {
        // Selection moved +200 in x, then erased past x=245.
        let moved = CGAffineTransform(translationX: 200, y: 0)
        let dtos = PencilKitBridge.dtos(
            from: straightStroke(transform: moved, mask: mask(keepingX: 190...245)))
        XCTAssertEqual(dtos.count, 1)
        let points = try dtos[0].decodedPoints()
        XCTAssertEqual(points.first?.x ?? 0, 200, accuracy: 0.03)
        XCTAssertEqual(points.last?.x ?? 0, 245, accuracy: 0.03)

        // The same mask in the stroke's pre-move coordinates erases nothing of it.
        let untouched = PencilKitBridge.dtos(
            from: straightStroke(transform: moved, mask: mask(keepingX: -10...45)))
        XCTAssertTrue(untouched.isEmpty)
    }

    func testDrawingExportAppliesErasureToEveryStroke() {
        let drawing = PKDrawing(strokes: [
            straightStroke(),
            straightStroke(mask: mask(keepingX: -10...45)),
            straightStroke(mask: UIBezierPath(rect: CGRect(x: 500, y: 500, width: 10, height: 10))),
        ])
        // Intact + trimmed + fully erased.
        XCTAssertEqual(PencilKitBridge.strokeDTOs(from: drawing).count, 2)
    }

    /// Every ink the tool picker can hand us must survive a save; an unmapped ink would
    /// silently drop the stroke.
    func testAllToolPickerInksExportAfterErasing() throws {
        let inkTypes: [PKInk.InkType] = [
            .pen, .pencil, .marker, .fountainPen, .watercolor, .crayon, .monoline,
        ]
        for inkType in inkTypes {
            let stroke = straightStroke(
                mask: mask(keepingX: -10...45), ink: PKInk(inkType, color: .red))
            let dtos = PencilKitBridge.dtos(from: stroke)
            XCTAssertEqual(dtos.count, 1, "\(inkType) should export one stroke")
            let dto = try XCTUnwrap(dtos.first)
            XCTAssertEqual(dto.color, UIColor.red.argb, "\(inkType) should keep its color")
            XCTAssertEqual(
                try dto.decodedPoints().last?.x ?? 0, 45, accuracy: 0.03,
                "\(inkType) should be trimmed by the eraser")
        }
    }

    @MainActor
    func testErasedPageRoundTripsThroughTheStore() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("bopa-test-\(UUID().uuidString)")
        let store = NotebookStore(rootURL: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let manifest = try store.createNotebook(title: "Erase")
        let pageId = try XCTUnwrap(manifest.pageIds.first)
        var page = try store.loadPage(notebookId: manifest.notebookId, pageId: pageId)

        // Two strokes drawn, then the eraser takes the tail off one and all of the other.
        let erasedAway = UIBezierPath(rect: CGRect(x: 500, y: 500, width: 10, height: 10))
        let drawing = PKDrawing(strokes: [
            straightStroke(mask: mask(keepingX: -10...45)),
            straightStroke(mask: erasedAway),
        ])
        page.strokes = PencilKitBridge.strokeDTOs(from: drawing)
        try store.savePage(page)

        let reloaded = try store.loadPage(notebookId: manifest.notebookId, pageId: pageId)
        XCTAssertEqual(reloaded.strokes.count, 1)
        let points = try reloaded.strokes[0].decodedPoints()
        XCTAssertEqual(points.last?.x ?? 0, 45, accuracy: 0.03)
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
