import Foundation
import SQLite3

// Convert a Notable on-device SQLite database into the WebDAV/local-store layout
// (notebooks/<id>/manifest.json + pages/<pageId>.json) used by the bopa iPad app.
// Usage: dbimport <app_database> <outputRoot>

guard CommandLine.arguments.count == 3 else {
    fatalError("usage: dbimport <app_database> <outputRoot>")
}
let dbPath = CommandLine.arguments[1]
let outRoot = URL(fileURLWithPath: CommandLine.arguments[2])

var db: OpaquePointer?
guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
    fatalError("cannot open \(dbPath)")
}
defer { sqlite3_close(db) }

func text(_ stmt: OpaquePointer?, _ i: Int32) -> String? {
    sqlite3_column_text(stmt, i).map { String(cString: $0) }
}
func iso(_ millis: Int64) -> String {
    NotableDate.format(Date(timeIntervalSince1970: Double(millis) / 1000))
}

let encoder = JSONEncoder()
encoder.outputFormatting = [.withoutEscapingSlashes]

// Strokes grouped by page
var strokesByPage: [String: [StrokeDTO]] = [:]
var stmt: OpaquePointer?
sqlite3_prepare_v2(db, "SELECT id,size,pen,color,maxPressure,top,bottom,left,right,points,pageId,createdAt,updatedAt FROM Stroke", -1, &stmt, nil)
var strokeCount = 0
while sqlite3_step(stmt) == SQLITE_ROW {
    let blobLen = Int(sqlite3_column_bytes(stmt, 9))
    guard let blobPtr = sqlite3_column_blob(stmt, 9) else { continue }
    var data = Data(bytes: blobPtr, count: blobLen)
    let maxPressure = Int(sqlite3_column_int(stmt, 4))

    // Normalize legacy raw pressure to [0,1] and re-encode, so files carry maxPressure=1
    // exactly like Notable's own sync serializer does.
    if maxPressure != 1, maxPressure > 0 {
        if var points = try? SBStrokeCodec.decode(data) {
            for i in points.indices {
                if let p = points[i].pressure {
                    points[i].pressure = min(max(p / Float(maxPressure), 0), 1)
                }
            }
            if let reencoded = try? SBStrokeCodec.encode(points) { data = reencoded }
        }
    }

    let pageId = text(stmt, 10)!
    let dto = StrokeDTO(
        id: text(stmt, 0)!,
        size: Float(sqlite3_column_double(stmt, 1)),
        pen: NotablePen.from(text(stmt, 2)),
        color: Int32(truncatingIfNeeded: sqlite3_column_int64(stmt, 3)),
        maxPressure: 1,
        top: Float(sqlite3_column_double(stmt, 5)),
        bottom: Float(sqlite3_column_double(stmt, 6)),
        left: Float(sqlite3_column_double(stmt, 7)),
        right: Float(sqlite3_column_double(stmt, 8)),
        pointsData: data.base64EncodedString(),
        createdAt: iso(sqlite3_column_int64(stmt, 11)),
        updatedAt: iso(sqlite3_column_int64(stmt, 12)))
    strokesByPage[pageId, default: []].append(dto)
    strokeCount += 1
}
sqlite3_finalize(stmt)

// Pages
struct PageRow {
    var file: PageFile
}
var pages: [String: PageFile] = [:]
sqlite3_prepare_v2(db, "SELECT id,scroll,notebookId,background,backgroundType,parentFolderId,createdAt,updatedAt FROM Page", -1, &stmt, nil)
while sqlite3_step(stmt) == SQLITE_ROW {
    let id = text(stmt, 0)!
    pages[id] = PageFile(
        id: id,
        notebookId: text(stmt, 2),
        background: text(stmt, 3) ?? "blank",
        backgroundType: text(stmt, 4) ?? "native",
        parentFolderId: text(stmt, 5),
        scroll: Int(sqlite3_column_int(stmt, 1)),
        createdAt: iso(sqlite3_column_int64(stmt, 6)),
        updatedAt: iso(sqlite3_column_int64(stmt, 7)),
        strokes: strokesByPage[id] ?? [])
}
sqlite3_finalize(stmt)

// Notebooks
var notebookCount = 0
var pageWrites = 0
sqlite3_prepare_v2(db, "SELECT id,title,openPageId,pageIds,parentFolderId,defaultBackground,defaultBackgroundType,linkedExternalUri,createdAt,updatedAt FROM Notebook", -1, &stmt, nil)
while sqlite3_step(stmt) == SQLITE_ROW {
    let id = text(stmt, 0)!
    let pageIds = (try? JSONDecoder().decode([String].self, from: Data((text(stmt, 3) ?? "[]").utf8))) ?? []
    let updatedAt = iso(sqlite3_column_int64(stmt, 9))
    let manifest = NotebookManifest(
        notebookId: id,
        title: text(stmt, 1) ?? "Untitled",
        pageIds: pageIds,
        openPageId: text(stmt, 2),
        parentFolderId: text(stmt, 4),
        defaultBackground: text(stmt, 5) ?? "blank",
        defaultBackgroundType: text(stmt, 6) ?? "native",
        linkedExternalUri: text(stmt, 7),
        createdAt: iso(sqlite3_column_int64(stmt, 8)),
        updatedAt: updatedAt,
        serverTimestamp: updatedAt)

    let dir = outRoot.appendingPathComponent("notebooks/\(id)/pages")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try! encoder.encode(manifest)
        .write(to: outRoot.appendingPathComponent("notebooks/\(id)/manifest.json"))
    for pageId in pageIds {
        guard let page = pages[pageId] else { continue }
        try! encoder.encode(page).write(to: dir.appendingPathComponent("\(pageId).json"))
        pageWrites += 1
    }
    notebookCount += 1
}
sqlite3_finalize(stmt)

print("imported \(notebookCount) notebooks, \(pageWrites) pages, \(strokeCount) strokes -> \(outRoot.path)")
