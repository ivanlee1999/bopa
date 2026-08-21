import UIKit
import XCTest

@testable import Bopa

/// The release-time measurement that decides whether a vertical pull has reached another page.
@MainActor
final class PageTurnOvershootTests: XCTestCase {
    private let threshold = EditorCanvasView.Coordinator.pageTurnThreshold

    // MARK: The zero-inset axis behaves exactly as before

    /// A page taller than the viewport, no insets: rest anywhere inside 0...max is no overshoot,
    /// and pulls past either end measure from those ends.
    func testAScrollingAxisWithoutInsetsKeepsItsOldMeasurements() {
        func vertical(_ offset: CGFloat) -> CGFloat {
            EditorCanvasView.Coordinator.overshoot(
                offset: offset, contentLength: 2000, boundsLength: 800,
                leadingInset: 0, trailingInset: 0)
        }
        XCTAssertEqual(vertical(0), 0)
        XCTAssertEqual(vertical(600), 0, "an ordinary mid-scroll position")
        XCTAssertEqual(vertical(1200), 0, "resting exactly at the bottom")
        XCTAssertEqual(vertical(1200 + threshold), threshold)
        XCTAssertEqual(vertical(-threshold), -threshold)
    }

    /// Content shorter than the viewport with no insets used to clamp the rest range to a single
    /// point at zero; it still must.
    func testContentShorterThanTheViewportRestsAtZero() {
        func short(_ offset: CGFloat) -> CGFloat {
            EditorCanvasView.Coordinator.overshoot(
                offset: offset, contentLength: 500, boundsLength: 800,
                leadingInset: 0, trailingInset: 0)
        }
        XCTAssertEqual(short(0), 0)
        XCTAssertEqual(short(threshold), threshold)
        XCTAssertEqual(short(-threshold), -threshold)
    }

}
