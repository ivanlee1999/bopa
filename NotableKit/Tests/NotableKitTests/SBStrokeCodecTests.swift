import XCTest
@testable import NotableKit

final class SBStrokeCodecTests: XCTestCase {

    private func makePoints(
        _ count: Int,
        pressure: Bool = true,
        tilt: Bool = true,
        dt: Bool = true
    ) -> [NotableStrokePoint] {
        (0..<count).map { i in
            NotableStrokePoint(
                x: 100 + Float(i) * 1.37,
                y: 200 + Float(i) * 0.83,
                pressure: pressure ? Float(i % 100) / 100.0 : nil,
                tiltX: tilt ? (i % 90) - 45 : nil,
                tiltY: tilt ? -((i % 90) - 45) : nil,
                dt: dt ? UInt16(min(i * 7, 65534)) : nil
            )
        }
    }

    private func assertPointsEqual(
        _ a: [NotableStrokePoint], _ b: [NotableStrokePoint],
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(a.count, b.count, file: file, line: line)
        for (p, q) in zip(a, b) {
            XCTAssertEqual(p.x, q.x, accuracy: 0.0105, file: file, line: line)
            XCTAssertEqual(p.y, q.y, accuracy: 0.0105, file: file, line: line)
            if let pp = p.pressure, let qp = q.pressure {
                // v2 pressure is uint16 fixed-point: worst case error 1/65535/2
                XCTAssertEqual(pp, qp, accuracy: 1.0 / 65535, file: file, line: line)
            } else {
                XCTAssertEqual(p.pressure == nil, q.pressure == nil, file: file, line: line)
            }
            XCTAssertEqual(p.tiltX, q.tiltX, file: file, line: line)
            XCTAssertEqual(p.tiltY, q.tiltY, file: file, line: line)
            XCTAssertEqual(p.dt, q.dt, file: file, line: line)
        }
    }

    func testHeaderLayout() throws {
        let points = makePoints(3)
        let data = try SBStrokeCodec.encode(points)
        XCTAssertEqual(data[0], 0x53) // 'S'
        XCTAssertEqual(data[1], 0x42) // 'B'
        XCTAssertEqual(data[2], 2)    // version
        XCTAssertEqual(data[3], 0b1111) // all channels
        // count int32 LE
        XCTAssertEqual(data[4], 3)
        XCTAssertEqual(data[5], 0)
        XCTAssertEqual(data[6], 0)
        XCTAssertEqual(data[7], 0)
        XCTAssertEqual(data[8], 0)    // small stroke: no compression
    }

    func testRoundTripAllChannels() throws {
        let points = makePoints(50)
        let decoded = try SBStrokeCodec.decode(try SBStrokeCodec.encode(points))
        assertPointsEqual(points, decoded)
    }

    func testRoundTripCoordinatesOnly() throws {
        let points = makePoints(20, pressure: false, tilt: false, dt: false)
        let data = try SBStrokeCodec.encode(points)
        XCTAssertEqual(data[3], 0)
        let decoded = try SBStrokeCodec.decode(data)
        assertPointsEqual(points, decoded)
    }

    func testRoundTripPressureOnly() throws {
        let points = makePoints(20, pressure: true, tilt: false, dt: false)
        let data = try SBStrokeCodec.encode(points)
        XCTAssertEqual(data[3], 1)
        assertPointsEqual(points, try SBStrokeCodec.decode(data))
    }

    func testRoundTripLargeStrokeUsesLZ4() throws {
        // Enough points that the raw body exceeds 512 bytes and compresses well
        // (dt increments are constant, tilts repeat -> compressible).
        let points = makePoints(1500)
        let data = try SBStrokeCodec.encode(points)
        XCTAssertEqual(data[8], 1, "expected LZ4 compression flag for large regular stroke")
        assertPointsEqual(points, try SBStrokeCodec.decode(data))
    }

    func testEmptyPointsThrows() {
        XCTAssertThrowsError(try SBStrokeCodec.encode([])) {
            XCTAssertEqual($0 as? SBCodecError, .emptyPointList)
        }
    }

    func testNonUniformChannelThrows() {
        var points = makePoints(5)
        points[3].pressure = nil
        XCTAssertThrowsError(try SBStrokeCodec.encode(points)) {
            XCTAssertEqual($0 as? SBCodecError, .nonUniformChannel("pressure"))
        }
    }

    func testPageTooLargeThrows() {
        let points = [NotableStrokePoint(x: 0, y: 10_000_001)]
        XCTAssertThrowsError(try SBStrokeCodec.encode(points))
    }

    func testBadMagicThrows() {
        var data = Data(repeating: 0, count: 32)
        data[0] = 0x41
        XCTAssertThrowsError(try SBStrokeCodec.decode(data)) {
            XCTAssertEqual($0 as? SBCodecError, .badMagic)
        }
    }

    func testUnsupportedVersionThrows() throws {
        var data = try SBStrokeCodec.encode(makePoints(3))
        data[2] = 3
        XCTAssertThrowsError(try SBStrokeCodec.decode(data)) {
            XCTAssertEqual($0 as? SBCodecError, .unsupportedVersion(3))
        }
    }

    func testTrailingBytesThrows() throws {
        var data = try SBStrokeCodec.encode(makePoints(3))
        XCTAssertEqual(data[8], 0, "test assumes uncompressed")
        data.append(0xAB)
        XCTAssertThrowsError(try SBStrokeCodec.decode(data)) {
            XCTAssertEqual($0 as? SBCodecError, .trailingBytes)
        }
    }

    func testPressureClampedOnEncode() throws {
        let points = [
            NotableStrokePoint(x: 0, y: 0, pressure: 1.7),
            NotableStrokePoint(x: 1, y: 1, pressure: -0.2),
        ]
        let decoded = try SBStrokeCodec.decode(try SBStrokeCodec.encode(points))
        XCTAssertEqual(decoded[0].pressure!, 1.0, accuracy: 1.0 / 65535)
        XCTAssertEqual(decoded[1].pressure!, 0.0, accuracy: 1.0 / 65535)
    }

    func testDtClampedToMax() throws {
        let points = [
            NotableStrokePoint(x: 0, y: 0, dt: 0),
            NotableStrokePoint(x: 1, y: 1, dt: 65535), // sentinel value, clamped on write
        ]
        let decoded = try SBStrokeCodec.decode(try SBStrokeCodec.encode(points))
        XCTAssertEqual(decoded[1].dt, 65534)
    }

    func testLZ4BlockRoundTrip() throws {
        let raw = Data((0..<4096).map { UInt8($0 % 7) })
        let compressed = try XCTUnwrap(SBStrokeCodec.lz4CompressBlock(raw))
        XCTAssertLessThan(compressed.count, raw.count)
        let restored = try SBStrokeCodec.lz4DecompressBlock(compressed, rawSize: raw.count)
        XCTAssertEqual(restored, raw)
    }
}
