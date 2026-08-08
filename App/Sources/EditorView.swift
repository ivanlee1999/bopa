import NotableKit
import PencilKit
import SwiftUI

/// Page editor: a PencilKit canvas bound to one Notable page, with page navigation.
/// Saves (debounced) after every drawing change and on exit.
struct EditorView: View {
    @EnvironmentObject private var store: NotebookStore
    let notebookId: String

    @State private var pageId: String?
    @State private var page: PageFile?
    @State private var drawing = PKDrawing()
    @State private var pageBackground: UIImage?
    @State private var pageImages: [PageImage] = []
    @State private var dirty = false
    @State private var saveTask: Task<Void, Never>?
    @State private var loadError: String?
    @StateObject private var undoController = CanvasUndoController()
    @State private var scrollState = CanvasScrollState()

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
                EditorCanvasView(
                    pageId: pageId,
                    background: pageBackground,
                    images: pageImages,
                    pageScroll: page?.scroll ?? 0,
                    drawing: $drawing,
                    undoController: undoController,
                    scrollState: scrollState,
                    onChanged: scheduleSave)
                    .ignoresSafeArea(edges: .bottom)
            }
        }
        .navigationTitle(manifest?.title ?? "Notebook")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    undoController.undo()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .disabled(!undoController.canUndo)
                .accessibilityIdentifier("editor.undo")

                Button {
                    undoController.redo()
                } label: {
                    Image(systemName: "arrow.uturn.forward")
                }
                .disabled(!undoController.canRedo)
                .accessibilityIdentifier("editor.redo")

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
        .onAppear { if pageId == nil { openInitialPage() } }
        .onDisappear { saveNow() }
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
            let notebookDir = store.notebookDirURL(notebookId)
            pageBackground = BackgroundRenderer.image(
                for: loaded,
                notebookDir: notebookDir,
                storeRoot: store.rootURL)
            pageImages = BackgroundRenderer.pageImages(for: loaded, notebookDir: notebookDir)
            // Seed with the persisted offset so a save before any scroll preserves it.
            scrollState.pageY = CGFloat(max(loaded.scroll, 0))
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
        saveTask?.cancel()
        guard var page else { return }
        let scroll = max(0, Int(scrollState.pageY.rounded()))
        guard dirty || scroll != page.scroll else { return }
        page.strokes = PencilKitBridge.strokeDTOs(from: drawing)
        page.scroll = scroll
        self.page = page
        try? store.savePage(page)
        dirty = false
    }
}

/// Reference box for the canvas's current scroll offset in unzoomed page space, written
/// by the canvas coordinator on every scroll and read at save time. A plain class (not
/// observable) on purpose: scrolling must not trigger SwiftUI re-renders.
@MainActor
final class CanvasScrollState {
    var pageY: CGFloat = 0
}

/// Bridges the canvas's NSUndoManager to SwiftUI button state. PencilKit registers
/// drawing edits with the responder chain's undo manager (the one CanvasContainerView
/// owns); this observes that manager's notifications so the toolbar buttons
/// enable/disable correctly.
@MainActor
final class CanvasUndoController: NSObject, ObservableObject {
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    private weak var manager: UndoManager?

    func attach(_ manager: UndoManager) {
        guard manager !== self.manager else { return }
        if let old = self.manager {
            NotificationCenter.default.removeObserver(self, name: nil, object: old)
        }
        self.manager = manager
        let names: [Notification.Name] = [
            .NSUndoManagerCheckpoint,
            .NSUndoManagerDidUndoChange,
            .NSUndoManagerDidRedoChange,
        ]
        for name in names {
            NotificationCenter.default.addObserver(
                self, selector: #selector(undoManagerStateDidChange(_:)),
                name: name, object: manager)
        }
        refresh()
    }

    func undo() { manager?.undo() }
    func redo() { manager?.redo() }

    /// Re-reads canUndo/canRedo. Also called explicitly after removeAllActions(),
    /// which posts no notification.
    func refresh() {
        canUndo = manager?.canUndo ?? false
        canRedo = manager?.canRedo ?? false
    }

    @objc private func undoManagerStateDidChange(_ note: Notification) {
        refresh()
    }
}

/// PKCanvasView wrapper. The canvas is its own scroll view; content grows vertically
/// (Notable pages are infinite vertical scroll).
struct EditorCanvasView: UIViewRepresentable {
    /// Identity of the loaded page. The canvas content is (re)loaded from `drawing` ONLY
    /// when this changes — never on ordinary SwiftUI renders. Programmatically setting
    /// `PKCanvasView.drawing` cancels any in-flight stroke, and PKDrawing's equality is
    /// identity-like, so a value-compare guard cannot prevent that (found by UI-test bisect).
    var pageId: String?
    var background: UIImage?
    var images: [PageImage] = []
    /// Persisted unzoomed page-space y offset, applied on page switches.
    var pageScroll: Int = 0
    @Binding var drawing: PKDrawing
    var undoController: CanvasUndoController = CanvasUndoController()
    var scrollState: CanvasScrollState = CanvasScrollState()
    var onChanged: () -> Void

    /// Logical page width shared with the BOOX (Notable uses the device's pixel width;
    /// strokes beyond this width would clip on the tablet).
    static let pageWidth: CGFloat = 1404
    static let minimumHeight: CGFloat = 3744

    func makeUIView(context: Context) -> CanvasContainerView {
        let container = CanvasContainerView()
        context.coordinator.container = container
        let canvas = container.canvas
        canvas.delegate = context.coordinator
        canvas.drawingPolicy = .anyInput
        canvas.tool = PKInkingTool(.pen, color: .black, width: 5)
        canvas.isAccessibilityElement = true
        canvas.accessibilityIdentifier = "editor.canvas"
        canvas.accessibilityValue = "strokes:0"
        canvas.contentSize = CGSize(width: Self.pageWidth, height: Self.minimumHeight)
        canvas.minimumZoomScale = 0.25
        canvas.maximumZoomScale = 3

        undoController.attach(container.pageUndoManager)

        let picker = context.coordinator.toolPicker
        picker.setVisible(true, forFirstResponder: canvas)
        picker.addObserver(canvas)
        canvas.becomeFirstResponder()
        return container
    }

    func updateUIView(_ container: CanvasContainerView, context: Context) {
        let canvas = container.canvas
        // Background and images may arrive/change without a page switch; both setters are
        // idempotent and never touch canvas.drawing.
        container.setBackground(background)
        container.setImages(images)
        // Load canvas content ONLY on page switches (found by UI-test bisect): assigning
        // canvas.drawing on ordinary renders cancels in-flight strokes, and PKDrawing
        // equality is identity-like, so a != guard cannot prevent that.
        guard context.coordinator.loadedPageId != pageId else { return }
        context.coordinator.loadedPageId = pageId
        context.coordinator.programmaticUpdate = true
        canvas.drawing = drawing
        context.coordinator.programmaticUpdate = false
        canvas.accessibilityValue = "strokes:\(drawing.strokes.count)"
        Self.growContent(canvas, for: drawing)
        // A page switch must not be undoable into the previous page's drawing.
        container.pageUndoManager.removeAllActions()
        undoController.refresh()
        // Restore the persisted scroll position for this page.
        container.setInitialScroll(pageY: CGFloat(pageScroll))
    }

    /// Grows the scrollable height to fit the drawing. An EMPTY drawing has a null bounds
    /// whose maxY is CGFLOAT_MAX — setting contentSize to that breaks the scroll view's
    /// gesture system and permanently disables inking (found by UI-test bisect).
    static func growContent(_ canvas: PKCanvasView, for drawing: PKDrawing) {
        let bounds = drawing.bounds
        guard !bounds.isNull, bounds.maxY.isFinite else { return }
        let needed = bounds.maxY + 1000
        if needed > canvas.contentSize.height {
            canvas.contentSize.height = needed
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        let parent: EditorCanvasView
        let toolPicker = PKToolPicker()
        var programmaticUpdate = false
        var loadedPageId: String?
        weak var container: CanvasContainerView?

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            container?.updateContentGeometry()
            parent.scrollState.pageY =
                scrollView.contentOffset.y / max(scrollView.zoomScale, 0.01)
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            container?.updateContentGeometry()
            parent.scrollState.pageY =
                scrollView.contentOffset.y / max(scrollView.zoomScale, 0.01)
        }

        init(_ parent: EditorCanvasView) {
            self.parent = parent
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            guard !programmaticUpdate else { return }
            let drawing = canvasView.drawing
            parent.drawing = drawing
            canvasView.accessibilityValue = "strokes:\(drawing.strokes.count)"
            parent.onChanged()
            EditorCanvasView.growContent(canvasView, for: drawing)
        }
    }
}
