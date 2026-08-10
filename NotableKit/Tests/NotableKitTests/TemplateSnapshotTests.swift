import CoreGraphics
import Foundation
import SnapshotTesting
import Testing

@testable import NotableKit

#if canImport(AppKit)
    import AppKit

    /// Pixel-level references for the native templates — the backgrounds that must look the same
    /// here as they do in Notable on the BOOX. The geometry tests alongside check alignment; these
    /// catch everything else (weight, spacing, colour) without a simulator.
    ///
    /// After an intentional visual change, re-record with
    /// `RECORD=1 ./scripts/test.sh kit` and eyeball the diff before committing.
    @Suite("Native template snapshots")
    struct TemplateSnapshotTests {
        private func render(_ template: NativeTemplate) throws -> NSImage {
            let workspace = try Fixtures.temporaryDirectory()
            let renderer = TemplateRenderer(store: TemplateStore(notableDirectory: workspace))
            // An off-origin viewport so the snapshot also pins scroll-offset alignment.
            let image = try renderer.image(
                for: .native(template),
                pageWidth: 300,
                viewport: CGRect(x: 0, y: 40, width: 300, height: 400),
                scale: 2
            )
            return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        }

        @Test("Each drawable grid matches its reference image")
        func drawableGrids() throws {
            for template in [NativeTemplate.dotted, .lined, .squared, .hexed] {
                assertSnapshot(
                    of: try render(template),
                    // Perceptual tolerance absorbs antialiasing drift between macOS versions
                    // (local vs CI runner) without letting a real change through.
                    as: .image(precision: 0.995, perceptualPrecision: 0.98),
                    named: template.name
                )
            }
        }
    }
#endif
