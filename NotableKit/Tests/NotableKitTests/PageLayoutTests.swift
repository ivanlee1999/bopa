import Foundation
import Testing

@testable import NotableKit

/// The rules that decide whether a page ends at its sheet, and what height a page that does not
/// still writes down.
@Suite("Page layout")
struct PageLayoutTests {

    @Test("Absent and sheet are bounded")
    func boundedByDefault() {
        #expect(!PageLayout.isScroll(nil))
        #expect(!PageLayout.isScroll(""))
        #expect(!PageLayout.isScroll(PageLayout.sheet))
    }

    /// The asymmetry is the point: declining to divide a page is recoverable, dividing one that
    /// should not have been divided is not.
    @Test("An unrecognized layout is read as scrolling, not as a sheet")
    func unknownIsScroll() {
        #expect(PageLayout.isScroll(PageLayout.scroll))
        #expect(PageLayout.isScroll("infinite-2d"))
    }

    @Test("The materialized height covers the content plus a screenful, in whole sheets")
    func materializedHeight() {
        // Empty page: one sheet, even though slack alone would fit in less.
        #expect(PageLayout.materializedHeight(contentBottom: 0, sheetHeight: 2000) == 2000)
        // 900 + 1000 slack = 1900, still inside the first sheet.
        #expect(PageLayout.materializedHeight(contentBottom: 900, sheetHeight: 2000) == 2000)
        // 1100 + 1000 = 2100, so two.
        #expect(PageLayout.materializedHeight(contentBottom: 1100, sheetHeight: 2000) == 4000)
        #expect(PageLayout.materializedHeight(contentBottom: 5000, sheetHeight: 2000) == 6000)
    }

    /// Why it rounds: a value that moved with every stroke would push the document on every
    /// save, and two devices that padded differently would overwrite each other's height for ever.
    @Test("Writing more ink inside one sheet does not change the declared height")
    func heightIsStableWithinASheet() {
        let a = PageLayout.materializedHeight(contentBottom: 2100, sheetHeight: 2000)
        let b = PageLayout.materializedHeight(contentBottom: 2400, sheetHeight: 2000)
        #expect(a == b)
    }

    @Test("A page with no usable sheet declares nothing rather than dividing by zero")
    func guardsZeroSheet() {
        #expect(PageLayout.materializedHeight(contentBottom: 500, sheetHeight: 0) == 0)
    }

    @Test("The declaration reaches both the document and the file")
    func readsOffBothModels() {
        let document = CouchPage(
            notebookId: "nb1", pageWidth: 1400, pageHeight: 4000, layout: PageLayout.scroll,
            createdAt: "2026-09-19T09:00:00Z", updatedAt: "2026-09-19T09:00:00Z",
            updatedBy: "ipad")
        #expect(document.isScroll)

        let file = PageFile(
            id: "p1", notebookId: "nb1", pageWidth: 1400, pageHeight: 4000,
            layout: PageLayout.scroll,
            createdAt: "2026-09-19T09:00:00Z", updatedAt: "2026-09-19T09:00:00Z")
        #expect(file.isScroll)

        var sheet = file
        sheet.layout = nil
        #expect(!sheet.isScroll)
    }
}
