import CoreGraphics
import Foundation
import Testing
@testable import NotableKit

@Suite("Rendering templates")
struct TemplateRendererTests {
    private func makeRenderer() throws -> (TemplateRenderer, URL) {
        let workspace = try Fixtures.temporaryDirectory()
        return (TemplateRenderer(store: TemplateStore(notableDirectory: workspace)), workspace)
    }

    @Test("Blank draws nothing, the grids draw something")
    func nativeGrids() throws {
        let (renderer, _) = try makeRenderer()
        let size = CGSize(width: 300, height: 550)

        let blank = try renderer.thumbnail(for: .native(.blank), size: size, scale: 1)
        #expect(blank.width == 300 && blank.height == 550)
        #expect(try Fixtures.containsNonWhitePixel(blank) == false)

        for template in [NativeTemplate.dotted, .lined, .squared, .hexed] {
            let image = try renderer.thumbnail(for: .native(template), size: size, scale: 1)
            #expect(try Fixtures.containsNonWhitePixel(image), "\(template.name) drew nothing")
        }
    }

    @Test("Grid lines sit on multiples of the grid spacing, wherever you scroll to")
    func gridAlignment() throws {
        let (renderer, _) = try makeRenderer()
        // A 1px-wide slice down the page, starting at a scroll offset that is not a multiple of 80.
        let viewport = CGRect(x: 0, y: 130, width: 1, height: 160)
        let image = try renderer.image(for: .native(.lined), pageWidth: 300, viewport: viewport, scale: 1)
        let bytes = try Fixtures.pixels(of: image)

        let inkedRows = (0..<image.height).filter { row in
            bytes[row * image.width * 4] < 250
        }
        // Lines at page y = 160 and 240 → rows 30 and 110 of this viewport (a 1-unit stroke
        // centred on the line antialiases across the two rows it straddles).
        #expect(inkedRows == [29, 30, 109, 110])
    }

    @Test("A PDF template is fitted to page width and anchored at the top")
    func pdfTemplate() throws {
        let (renderer, workspace) = try makeRenderer()
        let library = TemplateLibrary(store: renderer.store)
        let templates = try library.importTemplates(
            from: try Fixtures.writePDF(
                at: workspace.appending(path: "planner.pdf"),
                pageCount: 2,
                size: CGSize(width: 100, height: 200)
            )
        )

        // Page width 300 → 3x scale → the 200pt-tall page occupies 600 page units.
        #expect(try renderer.drawnHeight(for: templates[0], pageWidth: 300) == 600)

        // The fixture fills a bar at the *bottom* of the PDF page (PDF y is up), so in page
        // coordinates it lands at the bottom of the drawn area.
        let image = try renderer.image(
            for: templates[0],
            pageWidth: 300,
            viewport: CGRect(x: 0, y: 0, width: 300, height: 700),
            scale: 0.5
        )
        let bytes = try Fixtures.pixels(of: image)
        func isInk(x: Int, y: Int) -> Bool { bytes[(y * image.width + x) * 4] < 128 }

        #expect(isInk(x: 10, y: 10) == false)     // top of the page: white
        #expect(isInk(x: 10, y: 293))             // just above 600 page units (×0.5 scale): the bar
        #expect(isInk(x: 10, y: 310) == false)    // past the end of the PDF page: white again
    }

    @Test("Later PDF pages render differently from earlier ones")
    func pdfPageSelection() throws {
        let (renderer, workspace) = try makeRenderer()
        let library = TemplateLibrary(store: renderer.store)
        let templates = try library.importTemplates(
            from: try Fixtures.writePDF(
                at: workspace.appending(path: "planner.pdf"),
                pageCount: 3,
                size: CGSize(width: 100, height: 100)
            )
        )
        let viewport = CGRect(x: 0, y: 0, width: 100, height: 100)

        let renders = try templates.map { template in
            try Fixtures.pixels(of: renderer.image(
                for: template, pageWidth: 100, viewport: viewport, scale: 1
            ))
        }
        #expect(renders[0] != renders[1])
        #expect(renders[1] != renders[2])
    }

    @Test("A page with /Rotate is drawn the way a PDF viewer shows it")
    func rotatedPDFPage() throws {
        let (renderer, workspace) = try makeRenderer()
        let library = TemplateLibrary(store: renderer.store)
        let template = try #require(try library.importTemplates(
            from: try Fixtures.writeRotatedPDF(at: workspace.appending(path: "landscape.pdf"), rotation: 90)
        ).first)

        // A 100×200 page rotated a quarter turn presents as 200×100.
        #expect(template.pageSize == CGSize(width: 200, height: 100))
        #expect(try renderer.drawnHeight(for: template, pageWidth: 200) == 100)

        // Rotating clockwise carries the bar from the bottom edge to the left edge.
        let image = try renderer.image(
            for: template,
            pageWidth: 200,
            viewport: CGRect(x: 0, y: 0, width: 200, height: 100),
            scale: 1
        )
        let bytes = try Fixtures.pixels(of: image)
        func isInk(x: Int, y: Int) -> Bool { bytes[(y * image.width + x) * 4] < 128 }

        #expect(isInk(x: 5, y: 20))
        #expect(isInk(x: 5, y: 80))
        #expect(isInk(x: 100, y: 50) == false)
    }

    @Test("A repeating image tiles down the page; a plain one is drawn once")
    func repeatingImage() throws {
        let (renderer, workspace) = try makeRenderer()
        let library = TemplateLibrary(store: renderer.store)
        let template = try #require(try library.importTemplates(
            from: try Fixtures.writePNG(
                at: workspace.appending(path: "band.png"),
                size: CGSize(width: 100, height: 50),
                gray: 0.2
            )
        ).first)

        let viewport = CGRect(x: 0, y: 0, width: 100, height: 200)
        let once = try renderer.image(for: template, pageWidth: 100, viewport: viewport, scale: 1)
        let tiled = try renderer.image(
            for: template.repeatingDownThePage(), pageWidth: 100, viewport: viewport, scale: 1
        )

        let onceBytes = try Fixtures.pixels(of: once)
        let tiledBytes = try Fixtures.pixels(of: tiled)
        func isInk(_ bytes: [UInt8], y: Int) -> Bool { bytes[(y * 100 + 10) * 4] < 128 }

        #expect(isInk(onceBytes, y: 10))
        #expect(isInk(onceBytes, y: 120) == false)
        #expect(isInk(tiledBytes, y: 10))
        #expect(isInk(tiledBytes, y: 120))
    }

    @Test("Rendering a template whose asset is gone reports the missing asset")
    func missingAsset() throws {
        let (renderer, _) = try makeRenderer()
        let ref = TemplateRef(folder: .pdfs, fileName: "gone.pdf")
        let template = Template(source: .pdf(ref, pageIndex: 0), name: "gone")

        #expect(throws: TemplateError.missingAsset(ref)) {
            try renderer.thumbnail(for: template, size: CGSize(width: 100, height: 100))
        }
    }
}
