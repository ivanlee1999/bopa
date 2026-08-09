import Foundation
import Testing
@testable import NotableKit

@Suite("Importing templates")
struct TemplateLibraryTests {
    @Test("A multi-page planner PDF imports as one single-page template per page")
    func importsPlannerPDF() throws {
        let workspace = try Fixtures.temporaryDirectory()
        let source = try Fixtures.writePDF(
            at: workspace.appending(path: "Weekly Planner (A4).pdf"),
            pageCount: 3
        )
        let library = TemplateLibrary(notableDirectory: workspace.appending(path: "notabledb"))

        let templates = try library.importTemplates(from: source)

        #expect(templates.count == 3)
        #expect(templates.map(\.name) == [
            "Weekly-Planner-A4 · page 1",
            "Weekly-Planner-A4 · page 2",
            "Weekly-Planner-A4 · page 3",
        ])
        #expect(templates.allSatisfy { $0.ref?.relativePath == "pdfs/Weekly-Planner-A4.pdf" })
        #expect(templates[1].background == .pdfPage(templates[1].ref!, index: 1))
        #expect(templates[0].pageSize == CGSize(width: 612, height: 792))
        #expect(library.store.exists(templates[0].ref!))
    }

    @Test("A single-page template keeps the plain file name")
    func importsSinglePagePDF() throws {
        let workspace = try Fixtures.temporaryDirectory()
        let source = try Fixtures.writePDF(at: workspace.appending(path: "daily.pdf"), pageCount: 1)
        let library = TemplateLibrary(notableDirectory: workspace.appending(path: "notabledb"))

        let templates = try library.importTemplates(from: source)

        #expect(templates.count == 1)
        #expect(templates[0].name == "daily")
    }

    @Test("Images import as one template, and can be made repeating")
    func importsImage() throws {
        let workspace = try Fixtures.temporaryDirectory()
        let source = try Fixtures.writePNG(at: workspace.appending(path: "ruled.png"))
        let library = TemplateLibrary(notableDirectory: workspace.appending(path: "notabledb"))

        let template = try #require(try library.importTemplates(from: source).first)

        #expect(template.ref?.relativePath == "images/ruled.png")
        #expect(template.background == .image(template.ref!))
        #expect(template.pageSize == CGSize(width: 100, height: 200))
        #expect(template.repeatingDownThePage().background == .repeatingImage(template.ref!))
    }

    @Test("Re-importing the same file reuses the stored asset")
    func deduplicatesIdenticalImports() throws {
        let workspace = try Fixtures.temporaryDirectory()
        let source = try Fixtures.writePDF(at: workspace.appending(path: "daily.pdf"), pageCount: 1)
        let library = TemplateLibrary(notableDirectory: workspace.appending(path: "notabledb"))

        let first = try library.importTemplates(from: source)
        let second = try library.importTemplates(from: source)

        #expect(first.map(\.id) == second.map(\.id))
        #expect(try library.store.storedRefs().count == 1)
    }

    @Test("Different files with the same name get distinct stored names")
    func avoidsNameCollisions() throws {
        let workspace = try Fixtures.temporaryDirectory()
        let a = try Fixtures.writePDF(at: workspace.appending(path: "a/daily.pdf"), pageCount: 1)
        let b = try Fixtures.writePDF(at: workspace.appending(path: "b/daily.pdf"), pageCount: 4)
        let library = TemplateLibrary(notableDirectory: workspace.appending(path: "notabledb"))

        let first = try library.importTemplates(from: a)
        let second = try library.importTemplates(from: b)

        #expect(first[0].ref?.fileName == "daily.pdf")
        #expect(second[0].ref?.fileName == "daily-2.pdf")
        #expect(try library.store.storedRefs().count == 2)
    }

    @Test("The library lists built-ins plus everything imported")
    func listsTemplates() throws {
        let workspace = try Fixtures.temporaryDirectory()
        let library = TemplateLibrary(notableDirectory: workspace.appending(path: "notabledb"))
        try library.store.prepare()
        _ = try library.importTemplates(
            from: try Fixtures.writePDF(at: workspace.appending(path: "planner.pdf"), pageCount: 2)
        )
        _ = try library.importTemplates(from: try Fixtures.writePNG(at: workspace.appending(path: "ruled.png")))

        let all = try library.allTemplates()

        #expect(all.prefix(5).map(\.name) == ["Blank", "Dot grid", "Lines", "Small squares", "Hexagons"])
        #expect(try library.importedTemplates().count == 3)
        #expect(all.count == 8)
    }

    @Test("Removing a template removes every page that shared its file")
    func removesAsset() throws {
        let workspace = try Fixtures.temporaryDirectory()
        let library = TemplateLibrary(notableDirectory: workspace.appending(path: "notabledb"))
        let templates = try library.importTemplates(
            from: try Fixtures.writePDF(at: workspace.appending(path: "planner.pdf"), pageCount: 3)
        )

        #expect(try library.templatesSharingAsset(with: templates[0]).count == 3)
        try library.remove(templates[0])

        #expect(try library.importedTemplates().isEmpty)
        #expect(library.store.exists(templates[0].ref!) == false)
    }

    @Test("Unsupported files are rejected, missing assets are reported")
    func errors() throws {
        let workspace = try Fixtures.temporaryDirectory()
        let library = TemplateLibrary(notableDirectory: workspace.appending(path: "notabledb"))
        let text = workspace.appending(path: "notes.txt")
        try "hello".write(to: text, atomically: true, encoding: .utf8)

        #expect(throws: TemplateError.unsupportedFileType("txt")) {
            try library.importTemplates(from: text)
        }

        let ghost = TemplateRef(folder: .pdfs, fileName: "gone.pdf")
        #expect(throws: TemplateError.missingAsset(ghost)) {
            try library.templates(for: ghost)
        }
    }

    @Test("File names are sanitized for the WebDAV namespace")
    func sanitizesNames() {
        #expect(TemplateStore.sanitizedFileName("Weekly Planner.pdf", defaultExtension: "pdf")
            == "Weekly-Planner.pdf")
        // Letters from any script are kept — the WebDAV client percent-encodes them — but
        // separators, spaces and punctuation are not.
        #expect(TemplateStore.sanitizedFileName("a//b/../週次 planner!!.PDF", defaultExtension: "pdf")
            == "週次-planner.pdf")
        #expect(TemplateStore.sanitizedFileName("....", defaultExtension: "png") == "template.png")
        #expect(TemplateStore.sanitizedFileName("scan", defaultExtension: "png") == "scan.png")
    }
}
