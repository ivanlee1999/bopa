import UIKit
import XCTest

@testable import Bopa

/// The release-time measurement that decides whether a drag was a page turn.
///
/// The numbers here are the 'Side to side' landscape-iPad case that made turning impossible: a
/// 1210pt viewport showing an A4 page fitted whole, ~610pt wide on screen, centred by
/// `CanvasContainerView` with ~300pt of contentInset slack on either side — so the page *rests*
/// at contentOffset.x = -300, not 0. Measured against zero, every release read as a 300pt pull
/// backwards: 'previous page' fired on its own (a guarded no-op on page 1, so nothing ever
/// happened), and a forward turn needed the slack plus the whole threshold of rubber-banding.
@MainActor
final class PageTurnOvershootTests: XCTestCase {
    private let viewport: CGFloat = 1210
    private let fittedPageWidth: CGFloat = 610
    private let slack: CGFloat = 300
    private let threshold = EditorCanvasView.Coordinator.pageTurnThreshold

    private func horizontalOvershoot(atOffset offset: CGFloat) -> CGFloat {
        EditorCanvasView.Coordinator.overshoot(
            offset: offset,
            contentLength: fittedPageWidth,
            boundsLength: viewport,
            leadingInset: slack,
            trailingInset: slack)
    }

    // MARK: A centred page at rest is not a gesture

    func testACentredPageAtRestIsNoOvershoot() {
        XCTAssertEqual(horizontalOvershoot(atOffset: -slack), 0)
    }

    func testSmallRubberBandingAroundTheRestStaysUnderTheThreshold() {
        XCTAssertLessThan(abs(horizontalOvershoot(atOffset: -slack + 40)), threshold)
        XCTAssertLessThan(abs(horizontalOvershoot(atOffset: -slack - 40)), threshold)
    }

    // MARK: Genuine pulls measured from the rest position

    /// Forward needs exactly the threshold of pull past the rest — not slack + threshold.
    func testAForwardPullPastTheThresholdTurnsForward() {
        let overshoot = horizontalOvershoot(atOffset: -slack + threshold)
        XCTAssertEqual(overshoot, threshold)
        XCTAssertGreaterThan(overshoot, 0, "positive overshoot means next page")
    }

    func testABackwardPullPastTheThresholdTurnsBack() {
        let overshoot = horizontalOvershoot(atOffset: -slack - threshold)
        XCTAssertEqual(overshoot, -threshold)
    }

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
