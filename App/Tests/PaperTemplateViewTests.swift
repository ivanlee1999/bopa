import NotableKit
import UIKit
import XCTest

@testable import Bopa

/// Where an export would cut the page, drawn on the page.
///
/// The canvas is continuous and the export is not — it splits at fixed sheet-height intervals — so
/// without these the user writes straight across a break and finds a diagram cut in half.
///
/// Asserted by rendering rather than by any flag: what matters is that a mark appears on the page
/// at the break and nowhere else, and every internal state that could stand in for that has been
/// wrong at least once (a "blank" template, for instance, is a drawable one that draws nothing).
@MainActor
final class PaperTemplateViewTests: XCTestCase {

    private let sheet = PageSizePreset.a4.size
    /// Half scale, so the view's 1000pt covers 2000 page points — past the A4 sheet's 1872, which
    /// is the only way a break is on screen at all.
    private let zoom: CGFloat = 0.5

    private func makeView(
        template: NativeTemplate = .blank, declaresSheet: Bool = true, breaks: Bool = true
    ) -> PaperTemplateView {
        let view = PaperTemplateView(frame: CGRect(x: 0, y: 0, width: 800, height: 1000))
        view.template = template
        view.pageWidth = CGFloat(sheet.width)
        view.sheetHeight = declaresSheet ? CGFloat(sheet.height) : 0
        view.showsSheetBoundaries = breaks
        view.setGeometry(zoomScale: zoom, contentOffset: .zero)
        return view
    }

    func testPageBreaksAreOffByDefaultForPhysicalPages() {
        let view = PaperTemplateView(frame: CGRect(x: 0, y: 0, width: 800, height: 1000))
        view.pageWidth = CGFloat(sheet.width)
        view.sheetHeight = CGFloat(sheet.height)
        view.setGeometry(zoomScale: zoom, contentOffset: .zero)

        XCTAssertTrue(markedRows(view).isEmpty)
    }

    /// Rows of the rendered view carrying a mark, in view points.
    ///
    /// "A mark" is a pixel darker than the paper, not merely an opaque one: the template renderer
    /// fills the whole viewport white before it draws anything, so asking about coverage would
    /// answer yes for every pixel on the page.
    private func markedRows(_ view: PaperTemplateView) -> Set<Int> {
        let size = view.bounds.size
        // Unscaled, so a pixel row is a point row and the assertions can name one.
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = false
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { _ in view.draw(view.bounds) }
        guard let cgImage = image.cgImage else { return [] }

        let width = cgImage.width
        let height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return [] }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        let scale = CGFloat(height) / size.height
        var rows: Set<Int> = []
        for y in 0..<height {
            for x in 0..<width {
                let pixel = (y * width + x) * 4
                let opaque = pixels[pixel + 3] > 0
                let darkest = min(pixels[pixel], pixels[pixel + 1], pixels[pixel + 2])
                if opaque && darkest < 240 {
                    rows.insert(Int(CGFloat(y) / scale))
                    break
                }
            }
        }
        return rows
    }

    /// The break falls at one sheet height down, which at this zoom is halfway down the view.
    private var expectedBreakRow: Int { Int(CGFloat(sheet.height) * zoom) }

    /// A blank page is exactly the page most likely to be written straight across a break, so it
    /// is the one that most needs the mark.
    func testABlankPageDrawsItsBreak() {
        let rows = markedRows(makeView())

        XCTAssertFalse(rows.isEmpty, "nothing was marked at all")
        XCTAssertTrue(
            rows.contains { abs($0 - expectedBreakRow) <= 2 },
            "no mark near the sheet boundary at \(expectedBreakRow); marked rows: \(rows.sorted())")
    }

    /// A page that declares no sheet has no agreed break to promise, so it draws none.
    func testAnUndeclaredPageDrawsNoBreak() {
        XCTAssertTrue(markedRows(makeView(declaresSheet: false)).isEmpty)
    }

    func testTurningBreaksOffDrawsNone() {
        XCTAssertTrue(markedRows(makeView(breaks: false)).isEmpty)
    }

    /// The break is a mark on the paper, not a border round the view: it appears once, where the
    /// sheet ends, and the rest of the page is left alone.
    func testTheBreakIsTheOnlyThingDrawnOnABlankPage() {
        let rows = markedRows(makeView()).sorted()

        XCTAssertFalse(rows.isEmpty)
        for row in rows {
            XCTAssertLessThanOrEqual(
                abs(row - expectedBreakRow), 2, "unexpected mark at row \(row)")
        }
    }

    /// A drawable template keeps drawing its own paper alongside the break.
    func testALinedPageDrawsBothItsLinesAndItsBreak() {
        let rows = markedRows(makeView(template: .lined))

        XCTAssertGreaterThan(rows.count, 5, "the template's own lines are missing")
        XCTAssertTrue(rows.contains { abs($0 - expectedBreakRow) <= 2 })
    }
}
