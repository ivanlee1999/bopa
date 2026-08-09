import Foundation
import Testing
@testable import NotableKit

@Suite("Applying templates")
struct TemplateApplicationTests {
    let planner = Template(
        source: .pdf(TemplateRef(folder: .pdfs, fileName: "weekly.pdf"), pageIndex: 2),
        name: "Weekly · page 3"
    )

    @Test("A template becomes a page's background fields")
    func pageFields() {
        let fields = TemplateApplication.pageFields(for: planner)
        #expect(fields.background == "pdfs/weekly.pdf")
        #expect(fields.backgroundType == "pdf2")
    }

    @Test("A notebook plan carries defaults, per-page fields and the asset to upload")
    func notebookPlan() {
        let plan = TemplateApplication.plan(pageCount: 4, from: planner)

        #expect(plan.pages.count == 4)
        #expect(Set(plan.pages).count == 1)
        #expect(plan.notebookDefaults == plan.pages[0])
        #expect(plan.assets == [TemplateRef(folder: .pdfs, fileName: "weekly.pdf")])
    }

    @Test("Native templates need no asset upload")
    func nativePlan() {
        let plan = TemplateApplication.plan(pageCount: 2, from: .native(.dotted))
        #expect(plan.notebookDefaults == BackgroundFields(background: "dotted", backgroundType: "native"))
        #expect(plan.assets.isEmpty)
    }

    @Test("Mixed-template notebooks deduplicate shared assets")
    func mixedPlan() {
        let cover = Template(
            source: .image(TemplateRef(folder: .images, fileName: "cover.png"), repeating: false),
            name: "Cover"
        )
        let plan = TemplateApplication.plan(pages: [cover, planner, planner], notebookDefault: planner)

        #expect(plan.pages.count == 3)
        #expect(plan.notebookDefaults.backgroundType == "pdf2")
        #expect(plan.assets == [
            TemplateRef(folder: .images, fileName: "cover.png"),
            TemplateRef(folder: .pdfs, fileName: "weekly.pdf"),
        ])
    }

    @Test("An existing page's template can be recovered for a picker")
    func recoverTemplate() {
        let recovered = TemplateApplication.template(from: TemplateApplication.pageFields(for: planner))
        #expect(recovered?.source == planner.source)
        #expect(TemplateApplication.template(from: BackgroundFields(background: "lined", backgroundType: "native"))
            == .native(.lined))
        // A whole-notebook PDF mode isn't a single-page template.
        #expect(TemplateApplication.template(
            from: BackgroundFields(background: "pdfs/weekly.pdf", backgroundType: "autoPdf")
        ) == nil)
    }

    @Test("Assets land under the notebook's backgrounds collection, flat")
    func remotePaths() {
        let ref = TemplateRef(folder: .pdfs, fileName: "weekly.pdf")
        #expect(TemplateSync.remotePath(notebookId: "NB1", ref: ref)
            == "/notable/notebooks/NB1/backgrounds/weekly.pdf")
    }

    @Test("The upload set is the deduplicated set of referenced assets")
    func uploadSet() {
        let plan = TemplateApplication.plan(pageCount: 3, from: planner)
        #expect(TemplateSync.assets(in: plan.pages) == plan.assets)

        let mixed = [
            BackgroundFields(background: "blank", backgroundType: "native"),
            BackgroundFields(background: "pdfs/weekly.pdf", backgroundType: "pdf0"),
            BackgroundFields(background: "pdfs/weekly.pdf", backgroundType: "pdf1"),
            BackgroundFields(background: "images/ruled.png", backgroundType: "imagerepeating"),
        ]
        #expect(TemplateSync.assets(in: mixed) == [
            TemplateRef(folder: .pdfs, fileName: "weekly.pdf"),
            TemplateRef(folder: .images, fileName: "ruled.png"),
        ])
    }

    @Test("Assets absent from the store are the download set")
    func downloadSet() throws {
        let workspace = try Fixtures.temporaryDirectory()
        let store = TemplateStore(notableDirectory: workspace)
        let present = try store.install(
            contentsOf: try Fixtures.writePDF(at: workspace.appending(path: "have.pdf"), pageCount: 1)
        )
        let absent = TemplateRef(folder: .pdfs, fileName: "missing.pdf")

        #expect(TemplateSync.missingLocally([present, absent], store: store) == [absent])
    }

    @Test("Downloaded assets keep the server's name")
    func installDownloaded() throws {
        let workspace = try Fixtures.temporaryDirectory()
        let store = TemplateStore(notableDirectory: workspace)
        let data = try Data(
            contentsOf: try Fixtures.writePDF(at: workspace.appending(path: "src.pdf"), pageCount: 1)
        )

        let ref = try store.installDownloaded(data: data, fileName: "weekly.pdf", into: .pdfs)

        #expect(ref.relativePath == "pdfs/weekly.pdf")
        #expect(store.exists(ref))
        #expect(TemplateSync.folder(forRemoteName: "weekly.pdf") == .pdfs)
        #expect(TemplateSync.folder(forRemoteName: "ruled.png") == .images)
    }
}
