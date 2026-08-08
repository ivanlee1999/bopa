import Foundation
import SQLite3

// Export bopa's local store (notebooks/<id>/manifest.json + pages/*.json) INTO a Notable
// on-device SQLite database (a copy of Documents/notabledb/app_database), so edits made on
// the iPad can be carried back to the BOOX without WebDAV.
//
// Usage: dbexport <app_database> <storeRoot> [notebookId ...]
//   With no notebook ids, every notebook in the store is exported.
//   The database is modified in place and WAL-checkpointed so the single file is complete.

let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

guard CommandLine.arguments.count >= 3 else {
    fatalError("usage: dbexport <app_database> <storeRoot> [notebookId ...]")
}
let dbPath = CommandLine.arguments[1]
let storeRoot = URL(fileURLWithPath: CommandLine.arguments[2])
let onlyIds = Set(CommandLine.arguments.dropFirst(3))

var db: OpaquePointer?
guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
    fatalError("cannot open \(dbPath)")
}
defer { sqlite3_close(db) }

func exec(_ sql: String) {
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
        fatalError("SQL failed: \(sql) — \(String(cString: sqlite3_errmsg(db)))")
    }
}

func millis(_ iso: String) -> Int64 {
    NotableDate.parse(iso).map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) }
        ?? Int64(Date().timeIntervalSince1970 * 1000)
}

struct Statement {
    let handle: OpaquePointer

    init(_ sql: String) {
        var h: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &h, nil) == SQLITE_OK, let h else {
            fatalError("prepare failed: \(sql) — \(String(cString: sqlite3_errmsg(db)))")
        }
        handle = h
    }

    func bind(_ index: Int32, _ value: String?) {
        if let value { sqlite3_bind_text(handle, index, value, -1, SQLITE_TRANSIENT) }
        else { sqlite3_bind_null(handle, index) }
    }
    func bind(_ index: Int32, _ value: Int64) { sqlite3_bind_int64(handle, index, value) }
    func bind(_ index: Int32, _ value: Double) { sqlite3_bind_double(handle, index, value) }
    func bind(_ index: Int32, _ value: Data) {
        value.withUnsafeBytes {
            _ = sqlite3_bind_blob(handle, index, $0.baseAddress, Int32(value.count), SQLITE_TRANSIENT)
        }
    }

    func run() {
        guard sqlite3_step(handle) == SQLITE_DONE else {
            fatalError("step failed: \(String(cString: sqlite3_errmsg(db)))")
        }
        sqlite3_reset(handle)
        sqlite3_clear_bindings(handle)
    }
}

let decoder = JSONDecoder()
let notebooksDir = storeRoot.appendingPathComponent("notebooks")
let ids = ((try? FileManager.default.contentsOfDirectory(atPath: notebooksDir.path)) ?? [])
    .filter { onlyIds.isEmpty || onlyIds.contains($0) }

exec("PRAGMA foreign_keys=OFF")
exec("BEGIN")

let upsertNotebook = Statement("""
INSERT OR REPLACE INTO Notebook
(id,title,openPageId,pageIds,parentFolderId,defaultBackground,defaultBackgroundType,linkedExternalUri,createdAt,updatedAt)
VALUES (?,?,?,?,?,?,?,?,?,?)
""")
let upsertPage = Statement("""
INSERT OR REPLACE INTO Page
(id,scroll,notebookId,background,backgroundType,parentFolderId,createdAt,updatedAt)
VALUES (?,?,?,?,?,?,?,?)
""")
let deleteStrokes = Statement("DELETE FROM Stroke WHERE pageId = ?")
let insertStroke = Statement("""
INSERT OR REPLACE INTO Stroke
(id,size,pen,color,maxPressure,top,bottom,left,right,points,pageId,createdAt,updatedAt)
VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
""")

var notebookCount = 0
var pageCount = 0
var strokeCount = 0

for id in ids {
    let dir = notebooksDir.appendingPathComponent(id)
    guard let manifestData = try? Data(contentsOf: dir.appendingPathComponent("manifest.json")),
          let manifest = try? decoder.decode(NotebookManifest.self, from: manifestData)
    else { continue }

    upsertNotebook.bind(1, manifest.notebookId)
    upsertNotebook.bind(2, manifest.title)
    upsertNotebook.bind(3, manifest.openPageId)
    upsertNotebook.bind(4, String(data: try! JSONEncoder().encode(manifest.pageIds), encoding: .utf8)!)
    upsertNotebook.bind(5, manifest.parentFolderId)
    upsertNotebook.bind(6, manifest.defaultBackground)
    upsertNotebook.bind(7, manifest.defaultBackgroundType)
    upsertNotebook.bind(8, manifest.linkedExternalUri)
    upsertNotebook.bind(9, millis(manifest.createdAt))
    upsertNotebook.bind(10, millis(manifest.updatedAt))
    upsertNotebook.run()
    notebookCount += 1

    for pageId in manifest.pageIds {
        let pageURL = dir.appendingPathComponent("pages/\(pageId).json")
        guard let pageData = try? Data(contentsOf: pageURL),
              let page = try? decoder.decode(PageFile.self, from: pageData)
        else { continue }

        upsertPage.bind(1, page.id)
        upsertPage.bind(2, Int64(page.scroll))
        upsertPage.bind(3, page.notebookId ?? manifest.notebookId)
        upsertPage.bind(4, page.background)
        upsertPage.bind(5, page.backgroundType)
        upsertPage.bind(6, page.parentFolderId)
        upsertPage.bind(7, millis(page.createdAt))
        upsertPage.bind(8, millis(page.updatedAt))
        upsertPage.run()
        pageCount += 1

        deleteStrokes.bind(1, page.id)
        deleteStrokes.run()

        for stroke in page.strokes {
            guard let blob = Data(base64Encoded: stroke.pointsData) else { continue }
            insertStroke.bind(1, stroke.id)
            insertStroke.bind(2, Double(stroke.size))
            insertStroke.bind(3, stroke.pen)
            insertStroke.bind(4, Int64(stroke.color))
            insertStroke.bind(5, Int64(stroke.maxPressure))
            insertStroke.bind(6, Double(stroke.top))
            insertStroke.bind(7, Double(stroke.bottom))
            insertStroke.bind(8, Double(stroke.left))
            insertStroke.bind(9, Double(stroke.right))
            insertStroke.bind(10, blob)
            insertStroke.bind(11, page.id)
            insertStroke.bind(12, millis(stroke.createdAt))
            insertStroke.bind(13, millis(stroke.updatedAt))
            insertStroke.run()
            strokeCount += 1
        }
    }
}

exec("COMMIT")
exec("PRAGMA wal_checkpoint(TRUNCATE)")
print("exported \(notebookCount) notebooks, \(pageCount) pages, \(strokeCount) strokes -> \(dbPath)")
