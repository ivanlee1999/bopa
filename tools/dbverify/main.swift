import Foundation
import SQLite3

// Decode every stroke blob in a real BOOX-written Notable database with NotableKit's
// SB codec — the definitive byte-level compatibility check.

let dbPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "boox/b/notabledb/app_database"

var db: OpaquePointer?
guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
    fatalError("cannot open \(dbPath)")
}
defer { sqlite3_close(db) }

var stmt: OpaquePointer?
let sql = "SELECT id, pen, color, size, maxPressure, points FROM stroke"
guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
    fatalError("prepare failed: \(String(cString: sqlite3_errmsg(db)))")
}
defer { sqlite3_finalize(stmt) }

var total = 0
var decoded = 0
var failures: [String] = []
var totalPoints = 0
var pens: [String: Int] = [:]
var masks: [String: Int] = [:]
var maxPressures: Set<Int> = []
var pressureRange: (Float, Float) = (1, 0)
var compressionCounts: [UInt8: Int] = [:]

while sqlite3_step(stmt) == SQLITE_ROW {
    total += 1
    let id = String(cString: sqlite3_column_text(stmt, 0))
    let pen = String(cString: sqlite3_column_text(stmt, 1))
    let maxPressure = Int(sqlite3_column_int(stmt, 4))
    maxPressures.insert(maxPressure)
    pens[pen, default: 0] += 1

    guard let blobPtr = sqlite3_column_blob(stmt, 5) else {
        failures.append("\(id): NULL blob")
        continue
    }
    let blobLen = Int(sqlite3_column_bytes(stmt, 5))
    let data = Data(bytes: blobPtr, count: blobLen)
    if data.count > 8 { compressionCounts[data[8], default: 0] += 1 }

    do {
        let points = try SBStrokeCodec.decode(data)
        decoded += 1
        totalPoints += points.count
        var channels: [String] = []
        if points.first?.pressure != nil { channels.append("p") }
        if points.first?.tiltX != nil { channels.append("tx") }
        if points.first?.tiltY != nil { channels.append("ty") }
        if points.first?.dt != nil { channels.append("dt") }
        masks[channels.joined(separator: "+"), default: 0] += 1
        for pt in points {
            if let p = pt.pressure {
                let norm = maxPressure == 1 ? p : p / Float(maxPressure)
                pressureRange.0 = min(pressureRange.0, norm)
                pressureRange.1 = max(pressureRange.1, norm)
            }
        }
    } catch {
        failures.append("\(id) (pen \(pen), \(blobLen)B): \(error)")
    }
}

print("strokes: \(total), decoded OK: \(decoded), failures: \(failures.count)")
print("total points: \(totalPoints)")
print("pens: \(pens.sorted { $0.value > $1.value })")
print("channel sets: \(masks)")
print("maxPressure values: \(maxPressures.sorted())")
print("normalized pressure range: \(pressureRange.0)...\(pressureRange.1)")
print("compression flags (0=raw,1=lz4): \(compressionCounts)")
for f in failures.prefix(10) { print("FAIL: \(f)") }
exit(failures.isEmpty && total > 0 ? 0 : 1)
