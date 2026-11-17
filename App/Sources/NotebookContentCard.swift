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
    @EnvironmentObject private var transcripts: HandwritingTranscriptIndex
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("library.previewContent") private var previewContent = "ink"
    @AppStorage(CouchSettings.cloudTextKey) private var useServerText = false
    let notebook: NotebookManifest
    var layout = NotebookBrowserLayout.feed
    let edit: (String?) -> Void
    var topic: ((String) -> Void)?
    var accessory = AnyView(EmptyView())
    @State private var selectedPage: String?
    @State private var page: PageFile?
    @State private var expanded = false
    @State private var inkFingerprint = ""
    @State private var serverInk: ScribeInkSnapshot?
    @State private var renaming: TitleRenameRequest?
    @State private var showingPages = false

    private var pageID: String? {
        [selectedPage, notebook.openPageId, notebook.pageIds.first].compactMap { $0 }
            .first { notebook.pageIds.contains($0) }
    }
    private var topics: [String] { store.journalEntries[notebook.notebookId]?.visibleTopics ?? [] }
    private var revision: String { pageID.map { store.pageRevision(notebookId: notebook.notebookId, pageId: $0) } ?? "" }
    private var transcript: TranscriptContent? {
        pageID.flatMap { transcripts.content(notebookID: notebook.notebookId, pageID: $0, fingerprint: inkFingerprint, serverInk: serverInk) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                renaming = TitleRenameRequest(notebookID: notebook.notebookId, title: notebook.title)
            } label: {
                Text(transcripts.notebookTitle(notebook, store: store)).font(.headline).lineLimit(2).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }.buttonStyle(.plain).accessibilityLabel("Rename \(transcripts.notebookTitle(notebook, store: store))")
            if layout == .feed {
                LazyVStack(alignment: .leading, spacing: 24) {
                    ForEach(Array(notebook.pageIds.enumerated()), id: \.element) { index, pageID in
                        NotebookReadingPage(notebookID: notebook.notebookId, pageID: pageID, number: index + 1,
                            edit: { edit(pageID) }, rename: { title in
                                renaming = TitleRenameRequest(notebookID: notebook.notebookId, pageID: pageID, title: title)
                            })
                    }
                }
            } else if layout == .compact {
                Button { edit(pageID) } label: {
                    HStack(alignment: .top, spacing: 12) {
                        if let pageID, let image = ThumbnailRenderer.thumbnail(notebookId: notebook.notebookId, pageId: pageID, store: store) {
                            Image(uiImage: image).resizable().scaledToFit().frame(width: 46, height: 62)
                        }
                        VStack(alignment: .leading, spacing: 5) {
                            if let page { Text(FlowText.markdown(in: page.blocks)).font(.callout).lineLimit(2).foregroundStyle(.secondary) }
                            if previewContent == "text", let transcript { TranscriptReadText(content: transcript).font(.callout).frame(maxHeight: 100, alignment: .top).clipped().foregroundStyle(.secondary) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
            } else {
                if let page {
                    NotebookPageContent(page: page, notebookID: notebook.notebookId, transcript: transcript, previewContent: previewContent)
                        .frame(maxHeight: expanded ? nil : layout.previewHeight, alignment: .top).clipped()
                        .background(PreviewPageSwipe(enabled: notebook.pageIds.count > 1, move: movePage))
                        .accessibilityIdentifier("preview.content.\(notebook.notebookId)")
                        .onTapGesture { edit(pageID) }
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
                if layout == .feed {
                    Text("\(notebook.pageIds.count) \(notebook.pageIds.count == 1 ? "page" : "pages")")
                } else if let pageID {
                    Button { renaming = TitleRenameRequest(notebookID: notebook.notebookId, pageID: pageID, title: page?.title ?? "") } label: {
                        Text(transcripts.pageTitle(notebookID: notebook.notebookId, pageID: pageID, store: store) ?? "Page \((notebook.pageIds.firstIndex(of: pageID) ?? 0) + 1)").lineLimit(1)
                    }.accessibilityLabel("Rename page")
                }
                if layout != .feed { Button { showingPages = true } label: {
                    Label("\((notebook.pageIds.firstIndex(of: pageID ?? "") ?? 0) + 1)/\(notebook.pageIds.count)", systemImage: "rectangle.grid.2x2")
                }.accessibilityLabel("Preview pages").accessibilityIdentifier("preview.pages.\(notebook.notebookId)")
                    .accessibilityValue("\((notebook.pageIds.firstIndex(of: pageID ?? "") ?? 0) + 1)/\(notebook.pageIds.count)")
                }
                if layout != .compact && layout != .feed { Button(expanded ? "Collapse" : "Expand") { expanded.toggle() } }
                Spacer(minLength: 0)
                Button("Edit") { edit(pageID) }
                    .accessibilityLabel("Edit \(transcripts.notebookTitle(notebook, store: store))")
                accessory
            }.font(.caption).buttonStyle(.plain).frame(minHeight: 44)
            ModernistRule()
        }.foregroundStyle(Modernist.ink)
            .task(id: "\(layout.rawValue)#\(pageID ?? "")#\(revision)") {
                guard layout != .feed, let pageID else { page = nil; return }
                page = try? store.loadPage(notebookId: notebook.notebookId, pageId: pageID)
                if let page { transcripts.rememberTitlePage(page, revision: revision) }
                inkFingerprint = HandwritingTranscript.fingerprint(page?.strokes ?? [])
                serverInk = page.map(ScribeInkSnapshot.init)
                transcripts.request(notebookID: notebook.notebookId, pageID: pageID, store: store)
            }
            .task(id: "\(layout.rawValue)#\(pageID ?? "")#\(revision)#\(previewContent)#\(useServerText)#\(scenePhase)") {
                guard layout != .feed, let pageID, useServerText, previewContent == "text", scenePhase == .active else { return }
                let owner = UUID()
                defer { transcripts.cancelServerRequest(notebookID: notebook.notebookId, pageID: pageID, owner: owner) }
                while !Task.isCancelled {
                    transcripts.requestServer(notebookID: notebook.notebookId, pageID: pageID, store: store, owner: owner)
                    do { try await Task.sleep(for: .seconds(15)) } catch { return }
                }
            }
            .sheet(item: $renaming) { TitleRenameSheet(request: $0) }
            .sheet(isPresented: $showingPages) {
                NavigationStack {
                    NotebookNavigatorView(notebookId: notebook.notebookId, currentPageId: pageID) {
                        selectedPage = $0; showingPages = false
                    }
                }
            }
    }

    private func movePage(_ direction: Int) {
        guard let pageID, let current = notebook.pageIds.firstIndex(of: pageID), notebook.pageIds.indices.contains(current + direction) else { return }
        selectedPage = notebook.pageIds[current + direction]
    }

    @ViewBuilder private func tag(_ name: String) -> some View {
        if let topic { Button("#\(name)") { topic(name) }.buttonStyle(.plain).font(.caption).frame(minHeight: 44) }
        else { Text("#\(name)").font(.caption) }
    }
}

private struct NotebookReadingPage: View {
    @EnvironmentObject private var store: NotebookStore
    @EnvironmentObject private var transcripts: HandwritingTranscriptIndex
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("library.previewContent") private var previewContent = "ink"
    @AppStorage(CouchSettings.cloudTextKey) private var useServerText = false
    let notebookID: String
    let pageID: String
    let number: Int
    let edit: () -> Void
    let rename: (String) -> Void
    @State private var page: PageFile?
    @State private var inkFingerprint = ""
    @State private var serverInk: ScribeInkSnapshot?

    private var revision: String { store.pageRevision(notebookId: notebookID, pageId: pageID) }
    private var transcript: TranscriptContent? {
        transcripts.content(notebookID: notebookID, pageID: pageID, fingerprint: inkFingerprint, serverInk: serverInk)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { rename(page?.title ?? "") } label: {
                HStack {
                    Text("Page \(number)")
                    if let title = transcripts.pageTitle(notebookID: notebookID, pageID: pageID, store: store), title != "Page \(number)" { Text(title).lineLimit(1) }
                }.font(.caption).foregroundStyle(.secondary).frame(minHeight: 44)
            }.buttonStyle(.plain).accessibilityLabel("Rename page \(number)")
            if let page {
                NotebookPageContent(page: page, notebookID: notebookID, transcript: transcript, previewContent: previewContent)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentShape(Rectangle()).onTapGesture(perform: edit)
                    .accessibilityIdentifier("preview.content.\(notebookID).\(pageID)")
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 100)
            }
        }
        .task(id: revision) {
            let requestedRevision = revision
            let work = Task.detached(priority: .userInitiated) { [store, notebookID, pageID] in
                let page = try? store.readPage(notebookId: notebookID, pageId: pageID)
                return (page, HandwritingTranscript.fingerprint(page?.strokes ?? []), page.map(ScribeInkSnapshot.init))
            }
            let ready = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            guard !Task.isCancelled, revision == requestedRevision else { return }
            page = ready.0; inkFingerprint = ready.1; serverInk = ready.2
            if let page { transcripts.rememberTitlePage(page, revision: requestedRevision) }
            transcripts.request(notebookID: notebookID, pageID: pageID, store: store)
        }
        .task(id: "\(revision)#\(previewContent)#\(useServerText)#\(scenePhase)") {
            guard useServerText, previewContent == "text", scenePhase == .active else { return }
            let owner = UUID()
            defer { transcripts.cancelServerRequest(notebookID: notebookID, pageID: pageID, owner: owner) }
            while !Task.isCancelled {
                transcripts.requestServer(notebookID: notebookID, pageID: pageID, store: store, owner: owner)
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
            }
        }
    }
}

private struct NotebookPageContent: View {
    let page: PageFile
    let notebookID: String
    let transcript: TranscriptContent?
    let previewContent: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if previewContent == "text", let transcript {
                if FlowCanvasPreview.hasNonInkContent(page) { FlowCanvasPreview(page: page, notebookID: notebookID) }
                VStack(alignment: .leading, spacing: 6) {
                    Label("Recognized handwriting", systemImage: "text.viewfinder").font(.caption).foregroundStyle(.secondary)
                    TranscriptReadText(content: transcript)
                }
            } else if FlowCanvasPreview.hasCanvas(page) { FlowCanvasPreview(page: page, notebookID: notebookID) }
            ForEach(FlowText.sections(in: page.blocks)) { section in
                if section.isMarkdown { FlowReadText(source: section.source) }
                else if let block = section.blocks.first, previewContent != "text" || transcript == nil || block.kind != "ink" {
                    FlowBoundaryView(block: block, page: page, notebookID: notebookID)
                }
            }
            if !FlowCanvasPreview.hasCanvas(page), FlowText.ordered(page.blocks).isEmpty {
                Text("Empty note").foregroundStyle(.secondary).padding(.vertical, 24)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
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
