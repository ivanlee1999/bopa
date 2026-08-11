import NotableKit
import PencilKit
import SwiftUI

/// Page editor: a PencilKit canvas bound to one Notable page, with page navigation.
/// Saves (debounced) after every drawing change and on exit.
struct EditorView: View {
    @EnvironmentObject private var store: NotebookStore
    @EnvironmentObject private var handwriting: HandwritingSettings
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    let notebookId: String
    /// Dismisses the editor. The chrome is drawn here rather than in a navigation bar, so
    /// the presenter hands the close action down instead of contributing a toolbar item.
    var onClose: (() -> Void)?

    @StateObject private var toolSelection = ToolSelection()
    @State private var pageId: String?
    @State private var page: PageFile?
    @State private var drawing = PKDrawing()
    @State private var pageBackground: UIImage?
    @State private var pageImages: [PageImage] = []
    @State private var dirty = false
    @State private var saveTask: Task<Void, Never>?
    @State private var loadError: String?
    @State private var saveError: String?
    @StateObject private var undoController = CanvasUndoController()
    @State private var scrollState = CanvasScrollState()

    private var manifest: NotebookManifest? { store.manifest(id: notebookId) }
    private var pageIndex: Int {
        guard let manifest, let pageId else { return 0 }
        return manifest.pageIds.firstIndex(of: pageId) ?? 0
    }

    /// The current page's native paper. PDF- and image-backed pages draw no template:
    /// their background image already carries the paper.
    private var pageTemplate: NativeTemplate {
        guard let page else { return .blank }
        let background = PageBackground(background: page.background, backgroundType: page.backgroundType)
        guard case .native(let template) = background, template.isDrawable else { return .blank }
        return template
    }

    /// Only native-backed pages can switch template; changing a PDF-backed page would
    /// throw away the link to its PDF (which the BOOX side also relies on).
    private var canChangeTemplate: Bool {
        guard let page else { return false }
        let background = PageBackground(background: page.background, backgroundType: page.backgroundType)
        if case .native = background { return true }
        return false
    }

    /// The one-handed layout: the rail docks along the bottom instead of the left edge.
    private var isCompact: Bool { horizontalSizeClass == .compact }

    var body: some View {
        chrome
            .background(Modernist.canvas)
            .toolbar(.hidden, for: .navigationBar)
            .onAppear { if pageId == nil { openInitialPage() } }
            .onDisappear { saveNow() }
            // Leaving the app does not pop the editor, so the debounced save has to be flushed
            // here too — otherwise switching apps or locking the iPad within two seconds of the
            // last stroke loses it.
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { saveNow() }
            }
            .alert(
                "Couldn’t save this page", isPresented: .constant(saveError != nil),
                presenting: saveError
            ) { _ in
                Button("OK") { saveError = nil }
            } message: { error in
                Text("Your strokes are still here and bopa will try again. \(error)")
            }
    }

    // MARK: Chrome

    /// Rail and bar are docked, not floating: nothing here moves, overlaps the page or
    /// waits to be dragged out of the way.
    @ViewBuilder
    private var chrome: some View {
        if isCompact {
            VStack(spacing: 0) {
                topBar
                canvasArea
                ToolRail(selection: toolSelection, undo: undoController, vertical: false)
            }
        } else {
            HStack(spacing: 0) {
                ToolRail(selection: toolSelection, undo: undoController, vertical: true)
                VStack(spacing: 0) {
                    topBar
                    canvasArea
                        .ignoresSafeArea(edges: .bottom)
                }
            }
            .ignoresSafeArea(edges: .bottom)
        }
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            Button {
                onClose?()
            } label: {
                Image(systemName: "chevron.backward")
                    .font(.system(size: 17, weight: .semibold))
            }
            .buttonStyle(RailButtonStyle(selected: false, size: 34))
            .accessibilityLabel("Library")
            .accessibilityIdentifier("editor.close")

            Text(manifest?.title ?? "Notebook")
                .font(Modernist.font(15, .bold))
                .foregroundStyle(Modernist.ink)
                .lineLimit(1)

            Spacer(minLength: 8)

            if let manifest { pageControls(manifest) }
            optionsMenu
        }
        .padding(.horizontal, 8)
        .frame(height: Modernist.hit)
        .background(Modernist.rail)
        .overlay(alignment: .bottom) { ModernistRule() }
    }

    private func pageControls(_ manifest: NotebookManifest) -> some View {
        HStack(spacing: 2) {
            Button {
                openPage(at: pageIndex - 1)
            } label: {
                Image(systemName: "chevron.left").font(.system(size: 15, weight: .semibold))
            }
            .buttonStyle(RailButtonStyle(selected: false, size: 34))
            .disabled(pageIndex == 0)
            .accessibilityLabel("Previous page")

            Text("\(pageIndex + 1) / \(manifest.pageIds.count)")
                .font(Modernist.font(11, .medium).monospacedDigit())
                .foregroundStyle(Modernist.neutral700)

            Button {
                openPage(at: pageIndex + 1)
            } label: {
                Image(systemName: "chevron.right").font(.system(size: 15, weight: .semibold))
            }
            .buttonStyle(RailButtonStyle(selected: false, size: 34))
            .disabled(pageIndex >= manifest.pageIds.count - 1)
            .accessibilityLabel("Next page")

            Button {
                addPage()
            } label: {
                Image(systemName: "plus").font(.system(size: 16, weight: .semibold))
            }
            .buttonStyle(RailButtonStyle(selected: false, size: 34))
            .accessibilityLabel("Add page")
        }
    }

    private var optionsMenu: some View {
        Menu {
            Menu {
                Picker("Paper", selection: paperBinding) {
                    ForEach(NativeTemplate.builtIn, id: \.name) { template in
                        Label(template.displayName, systemImage: template.symbolName)
                            .tag(template)
                    }
                }
            } label: {
                Label("Paper", systemImage: "doc.plaintext")
            }
            .disabled(!canChangeTemplate)

            Toggle(isOn: $handwriting.config.fingerDrawing) {
                Label("Finger draws", systemImage: "hand.point.up.left")
            }
            Toggle(isOn: $handwriting.config.scrollLocked) {
                Label("Lock scrolling", systemImage: "lock")
            }
            Toggle(isOn: $handwriting.config.showsToolPicker) {
                Label("Tool palette", systemImage: "paintpalette")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 34, height: 34)
                .foregroundStyle(Modernist.ink)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Options")
        .accessibilityIdentifier("editor.options")
    }

    /// The page plus the paper it is drawn on, captioned with which paper that is — the
    /// same five native templates the BOOX renders, so the caption is also a promise.
    private var canvasArea: some View {
        ZStack(alignment: .bottomTrailing) {
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
                    template: pageTemplate,
                    drawing: $drawing,
                    config: handwriting.config,
                    toolSelection: toolSelection,
                    undoController: undoController,
                    scrollState: scrollState,
                    onChanged: scheduleSave)

                if canChangeTemplate {
                    Kicker("\(pageTemplate.displayName) · native", color: Modernist.neutral600)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .allowsHitTesting(false)
                }
            }
        }
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
        if let newPage = try? store.addPage(
            to: notebookId, fallbackTemplate: handwriting.config.defaultTemplate)
        {
            open(pageId: newPage.id)
        }
    }

    private var paperBinding: Binding<NativeTemplate> {
        Binding(get: { pageTemplate }, set: { setTemplate($0) })
    }

    /// Writes the template into the page file (`backgroundType: "native"`), which is what
    /// the BOOX reads back after a sync.
    private func setTemplate(_ template: NativeTemplate) {
        guard var page, canChangeTemplate else { return }
        let fields = TemplateApplication.pageFields(for: .native(template))
        guard fields.background != page.background || fields.backgroundType != page.backgroundType
        else { return }
        page.background = fields.background
        page.backgroundType = fields.backgroundType
        self.page = page
        dirty = true
        saveNow()
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
        // `page.strokes` is the set we last loaded or wrote, so identity chains forward across
        // repeated saves: an untouched stroke keeps its id and its exact bytes.
        page.strokes = PencilKitBridge.strokeDTOs(from: drawing, source: page.strokes)
        page.scroll = scroll
        self.page = page
        do {
            try store.savePage(page)
            dirty = false
        } catch {
            // Leave `dirty` set so the next flush retries. Clearing it on a failed write — which
            // is what `try?` did — silently discarded the strokes that failed to land.
            saveError = String(describing: error)
        }
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
    /// Native paper drawn behind the ink (`.blank` for PDF-backed pages).
    var template: NativeTemplate = .blank
    @Binding var drawing: PKDrawing
    var config = HandwritingConfig()
    /// The docked rail's choice of tool and ink. Authoritative: a tool picked anywhere
    /// else is mirrored back onto it rather than competing with it.
    var toolSelection: ToolSelection = ToolSelection()
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
        canvas.isAccessibilityElement = true
        canvas.accessibilityIdentifier = "editor.canvas"
        canvas.accessibilityValue = "strokes:0"
        canvas.contentSize = CGSize(width: Self.pageWidth, height: Self.minimumHeight)
        canvas.minimumZoomScale = 0.25
        canvas.maximumZoomScale = 3

        undoController.attach(container.pageUndoManager)

        let picker = context.coordinator.toolPicker
        // Seed canvas and picker from the rail before the observers are attached, so this
        // does not read back as a user-driven tool change. PKToolPicker otherwise persists
        // whatever was last selected app-wide, which the rail would then be lying about.
        var initialTool = toolSelection.pkTool
        if CommandLine.arguments.contains("--uitest-select-eraser") {
            // The tool picker is system UI a UI test cannot reliably drive; erasing is
            // reached by relaunching with this argument instead.
            initialTool = PKEraserTool(.bitmap)
        } else if CommandLine.arguments.contains("--uitest-reset-tool") {
            // A leftover eraser makes drawing tests silently no-op; tests opt into a
            // known pen rather than inheriting one.
            initialTool = PKInkingTool(.pen, color: .black, width: 5)
        }
        canvas.tool = initialTool
        picker.selectedTool = initialTool
        context.coordinator.toolSelection = toolSelection
        // Freezes the rail's current revision as already-applied, so the first update does
        // not stomp the tool we just set (which matters for the eraser test hook).
        context.coordinator.markToolApplied()
        picker.addObserver(canvas)
        picker.addObserver(context.coordinator)
        context.coordinator.apply(config, to: container)
        canvas.becomeFirstResponder()
        return container
    }

    func updateUIView(_ container: CanvasContainerView, context: Context) {
        let canvas = container.canvas
        context.coordinator.apply(config, to: container)
        context.coordinator.toolSelection = toolSelection
        context.coordinator.applyToolIfNeeded()
        container.setTemplate(template)
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

    final class Coordinator: NSObject, PKCanvasViewDelegate, PKToolPickerObserver,
        UIPencilInteractionDelegate
    {
        let parent: EditorCanvasView
        let toolPicker = PKToolPicker()
        var programmaticUpdate = false
        var loadedPageId: String?
        weak var container: CanvasContainerView?
        var toolSelection: ToolSelection?
        /// Last rail revision pushed onto the canvas. `-1` means "nothing applied yet".
        private var appliedToolRevision = -1

        private var config = HandwritingConfig()
        private var didApplyConfig = false
        /// The tool selected before the current one, for the "previous tool" and
        /// eraser-toggle pencil gestures.
        private var previousTool: PKTool?
        private let pencilInteraction = UIPencilInteraction()
        /// Session-local override of the tool palette (the "show/hide" pencil gesture);
        /// nil means "follow the setting".
        private var toolPickerOverride: Bool?

        /// Pushes the handwriting preferences onto the canvas. Called on creation and on
        /// every SwiftUI update; every step is idempotent and none of them touch
        /// `canvas.drawing` (which would cancel an in-flight stroke).
        func apply(_ newConfig: HandwritingConfig, to container: CanvasContainerView) {
            guard newConfig != config || !didApplyConfig else { return }
            config = newConfig
            didApplyConfig = true
            let canvas = container.canvas

            canvas.drawingPolicy = config.fingerDrawing ? .anyInput : .pencilOnly
            canvas.isScrollEnabled = !config.scrollLocked
            container.fitWidthOnOpen = config.zoomOnOpen == .fitWidth

            let showsPicker = toolPickerOverride ?? config.showsToolPicker
            toolPicker.setVisible(showsPicker, forFirstResponder: canvas)

            // Only claim the pencil gestures when the user asked for something other than
            // the system behaviour; otherwise leave them to PencilKit.
            let wantsPencilGestures =
                config.doubleTapAction != .system || config.squeezeAction != .system
            if wantsPencilGestures {
                pencilInteraction.delegate = self
                if pencilInteraction.view !== container {
                    container.addInteraction(pencilInteraction)
                }
            } else if pencilInteraction.view != nil {
                container.removeInteraction(pencilInteraction)
                pencilInteraction.delegate = nil
            }
        }

        // MARK: - Tool rail

        /// Pushes the rail's tool onto the canvas, once per rail tap. Keyed on the rail's
        /// revision rather than on the tool: `PKTool` is not equatable, and re-assigning an
        /// equal tool on every SwiftUI render would cancel in-flight strokes.
        func applyToolIfNeeded() {
            guard let toolSelection, toolSelection.revision != appliedToolRevision else { return }
            appliedToolRevision = toolSelection.revision
            select(toolSelection.pkTool)
        }

        /// Marks the rail's current revision as applied without touching the canvas, for
        /// when something else has already set the tool it asks for.
        func markToolApplied() {
            appliedToolRevision = toolSelection?.revision ?? 0
        }

        /// Applies a tool chosen outside the rail and mirrors it back, so the rail always
        /// shows what the canvas is actually holding. `adopt` deliberately does not bump
        /// the rail's revision, so this cannot bounce back through `applyToolIfNeeded`.
        private func selectFromOutsideTheRail(_ tool: PKTool) {
            toolSelection?.adopt(tool)
            select(tool)
        }

        // MARK: - Apple Pencil gestures

        func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
            perform(config.doubleTapAction, fallback: Self.systemTapAction())
        }

        @available(iOS 17.5, *)
        func pencilInteraction(
            _ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap
        ) {
            perform(config.doubleTapAction, fallback: Self.systemTapAction())
        }

        @available(iOS 17.5, *)
        func pencilInteraction(
            _ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze
        ) {
            guard squeeze.phase == .ended else { return }
            perform(config.squeezeAction, fallback: Self.systemSqueezeAction())
        }

        /// Maps the system-wide Settings › Apple Pencil preference onto our action set, used
        /// when only one of the two gestures is customised and the other says "System".
        private static func action(for preference: UIPencilPreferredAction) -> PencilAction {
            switch preference {
            case .switchEraser: .eraser
            case .switchPrevious: .previousTool
            case .showColorPalette, .showInkAttributes: .toggleToolPicker
            default: .ignore
            }
        }

        private static func systemTapAction() -> PencilAction {
            action(for: UIPencilInteraction.preferredTapAction)
        }

        private static func systemSqueezeAction() -> PencilAction {
            guard #available(iOS 17.5, *) else { return .ignore }
            return action(for: UIPencilInteraction.preferredSqueezeAction)
        }

        private func perform(_ action: PencilAction, fallback: @autoclosure () -> PencilAction) {
            switch action == .system ? fallback() : action {
            case .system, .ignore:
                break
            case .eraser:
                if toolPicker.selectedTool is PKEraserTool {
                    selectFromOutsideTheRail(
                        previousTool ?? toolSelection?.pkTool
                            ?? PKInkingTool(.pen, color: .black, width: 5))
                } else {
                    selectFromOutsideTheRail(PKEraserTool(.bitmap))
                }
            case .previousTool:
                if let previousTool { selectFromOutsideTheRail(previousTool) }
            case .undo:
                container?.pageUndoManager.undo()
            case .toggleToolPicker:
                guard let canvas = container?.canvas else { return }
                let showing = toolPickerOverride ?? config.showsToolPicker
                toolPickerOverride = !showing
                toolPicker.setVisible(!showing, forFirstResponder: canvas)
            }
        }

        private func select(_ tool: PKTool) {
            noteSelection(tool)
            isProgrammaticToolChange = true
            toolPicker.selectedTool = tool
            container?.canvas.tool = tool
            isProgrammaticToolChange = false
        }

        private func noteSelection(_ tool: PKTool) {
            previousTool = currentTool
            currentTool = tool
        }

        // MARK: - PKToolPickerObserver

        func toolPickerSelectedToolDidChange(_ toolPicker: PKToolPicker) {
            // Skipped for our own switches: `select` has already done the bookkeeping, and
            // running it twice would make "previous tool" the current one.
            guard !isProgrammaticToolChange else { return }
            noteSelection(toolPicker.selectedTool)
            // The system palette is still available behind a setting; when it is used, the
            // rail follows it rather than the two disagreeing about what is selected.
            toolSelection?.adopt(toolPicker.selectedTool)
        }

        private var currentTool: PKTool?
        private var isProgrammaticToolChange = false

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            container?.updateContentGeometry()
            parent.scrollState.pageY =
                scrollView.contentOffset.y / max(scrollView.zoomScale, 0.01)
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            container?.canvasZoomDidChange()
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
