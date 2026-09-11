import SwiftUI
import UIKit
import XCTest

@testable import Bopa

/// The same vectors live in Notable's CoverIdentityTest. Cover identity must survive
/// moving between devices, including ids with surrogate pairs and negative hashes.
@MainActor
final class CoverIdentityTests: XCTestCase {
    func testSpineIdentityMatchesNotable() {
        let vectors: [(String, Int)] = [
            ("", 0), ("notebook-1", 3), ("notebook-2", 0),
            ("00000000-0000-0000-0000-000000000001", 1),
            ("ffffffff-ffff-ffff-ffff-ffffffffffff", 0),
            ("日本語", 3), ("Notes 🖊️", 3), ("polygenelubricants", 0),
        ]
        let palette = [0xAE1800, 0x201E1D, 0xDD2B0F, 0x888888]
        for (id, index) in vectors {
            XCTAssertEqual(Modernist.stableIndex(id, count: 4), index, id)
            let rgb = palette[index]
            var (red, green, blue, alpha) = (CGFloat(0), CGFloat(0), CGFloat(0), CGFloat(0))
            XCTAssertTrue(UIColor(Modernist.fill(for: id)).getRed(
                &red, green: &green, blue: &blue, alpha: &alpha))
            XCTAssertEqual(red, CGFloat((rgb >> 16) & 255) / 255, accuracy: 0.001, id)
            XCTAssertEqual(green, CGFloat((rgb >> 8) & 255) / 255, accuracy: 0.001, id)
            XCTAssertEqual(blue, CGFloat(rgb & 255) / 255, accuracy: 0.001, id)
            XCTAssertEqual(alpha, 1, accuracy: 0.001, id)
        }
    }
}
