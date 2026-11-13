import NotableKit
import SwiftUI

enum NotebookBrowserLayout: String, CaseIterable, Identifiable {
    case feed, compact, large, medium, overview
    var id: String { rawValue }
    var title: String {
        switch self {
        case .feed: "Reading feed"
        case .compact: "Compact list"
        case .large: "2 × 2"
        case .medium: "2 × 3"
        case .overview: "3 × 4"
        }
    }
    var columns: Int { self == .feed || self == .compact ? 1 : self == .overview ? 3 : 2 }
    var previewHeight: CGFloat { self == .overview ? 110 : self == .medium ? 170 : 260 }
    static func resolve(_ key: String, compact: Bool) -> Self {
        if key == "list" { return .compact }
        if key == "grid" { return .large }
        let selected = Self(rawValue: key) ?? .feed
        return compact && selected == .overview ? .medium : selected
    }
}

struct NotebookContentCard: View {
    @EnvironmentObject private var store: NotebookStore
    let notebook: NotebookManifest
    var layout = NotebookBrowserLayout.feed
    let edit: (String?) -> Void
    var topic: ((String) -> Void)?
    var accessory = AnyView(EmptyView())
    @State private var selectedPage: String?
    @State private var page: PageFile?
    @State private var expanded = false

    private var pageID: String? {
        [selectedPage, notebook.openPageId, notebook.pageIds.first].compactMap { $0 }
            .first { notebook.pageIds.contains($0) }
    }
    private var topics: [String] { store.journalEntries[notebook.notebookId]?.visibleTopics ?? [] }
    private var revision: String { pageID.map { store.pageRevision(notebookId: notebook.notebookId, pageId: $0) } ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if layout == .compact {
                Button { edit(pageID) } label: {
                    HStack(alignment: .top, spacing: 12) {
                        if let pageID, let image = ThumbnailRenderer.thumbnail(notebookId: notebook.notebookId, pageId: pageID, store: store) {
                            Image(uiImage: image).resizable().scaledToFit().frame(width: 46, height: 62)
                        }
                        VStack(alignment: .leading, spacing: 5) {
                            Text(notebook.title).font(.headline).lineLimit(2)
                            if let page { Text(FlowText.markdown(in: page.blocks)).font(.callout).lineLimit(2).foregroundStyle(.secondary) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
            } else {
                Text(notebook.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let page {
                    VStack(alignment: .leading, spacing: 14) {
                        if FlowCanvasPreview.hasCanvas(page) { FlowCanvasPreview(page: page, notebookID: notebook.notebookId) }
                        ForEach(FlowText.sections(in: page.blocks)) { section in
                            if section.isMarkdown { FlowReadText(source: section.source) }
                            else if let block = section.blocks.first { FlowBoundaryView(block: block, page: page, notebookID: notebook.notebookId) }
                        }
                        if !FlowCanvasPreview.hasCanvas(page), FlowText.ordered(page.blocks).isEmpty {
                            Text("Empty note").foregroundStyle(.secondary).padding(.vertical, 24)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                        .frame(maxHeight: expanded ? nil : layout.previewHeight, alignment: .top).clipped()
                } else {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 100)
                }
            }
            if !topics.isEmpty {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { ForEach(topics, id: \.self) { tag($0) } }
                    Text(topics.map { "#\($0)" }.joined(separator: "  ")).font(.caption)
                }
            }
            HStack(spacing: 8) {
                if notebook.pageIds.count > 1 {
                    Menu {
                        ForEach(Array(notebook.pageIds.enumerated()), id: \.element) { index, id in
                            Button("Page \(index + 1)") { selectedPage = id }
                        }
                    } label: { Text("\((notebook.pageIds.firstIndex(of: pageID ?? "") ?? 0) + 1)/\(notebook.pageIds.count)") }
                    .accessibilityLabel("Preview pages")
                }
                if layout != .compact { Button(expanded ? "Collapse" : "Expand") { expanded.toggle() } }
                Spacer(minLength: 0)
                Button("Edit") { edit(pageID) }
                    .accessibilityLabel("Edit \(notebook.title)")
                accessory
            }.font(.caption).buttonStyle(.plain).frame(minHeight: 44)
            ModernistRule()
        }.foregroundStyle(Modernist.ink)
            .task(id: "\(pageID ?? "")#\(revision)") {
                guard let pageID else { page = nil; return }
                page = try? store.loadPage(notebookId: notebook.notebookId, pageId: pageID)
            }
    }

    @ViewBuilder private func tag(_ name: String) -> some View {
        if let topic { Button("#\(name)") { topic(name) }.buttonStyle(.plain).font(.caption).frame(minHeight: 44) }
        else { Text("#\(name)").font(.caption) }
    }
}

struct FlowReadText: View {
    let source: String
    private func text(_ line: MarkdownText.Line) -> Text {
        let prefix: String
        switch line.kind { case .bullet: prefix = "• "; case .numbered(let number): prefix = "\(number). "; default: prefix = "" }
        return line.spans.reduce(Text(prefix)) { result, span in
            var piece = Text(span.text)
            if span.traits.contains(.bold) { piece = piece.bold() }
            if span.traits.contains(.italic) { piece = piece.italic() }
            if span.traits.contains(.code) { piece = piece.monospaced() }
            if span.traits.contains(.link) { piece = piece.underline() }
            return result + piece
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(MarkdownText.parse(source).enumerated()), id: \.offset) { _, line in
                text(line).font(font(line.kind)).frame(maxWidth: .infinity, alignment: .leading)
            }
        }.textSelection(.enabled)
    }
    private func font(_ kind: MarkdownText.LineKind) -> Font {
        switch kind {
        case .heading(let level): level == 1 ? .title : level == 2 ? .title2 : .headline
        default: .body
        }
    }
}
