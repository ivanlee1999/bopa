import XCTest
@testable import NotableKit

final class PolylineTests: XCTestCase {

    /// Hand-computed against the Kotlin algorithm:
    /// 1.0 @ p2 -> 100 -> zigzag 200 -> chunks [40, 6] -> chars 'g','E'
    func testKnownVectorPositive() {
        XCTAssertEqual(Polyline.encode([1.0], precision: 2), "gE")
        XCTAssertEqual(Polyline.decode("gE", precision: 2), [1.0])
    }

    /// -1.0 @ p2 -> -100 -> zigzag 199 -> chunks [39, 6] -> chars 'f','E'
    func testKnownVectorNegative() {
        XCTAssertEqual(Polyline.encode([-1.0], precision: 2), "fE")
        XCTAssertEqual(Polyline.decode("fE", precision: 2), [-1.0])
    }

    /// 0 encodes as zigzag 0 -> single chunk 0 -> '?' (63)
    func testZero() {
        XCTAssertEqual(Polyline.encode([0], precision: 2), "?")
        XCTAssertEqual(Polyline.decode("?", precision: 2), [0])
    }

    func testRoundTripSequence() {
        let values: [Float] = [0, 0.25, 10.5, 10.49, -3.75, 1859.99, 2480.01, 0.01, -0.01]
        let decoded = Polyline.decode(Polyline.encode(values, precision: 2), precision: 2)
        XCTAssertEqual(decoded.count, values.count)
        for (a, b) in zip(values, decoded) {
            // precision 2 => resolution 0.01; truncation on encode allows up to 0.01 error
            XCTAssertEqual(a, b, accuracy: 0.0105, "\(a) vs \(b)")
        }
    }

    func testRoundTripLargeValues() {
        // Page y-coordinates can be large (infinite scroll); max page height is 1e7.
        let values: [Float] = [9_999_999, 9_999_999.5, 0]
        let decoded = Polyline.decode(Polyline.encode(values, precision: 2), precision: 2)
        for (a, b) in zip(values, decoded) {
            XCTAssertEqual(a, b, accuracy: 1.0) // Float precision itself is ~1 at 1e7
        }
    }

    func testRoundTripRandomWalk() {
        var values: [Float] = []
        var x: Float = 500
        var seed: UInt64 = 0x2545F4914F6CDD1D
        for _ in 0..<2000 {
            seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
            x += Float(Int64(bitPattern: seed) % 100) / 50.0
            values.append(x)
        }
        let decoded = Polyline.decode(Polyline.encode(values, precision: 2), precision: 2)
        XCTAssertEqual(decoded.count, values.count)
        for (a, b) in zip(values, decoded) {
            XCTAssertEqual(a, b, accuracy: 0.0105)
        }
    }
}
