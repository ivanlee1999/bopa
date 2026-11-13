import Foundation

/// The document projection of existing blocks. Geometry stays on the canvas; editing a run
/// changes only its Markdown blocks and leaves the boundaries between runs intact.
public enum FlowText {
    public struct Section: Identifiable, Equatable, Sendable {
        public let id: String
        public let blocks: [CouchBlock]
        public var isMarkdown: Bool { blocks.allSatisfy { $0.kind == "md" } }
        public var source: String { MarkdownBlocks.join(blocks.map { $0.text ?? "" }) }
    }

    public enum EditError: Error { case boundaryChanged }

    public static func isFlow(_ block: CouchBlock) -> Bool {
        (block.x == nil || block.y == nil) && block.kind != "text-version"
    }

    public static func ordered(_ blocks: [CouchBlock]) -> [CouchBlock] {
        blocks.filter(isFlow).sorted {
            let key = CouchMerge.byteCompare($0.orderKey, $1.orderKey)
            return key == 0 ? CouchMerge.byteCompare($0.id, $1.id) < 0 : key < 0
        }
    }

    public static func sections(in blocks: [CouchBlock]) -> [Section] {
        var result: [Section] = []
        var markdown: [CouchBlock] = []
        func flush() {
            if let first = markdown.first { result.append(Section(id: first.id, blocks: markdown)) }
            markdown = []
        }
        for block in ordered(blocks) {
            if block.kind == "md" { markdown.append(block) }
            else { flush(); result.append(Section(id: block.id, blocks: [block])) }
        }
        flush()
        return result
    }

    public static func markdown(in blocks: [CouchBlock]) -> String {
        MarkdownBlocks.join(ordered(blocks).filter { $0.kind == "md" }.map { $0.text ?? "" })
    }

    public static func inkIDs(in blocks: [CouchBlock]) -> Set<String> {
        Set(ordered(blocks).filter { $0.kind == "ink" }.flatMap(\.strokeIds))
    }

    /// A merged reference may name a stroke twice. Its first document occurrence owns it.
    public static func inkIDs(for blockID: String, in blocks: [CouchBlock]) -> Set<String> {
        var seen: Set<String> = []
        for block in ordered(blocks) where block.kind == "ink" {
            let owned = Set(block.strokeIds).subtracting(seen)
            if block.id == blockID { return owned }
            seen.formUnion(owned)
        }
        return []
    }

    /// Reconciles one continuous editor against the latest page. Unchanged paragraphs keep
    /// their ids and bytes; changed paragraphs retain identity; only additions mint ids.
    /// A new non-text boundary under a dirty draft refuses the edit instead of moving it.
    public static func replacing(
        base: [CouchBlock], in current: [CouchBlock], with source: String,
        stamp: String, deviceID: String, makeID: () -> String = { UUID().uuidString.lowercased() }
    ) throws -> [CouchBlock] {
        let flow = ordered(current)
        let baseIDs = Set(base.map(\.id))
        let currentByID = Dictionary(current.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let indices = flow.indices.filter { baseIDs.contains(flow[$0].id) }
        if !base.isEmpty {
            guard indices.count == base.count,
                  indices.allSatisfy({ flow[$0].kind == "md" }),
                  let first = indices.first, let last = indices.last,
                  flow[first...last].allSatisfy({ baseIDs.contains($0.id) })
            else { throw EditError.boundaryChanged }
        }
        if source.utf8.elementsEqual(MarkdownBlocks.join(base.map { $0.text ?? "" }).utf8) {
            return current
        }

        let chunks = MarkdownBlocks.split(source)
        var assignments = Array<Int?>(repeating: nil, count: chunks.count)
        var unused = Set(base.indices)
        var exact: [Data: [Int]] = [:]
        for i in base.indices { exact[Data((base[i].text ?? "").utf8), default: []].append(i) }
        for i in chunks.indices {
            let key = Data(chunks[i].utf8)
            if var candidates = exact[key], !candidates.isEmpty {
                let old = candidates.removeFirst(); exact[key] = candidates
                assignments[i] = old; unused.remove(old)
            }
        }
        var cursor = 0
        while cursor < chunks.count {
            if assignments[cursor] != nil { cursor += 1; continue }
            let start = cursor
            while cursor < chunks.count && assignments[cursor] == nil { cursor += 1 }
            let before = start > 0 ? assignments[start - 1] : nil
            let after = cursor < chunks.count ? assignments[cursor] : nil
            let lower = (before ?? -1) + 1, upper = after ?? base.count
            let candidates = unused.sorted().filter { $0 >= lower && $0 < upper }
            for (new, old) in zip(start..<cursor, candidates) {
                assignments[new] = old; unused.remove(old)
            }
        }

        let replacement = chunks.indices.map { index -> CouchBlock in
            if let old = assignments[index] {
                let original = base[old]
                var block = currentByID[original.id] ?? original
                // Untouched local text must not overwrite a paragraph edited remotely.
                if chunks[index].utf8.elementsEqual((original.text ?? "").utf8) { return block }
                block.text = chunks[index]; block.updatedAt = stamp; block.deviceId = deviceID
                return block
            }
            return CouchBlock(id: makeID(), kind: "md", text: chunks[index],
                              createdAt: stamp, updatedAt: stamp, deviceId: deviceID)
        }
        var updatedFlow: [CouchBlock] = []
        var inserted = false
        for block in flow {
            if baseIDs.contains(block.id) {
                if !inserted { updatedFlow += replacement; inserted = true }
            } else { updatedFlow.append(block) }
        }
        if !inserted { updatedFlow += replacement }
        if updatedFlow.map(\.id) != flow.map(\.id) {
            // Rebalance only on an actual insertion/deletion/reorder. Old keys may be empty
            // or tied, so there is not always a string between two neighbours.
            for i in updatedFlow.indices {
                let key = String(format: "%012d", i)
                if updatedFlow[i].orderKey != key {
                    updatedFlow[i].orderKey = key
                    updatedFlow[i].updatedAt = stamp; updatedFlow[i].deviceId = deviceID
                }
            }
        }
        return current.filter { !isFlow($0) } + updatedFlow
    }
}
