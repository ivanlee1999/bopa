import CoreGraphics
import NotableKit
import SnapshotTesting
import UIKit
import XCTest

@testable import Bopa

/// Pixel references for rendered markdown: the headings, the weights, the list indents and the
/// wrap. A subset renderer has no library to be right on its behalf, so this is what notices
/// when a heading stops being bold or a bullet's wrapped line stops hanging.
///
/// After an intentional visual change, re-record with `RECORD=1 ./scripts/test.sh app` and
/// eyeball the diff before committing.
final class TextBoxSnapshotTests: XCTestCase {

    // Tolerances absorb font-rasterization drift between the local simulator and CI's, without
    // letting a real rendering change through.
    private let strategy = Snapshotting<UIImage, UIImage>.image(
        precision: 0.99, perceptualPrecision: 0.97)

    private func render(_ source: String, width: CGFloat = 560) -> UIImage {
        let height = TextBoxLayout.measuredHeight(source: source, width: width)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 2
        format.opaque = true
        return UIGraphicsImageRenderer(
            size: CGSize(width: width, height: height), format: format
        ).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            TextBoxLayout.draw(
                source: source,
                in: CGRect(x: 0, y: 0, width: width, height: height),
                context: context.cgContext,
                scale: 1)
        }
    }

    func testEveryPartOfTheGrammar() {
        let source = """
        # Shopping
        ## Tomorrow
        ### Notes
        Plain body text that is long enough to wrap onto a second line so the wrap is covered.
        **Bold**, *italic*, and `code` all in one line.
        - milk
        - a bullet whose text is long enough to wrap, so the hanging indent is covered too
        3. third
        4. fourth
        See [the docs](https://example.com) for more.
        """
        assertSnapshot(of: render(source), as: strategy)
    }

    /// A blank line is the user asking for space, and a renderer that drops it closes a gap
    /// they typed on purpose.
    func testBlankLinesAreKept() {
        assertSnapshot(of: render("one\n\n\ntwo"), as: strategy)
    }

    /// Ink is drawn over text, so the box has to paint its letters and nothing else — no panel,
    /// no fill. A background here would rub out the strokes above it.
    func testABoxPaintsNoBackground() {
        let width = 300
        let height = 120
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        TextBoxLayout.draw(
            source: "words",
            in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)),
            context: context,
            scale: 1)

        // The bottom-right corner is well past the end of a five-letter word, so it is still the
        // paper it started as. Read through the context's own stride: the row padding is zero,
        // which in a grayscale buffer is black, and a flat read would call it ink.
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
        let corner = bytes[(height - 2) * context.bytesPerRow + (width - 2)]
        XCTAssertEqual(corner, 255, "a text box must not paint a background behind the ink")
    }
}
