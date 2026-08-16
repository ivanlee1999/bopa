import CryptoKit
import Foundation

/// Cutting a page that grew past its sheet into one page per sheet.
///
/// A page has always been an endless vertical canvas: the declared sheet was only where export
/// divided it, so writing to the bottom and carrying on made the *same* page taller. Everything
/// below the first sheet was then invisible to anything that works in pages — the overview showed
/// one thumbnail, a bookmark could only point at the whole scroll, and reordering could not reach
/// it. This turns each of those sheets into a page of its own.
///
/// The rules are shared with the BOOX (`PageSplit.kt`) and pinned by the conformance vectors in
/// `docs/couch-sync-vectors/`. Three of them carry the weight:
///
/// - **The first sheet keeps the page's own id.** Bookmarks and outline entries name a page id, so
///   giving sheet 0 a new one would strand every entry that pointed at the page.
/// - **Later sheets get ids derived from the parent's**, so two devices that split the same page
///   while neither can see the other produce the *same* pages rather than two rival sets the merge
///   would then keep both of. This is the whole reason the id is a hash and not a UUID.
/// - **Ink is never cut.** A stroke belongs to the sheet its top edge falls in and travels whole,
///   so a descender crossing the boundary stays in one piece rather than being severed.
public enum PageSplit {

    /// The sheet a page is divided by: what it declares, else the notebook's default, else the
    /// geometry a page written before sheets existed is read with.
    ///
    /// The fallback has to be this constant and not "the screen", which is what the BOOX lays an
    /// undeclared page out at: a sheet the two apps disagree about would divide the page into a
    /// different number of pages on each of them, which is exactly the split the derived ids exist
    /// to prevent. Every page this produces declares its size, so the ambiguity is spent once.
    public static func sheet(for page: PageFile, notebookDefault: PageSize?) -> PageSize {
        if let width = page.pageWidth, let height = page.pageHeight, width > 0, height > 0 {
            return PageSize(width: width, height: height)
        }
        if let notebookDefault, notebookDefault.width > 0, notebookDefault.height > 0 {
            return notebookDefault
        }
        return .legacyUndeclared
    }

    /// The id of sheet [index] of [parentId] — `index` 0 is the parent itself.
    ///
    /// SHA-256 over an ASCII string, rendered in the shape of a UUID because that is what every
    /// other page id in the file looks like. Not a UUIDv5: no namespace, no version nibble, just
    /// the first 16 bytes of the digest — the only property required of it is that Kotlin and
    /// Swift compute the same one.
    public static func childId(parentId: String, sheet index: Int) -> String {
        if index == 0 { return parentId }
        let digest = SHA256.hash(data: Data("notable-page-split:\(parentId):\(index)".utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        let bytes = String(hex.prefix(32))
        func part(_ range: Range<Int>) -> String {
            let start = bytes.index(bytes.startIndex, offsetBy: range.lowerBound)
            let end = bytes.index(bytes.startIndex, offsetBy: range.upperBound)
            return String(bytes[start..<end])
        }
        return "\(part(0..<8))-\(part(8..<12))-\(part(12..<16))-\(part(16..<20))-\(part(20..<32))"
    }

    /// Which sheet a piece of content belongs to: the one its *top edge* falls in.
    ///
    /// The single rule the two apps have to agree on item by item. Everything else about the split
    /// is bookkeeping around it.
    public static func sheetIndex(ofTop top: Float, sheetHeight: Int) -> Int {
        guard sheetHeight > 0 else { return 0 }
        return Int((max(0, top) / Float(sheetHeight)).rounded(.down))
    }

    /// How many sheets content occupies, counted from where it *starts*, not from how far it
    /// reaches.
    ///
    /// Measuring the extent instead would make this non-idempotent: a stroke beginning just above
    /// the boundary and trailing past it keeps the page taller than one sheet, so every later run
    /// would find two sheets, assign nothing to the second, and file an empty page — once per open,
    /// for ever. Counting where content begins means a split page always reports one sheet.
    public static func sheetCount(tops: [Float], sheetHeight: Int) -> Int {
        (tops.map { sheetIndex(ofTop: $0, sheetHeight: sheetHeight) }.max() ?? 0) + 1
    }

    public static func sheetCount(of page: PageFile, sheet: PageSize) -> Int {
        sheetCount(
            tops: page.strokes.map(\.top) + page.images.map { Float($0.y) },
            sheetHeight: sheet.height)
    }

    /// Divides [page] into one page per sheet, in order, the first of which *is* [page].
    ///
    /// Returns a single page unchanged when there is nothing below the first sheet, so this is
    /// safe to run on every page of every notebook and cheap to run again.
    ///
    /// - Parameter now: the timestamp written to every page it produces. Taken as an argument so
    ///   the vectors can pin the output exactly.
    public static func split(
        _ page: PageFile, sheet: PageSize, now: String, updatedBy: String
    ) throws -> [PageFile] {
        let count = sheetCount(of: page, sheet: sheet)
        guard count > 1 else { return [declaring(sheet, on: page)] }

        let height = Float(sheet.height)
        var pages: [PageFile] = []
        for index in 0..<count {
            let offset = Float(index) * height
            let strokes = try page.strokes
                .filter { sheetIndex(ofTop: $0.top, sheetHeight: sheet.height) == index }
                .map { try shift($0, byY: -offset) }
            let images = page.images
                .filter { sheetIndex(ofTop: Float($0.y), sheetHeight: sheet.height) == index }
                .map { image -> ImageDTO in
                    var moved = image
                    moved.y -= Int(offset)
                    return moved
                }

            if index == 0 {
                var first = declaring(sheet, on: page)
                first.strokes = strokes
                first.images = images
                first.scroll = 0
                first.updatedAt = now
                first.updatedBy = updatedBy
                pages.append(first)
            } else {
                pages.append(
                    PageFile(
                        id: childId(parentId: page.id, sheet: index),
                        notebookId: page.notebookId,
                        // The paper follows the page it came out of — these are the same sheet of
                        // notes, and a background that changed halfway down would say otherwise.
                        background: page.background,
                        backgroundType: page.backgroundType,
                        parentFolderId: page.parentFolderId,
                        scroll: 0,
                        pageWidth: sheet.width,
                        pageHeight: sheet.height,
                        // Created when the ink was, not when the split ran: these pages are not new
                        // notes, and anything sorting by age should not float them to the top.
                        createdAt: page.createdAt,
                        updatedAt: now,
                        strokes: strokes,
                        images: images,
                        updatedBy: updatedBy))
            }
        }
        return pages
    }

    /// The page with its sheet written down, so the next reader does not have to guess it.
    private static func declaring(_ sheet: PageSize, on page: PageFile) -> PageFile {
        var declared = page
        declared.pageWidth = sheet.width
        declared.pageHeight = sheet.height
        return declared
    }

    /// Moves a stroke, points and bounds together.
    ///
    /// The points are the stroke — the bounds are a cached reading of them — so both have to move
    /// or the page overview and the eraser would look in the wrong place.
    private static func shift(_ stroke: StrokeDTO, byY delta: Float) throws -> StrokeDTO {
        var moved = stroke
        moved.top += delta
        moved.bottom += delta
        let points = try SBStrokeCodec.decode(Data(base64Encoded: stroke.pointsData) ?? Data())
        let shifted = points.map { point -> NotableStrokePoint in
            var moved = point
            moved.y += delta
            return moved
        }
        moved.pointsData = try SBStrokeCodec.encode(shifted).base64EncodedString()
        return moved
    }

    // MARK: - The same split, over the shared document

    /// Divides a [CouchPage] by the same rules, for the conformance vectors and for any caller
    /// working in the wire format rather than in files.
    ///
    /// Kept beside the file version and built from the same `sheetIndex`/`sheetCount` primitives
    /// rather than reimplemented: the rule that decides which sheet a stroke lands on exists once,
    /// so the two cannot drift apart within this app the way the two apps could between them.
    public static func split(
        _ page: CouchPage, id: String, sheet: PageSize, now: String, updatedBy: String
    ) throws -> [(id: String, page: CouchPage)] {
        let tops = page.strokes.map(\.top) + page.images.map { Float($0.y) }
        let count = sheetCount(tops: tops, sheetHeight: sheet.height)
        guard count > 1 else { return [(id, declaring(sheet, on: page))] }

        let height = Float(sheet.height)
        var pages: [(id: String, page: CouchPage)] = []
        for index in 0..<count {
            let offset = Float(index) * height
            var divided = declaring(sheet, on: page)
            divided.strokes = try page.strokes
                .filter { sheetIndex(ofTop: $0.top, sheetHeight: sheet.height) == index }
                .map { try shift($0, byY: -offset) }
            divided.images = page.images
                .filter { sheetIndex(ofTop: Float($0.y), sheetHeight: sheet.height) == index }
                .map { image in
                    var moved = image
                    moved.y -= Int(offset)
                    return moved
                }
            divided.updatedAt = now
            divided.updatedBy = updatedBy
            pages.append((childId(parentId: id, sheet: index), divided))
        }
        return pages
    }

    private static func declaring(_ sheet: PageSize, on page: CouchPage) -> CouchPage {
        var declared = page
        declared.pageWidth = sheet.width
        declared.pageHeight = sheet.height
        return declared
    }

    private static func shift(_ stroke: CouchStroke, byY delta: Float) throws -> CouchStroke {
        var moved = stroke
        moved.top += delta
        moved.bottom += delta
        let points = try SBStrokeCodec.decode(Data(base64Encoded: stroke.pointsData) ?? Data())
        moved.pointsData = try SBStrokeCodec.encode(
            points.map { point in
                var shifted = point
                shifted.y += delta
                return shifted
            }).base64EncodedString()
        return moved
    }
}
