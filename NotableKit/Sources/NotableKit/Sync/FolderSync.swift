import Foundation

/// Pure merge logic for `/notable/folders.json` (see docs §2).
///
/// The whole tree lives in a single file, so reconciliation is a union by folder id with
/// the newer `updatedAt` winning per folder — deterministic (output sorted by id) and
/// convergent from both sides. Entries with unparsable dates lose ties (Notable skips
/// them entirely; we keep whichever side parses).
enum FolderMerge {
    static func merge(local: [FolderDTO], remote: [FolderDTO]) -> [FolderDTO] {
        var byId: [String: FolderDTO] = [:]
        for folder in remote { byId[folder.id] = folder }
        for folder in local {
            if let existing = byId[folder.id] {
                let localMs = epochMs(folder.updatedAt) ?? .min
                let remoteMs = epochMs(existing.updatedAt) ?? .min
                if localMs > remoteMs { byId[folder.id] = folder }
            } else {
                byId[folder.id] = folder
            }
        }
        return byId.values.sorted { $0.id < $1.id }
    }

    private static func epochMs(_ iso: String) -> Int64? {
        NotableDate.parse(iso).map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) }
    }
}

/// Notebook ids deleted locally while offline, persisted at
/// `<root>/.bopa-pending-deletions.json` (dotfile — never uploaded, like
/// `.bopa-sync-state.json`). The sync engine turns each pending id into a zero-byte
/// tombstone at `/notable/deletions/<id>` at the start of the next sync (docs §8).
public enum PendingDeletions {
    public static func fileURL(root: URL) -> URL {
        root.appendingPathComponent(".bopa-pending-deletions.json")
    }

    public static func load(root: URL) -> [String] {
        guard let data = try? Data(contentsOf: fileURL(root: root)),
              let ids = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return ids
    }

    public static func add(_ id: String, root: URL) {
        var ids = load(root: root)
        guard !ids.contains(id) else { return }
        ids.append(id)
        save(ids.sorted(), root: root)
    }

    public static func remove(_ id: String, root: URL) {
        let ids = load(root: root).filter { $0 != id }
        save(ids, root: root)
    }

    private static func save(_ ids: [String], root: URL) {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if ids.isEmpty {
            try? FileManager.default.removeItem(at: fileURL(root: root))
        } else if let data = try? JSONEncoder().encode(ids) {
            try? data.write(to: fileURL(root: root))
        }
    }
}
