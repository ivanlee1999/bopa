import Foundation
import SQLite3

// Convert a Notable on-device SQLite database into the WebDAV/local-store layout
// (notebooks/<id>/manifest.json + pages/<pageId>.json) used by the bopa iPad app.
// Usage: dbimport <app_database> <outputRoot>

enum BackgroundKind {
    static func isFileBacked(_ type: String) -> Bool {
        type.hasPrefix("pdf") || type == "autoPdf" || type.hasPrefix("image")
    }
}

guard CommandLine.arguments.count == 3 else {
    fatalError("usage: dbimport <app_database> <outputRoot>")
}
let dbPath = CommandLine.arguments[1]
let outRoot = URL(fileURLWithPath: CommandLine.arguments[2])


/// Opens the database, preferring read-write. A WAL-mode database needs write access to
/// recover its -wal file (where the newest strokes live), so read-write is tried first and
/// read-only is the fallback for copies on read-only media.
func openDatabase(_ path: String) -> OpaquePointer {
    var handle: OpaquePointer?
    if sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let opened = handle {
        return opened
    }
    if handle != nil {
        sqlite3_close(handle)
        handle = nil
    }
    if sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let opened = handle {
        FileHandle.standardError.write(
            Data("note: opened read-only; unflushed -wal content may be missing\n".utf8))
        return opened
    }
    fatalError("cannot open \(path): \(handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error")")
}

/// Prepares a statement, surfacing SQLite's error instead of returning a nil handle that
/// would crash the next sqlite3_step.
func prepare(_ db: OpaquePointer, _ sql: String) -> OpaquePointer {
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let prepared = stmt else {
        fatalError("prepare failed for \(sql): \(String(cString: sqlite3_errmsg(db)))")
    }
    return prepared
}
let db = openDatabase(dbPath)
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
var stmt = prepare(db, "SELECT id,size,pen,color,maxPressure,top,bottom,left,right,points,pageId,createdAt,updatedAt FROM Stroke")
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
stmt = prepare(db, "SELECT id,scroll,notebookId,background,backgroundType,parentFolderId,createdAt,updatedAt FROM Page")
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
stmt = prepare(db, "SELECT id,title,openPageId,pageIds,parentFolderId,defaultBackground,defaultBackgroundType,linkedExternalUri,createdAt,updatedAt FROM Notebook")
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

    // Copy referenced PDF/image backgrounds (device-absolute paths in the DB; the files
    // live next to the database). Resolution in the app is by basename.
    let dbDir = URL(fileURLWithPath: dbPath).deletingLastPathComponent()
    let bgDir = outRoot.appendingPathComponent("notebooks/\(id)/backgrounds")
    var copiedBackgrounds: Set<String> = []
    for pageId in pageIds {
        guard let page = pages[pageId],
              BackgroundKind.isFileBacked(page.backgroundType) else { continue }
        let basename = (page.background as NSString).lastPathComponent
        guard !basename.isEmpty, !copiedBackgrounds.contains(basename) else { continue }
        copiedBackgrounds.insert(basename)
        for sub in ["backgrounds/pdfs", "backgrounds/images", "backgrounds"] {
            let source = dbDir.appendingPathComponent("\(sub)/\(basename)")
            if FileManager.default.fileExists(atPath: source.path) {
                try? FileManager.default.createDirectory(at: bgDir, withIntermediateDirectories: true)
                try? FileManager.default.copyItem(at: source, to: bgDir.appendingPathComponent(basename))
                break
            }
        }
    }
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

// Folders -> folders.json (same columns as the wire DTO; timestamps are epoch millis).
var folders: [FolderDTO] = []
// Optional handle, not `prepare`: older databases have no Folder table, and its absence
// is expected rather than fatal.
var folderStmt: OpaquePointer?
if sqlite3_prepare_v2(
    db, "SELECT id,title,parentFolderId,createdAt,updatedAt FROM Folder", -1, &folderStmt, nil
) == SQLITE_OK, let folderStmt {
    while sqlite3_step(folderStmt) == SQLITE_ROW {
        folders.append(FolderDTO(
            id: text(folderStmt, 0)!,
            title: text(folderStmt, 1) ?? "Untitled",
            parentFolderId: text(folderStmt, 2),
            createdAt: iso(sqlite3_column_int64(folderStmt, 3)),
            updatedAt: iso(sqlite3_column_int64(folderStmt, 4))))
    }
    sqlite3_finalize(folderStmt)
}
if !folders.isEmpty {
    try! FileManager.default.createDirectory(at: outRoot, withIntermediateDirectories: true)
    let file = FoldersFile(folders: folders, serverTimestamp: NotableDate.format(Date()))
    try! encoder.encode(file).write(to: outRoot.appendingPathComponent("folders.json"))
}

print("imported \(notebookCount) notebooks, \(pageWrites) pages, \(strokeCount) strokes, \(folders.count) folders -> \(outRoot.path)")
