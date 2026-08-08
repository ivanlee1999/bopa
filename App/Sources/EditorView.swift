import NotableKit
import OSLog
import PencilKit
import SwiftUI

let edlog = Logger(subsystem: "dev.ivan.bopa", category: "editor")

/// Page editor: a PencilKit canvas bound to one Notable page, with page navigation.
/// Saves (debounced) after every drawing change and on exit.
struct EditorView: View {
    @EnvironmentObject private var store: NotebookStore
    let notebookId: String

    @State private var pageId: String?
    @State private var page: PageFile?
    @State private var drawing = PKDrawing()
    @State private var dirty = false
    @State private var saveTask: Task<Void, Never>?
    @State private var loadError: String?

    private var manifest: NotebookManifest? { store.manifest(id: notebookId) }
    private var pageIndex: Int {
        guard let manifest, let pageId else { return 0 }
        return manifest.pageIds.firstIndex(of: pageId) ?? 0
    }

    var body: some View {
        Group {
            if let loadError {
                ContentUnavailableView(
                    "Could not open page", systemImage: "exclamationmark.triangle",
                    description: Text(loadError))
            } else {
                CanvasView(drawing: $drawing, onChanged: scheduleSave)
                    .ignoresSafeArea(edges: .bottom)
            }
        }
        .navigationTitle(manifest?.title ?? "Notebook")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if let manifest {
                    Button {
                        openPage(at: pageIndex - 1)
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .disabled(pageIndex == 0)

                    Text("\(pageIndex + 1)/\(manifest.pageIds.count)")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)

                    Button {
                        openPage(at: pageIndex + 1)
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .disabled(pageIndex >= manifest.pageIds.count - 1)

                    Button {
                        addPage()
                    } label: {
                        Image(systemName: "plus.square")
                    }
                }
            }
        }
        .onAppear { edlog.warning("EditorView appear"); if pageId == nil { openInitialPage() } }
        .onDisappear { edlog.warning("EditorView DISAPPEAR"); saveNow() }
    }

    private func openInitialPage() {
        guard let manifest else { return }
        let initial = manifest.openPageId ?? manifest.pageIds.first
        if let initial { open(pageId: initial) }
    }

    private func openPage(at index: Int) {
        guard let manifest, manifest.pageIds.indices.contains(index) else { return }
        saveNow()
        open(pageId: manifest.pageIds[index])
    }

    private func open(pageId newPageId: String) {
        do {
            let loaded = try store.loadPage(notebookId: notebookId, pageId: newPageId)
            page = loaded
            pageId = newPageId
            drawing = PencilKitBridge.drawing(from: loaded.strokes)
            dirty = false
            loadError = nil
        } catch {
            loadError = String(describing: error)
        }
    }

    private func addPage() {
        saveNow()
        if let newPage = try? store.addPage(to: notebookId) {
            open(pageId: newPage.id)
        }
    }

    private func scheduleSave() {
        dirty = true
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { saveNow() }
        }
    }

    private func saveNow() {
        edlog.warning("saveNow dirty=\(dirty)")
        saveTask?.cancel()
        guard dirty, var page else { return }
        page.strokes = PencilKitBridge.strokeDTOs(from: drawing)
        self.page = page
        try? store.savePage(page)
        dirty = false
    }
}

/// PKCanvasView wrapper. The canvas is its own scroll view; content grows vertically
/// (Notable pages are infinite vertical scroll).
private struct CanvasView: UIViewRepresentable {
    @Binding var drawing: PKDrawing
    var onChanged: () -> Void

    /// Logical page width shared with the BOOX (Notable uses the device's pixel width;
    /// strokes beyond this width would clip on the tablet).
    static let pageWidth: CGFloat = 1404
    static let minimumHeight: CGFloat = 3744

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.delegate = context.coordinator
        canvas.drawingPolicy = .anyInput
        canvas.contentSize = CGSize(width: Self.pageWidth, height: Self.minimumHeight)
        canvas.minimumZoomScale = 0.25
        canvas.maximumZoomScale = 3
        canvas.drawing = drawing

        let picker = context.coordinator.toolPicker
        picker.setVisible(true, forFirstResponder: canvas)
        picker.addObserver(canvas)
        canvas.becomeFirstResponder()
        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        // Push external drawing changes (page switches) without echoing canvas edits back.
        if !context.coordinator.canvasIsUpdating, canvas.drawing != drawing {
            edlog.warning("updateUIView: pushing drawing to canvas (\(drawing.strokes.count) strokes)")
            context.coordinator.programmaticUpdate = true
            canvas.drawing = drawing
            context.coordinator.programmaticUpdate = false
            growContent(canvas)
        }
    }

    private func growContent(_ canvas: PKCanvasView) {
        let needed = canvas.drawing.bounds.maxY + 1000
        if needed > canvas.contentSize.height {
            canvas.contentSize.height = needed
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        let parent: CanvasView
        let toolPicker = PKToolPicker()
        var programmaticUpdate = false
        var canvasIsUpdating = false

        init(_ parent: CanvasView) {
            self.parent = parent
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            edlog.warning("drawingDidChange programmatic=\(self.programmaticUpdate) strokes=\(canvasView.drawing.strokes.count)")
            guard !programmaticUpdate else { return }
            canvasIsUpdating = true
            parent.drawing = canvasView.drawing
            canvasIsUpdating = false
            parent.onChanged()
            let needed = canvasView.drawing.bounds.maxY + 1000
            if needed > canvasView.contentSize.height {
                canvasView.contentSize.height = needed
            }
        }
    }
}
