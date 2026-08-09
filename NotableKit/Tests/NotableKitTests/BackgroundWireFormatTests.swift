import Testing
@testable import NotableKit

@Suite("Background wire format")
struct BackgroundWireFormatTests {
    @Test("Native backgrounds round-trip")
    func nativeRoundTrip() {
        for template in NativeTemplate.builtIn {
            let fields = PageBackground.native(template).fields()
            #expect(fields.backgroundType == "native")
            #expect(fields.background == template.name)
            #expect(PageBackground(fields: fields) == .native(template))
        }
    }

    @Test("Asset backgrounds round-trip through relative paths")
    func assetRoundTrip() {
        let pdf = TemplateRef(folder: .pdfs, fileName: "weekly.pdf")
        let image = TemplateRef(folder: .images, fileName: "grid.png")
        let cover = TemplateRef(folder: .covers, fileName: "cover.png")

        let cases: [(PageBackground, String, String)] = [
            (.pdfPage(pdf, index: 0), "pdfs/weekly.pdf", "pdf0"),
            (.pdfPage(pdf, index: 12), "pdfs/weekly.pdf", "pdf12"),
            (.autoPDF(pdf), "pdfs/weekly.pdf", "autoPdf"),
            (.image(image), "images/grid.png", "image"),
            (.repeatingImage(image), "images/grid.png", "imagerepeating"),
            (.coverImage(cover), "covers/cover.png", "coverImage"),
        ]

        for (background, expectedPath, expectedType) in cases {
            let fields = background.fields()
            #expect(fields.background == expectedPath)
            #expect(fields.backgroundType == expectedType)
            #expect(PageBackground(fields: fields) == background)
        }
    }

    @Test("Absolute paths written by Notable's picker are understood")
    func absolutePathsFromNotable() {
        let background = PageBackground(
            background: "/storage/emulated/0/Documents/notabledb/backgrounds/pdfs/weekly.pdf",
            backgroundType: "pdf3"
        )
        #expect(background == .pdfPage(TemplateRef(folder: .pdfs, fileName: "weekly.pdf"), index: 3))
        // We normalize to the relative form Notable's downloader expects.
        #expect(background.fields().background == "pdfs/weekly.pdf")
    }

    @Test("Absolute style is available for device-local writes")
    func absoluteStyle() {
        let ref = TemplateRef(folder: .pdfs, fileName: "weekly.pdf")
        let fields = PageBackground.pdfPage(ref, index: 1)
            .fields(pathStyle: .absolute(root: "/storage/emulated/0/Documents/notabledb/backgrounds/"))
        #expect(fields.background == "/storage/emulated/0/Documents/notabledb/backgrounds/pdfs/weekly.pdf")
    }

    @Test("Bare basenames take their folder from the background type")
    func bareBasename() {
        #expect(
            PageBackground(background: "weekly.pdf", backgroundType: "pdf0")
                == .pdfPage(TemplateRef(folder: .pdfs, fileName: "weekly.pdf"), index: 0)
        )
        #expect(
            PageBackground(background: "grid.png", backgroundType: "image")
                == .image(TemplateRef(folder: .images, fileName: "grid.png"))
        )
    }

    @Test("Unknown and malformed values degrade to a native background")
    func fallbacks() {
        #expect(PageBackground(background: "blank", backgroundType: "somethingNew") == .native(.blank))
        #expect(PageBackground(background: "", backgroundType: "pdf2") == .native(.blank))
        #expect(PageBackground(background: "  ", backgroundType: "image") == .native(.blank))
        // pdf without a numeric suffix is not a PDF background
        #expect(PageBackground(background: "x.pdf", backgroundType: "pdfx") == .native(.custom("x.pdf")))
    }

    @Test("Unknown native names survive a round trip")
    func unknownNativeName() {
        let background = PageBackground(background: "isometric", backgroundType: "native")
        #expect(background == .native(.custom("isometric")))
        #expect(background.fields().background == "isometric")
        #expect(NativeTemplate.custom("isometric").isDrawable == false)
    }

    @Test("Template references parse from every observed path shape")
    func refParsing() {
        #expect(TemplateRef.parse("pdfs/a.pdf", impliedFolder: .images)?.folder == .pdfs)
        #expect(TemplateRef.parse("backgrounds/covers/a.png", impliedFolder: .images)?.folder == .covers)
        #expect(TemplateRef.parse("a.png", impliedFolder: .images)?.relativePath == "images/a.png")
        #expect(TemplateRef.parse("/var/mobile/x/backgrounds/pdfs/a.pdf", impliedFolder: .images)?
            .relativePath == "pdfs/a.pdf")
        // An absolute path with no `backgrounds/` component still yields a usable basename.
        #expect(TemplateRef.parse("/sdcard/Download/a.pdf", impliedFolder: .pdfs)?
            .relativePath == "pdfs/a.pdf")
        #expect(TemplateRef.parse("", impliedFolder: .pdfs) == nil)
    }
}
