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
    /// The ids of the strokes the canvas is currently showing — what was loaded into it, or what
    /// was last exported out of it. Two jobs: it is the baseline `savePage` derives tombstones
    /// from, and it is how "the file holds ink the canvas does not" is decided.
    @State private var canvasStrokeIDs: Set<String> = []
    /// Bumped whenever `drawing` is replaced from outside the canvas, which is the only cue
    /// `EditorCanvasView` has to reload it without a page switch.
    @State private var contentRevision = 0
    /// Sync wrote something and the canvas has not caught up. Survives until it is safe to act on.
    @State private var remoteInkPending = false
    @State private var dirty = false
    @State private var saveTask: Task<Void, Never>?
    @State private var loadError: String?
    @State private var saveError: String?
    @StateObject private var undoController = CanvasUndoController()
    @State private var liveState = CanvasLiveState()
    @State private var viewport = CanvasViewportController()

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
            // The CouchDB pull loop rewrites page files with no regard for what is open, so the
            // editor has to hear about it or it would keep drawing on a stale copy.
            .onReceive(
                NotificationCenter.default.publisher(
                    for: NotebookStore.didApplyRemoteChangesNotification)
            ) { _ in
                remoteInkPending = true
                foldInRemoteInk()
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

            // The way back onto the fit after a pinch. Also switches the preference on, so
            // "fit it now" and "keep it fitted" are the same gesture rather than two. Both
            // steps are needed: the preference alone does nothing when it was already on
            // (which is the pinched-away case this exists for), and the direct fit alone
            // would leave "actual size" selected. `fitToWidth` is idempotent, so the config
            // change reaching the canvas afterwards does not fit a second time.
            Button {
                handwriting.config.pageFit = .fitWidth
                viewport.fitToWidth()
            } label: {
                Label("Fit page width", systemImage: "arrow.left.and.right")
            }
            .accessibilityIdentifier("editor.fitWidth")
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
                    contentRevision: contentRevision,
                    background: pageBackground,
                    images: pageImages,
                    pageScroll: page?.scroll ?? 0,
                    template: pageTemplate,
                    drawing: $drawing,
                    config: handwriting.config,
                    toolSelection: toolSelection,
                    undoController: undoController,
                    liveState: liveState,
                    viewport: viewport,
                    onChanged: scheduleSave,
                    onIdle: foldInRemoteInk)

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
            canvasStrokeIDs = Set(loaded.strokes.map(\.id))
            contentRevision += 1
            // Seed with the persisted offset so a save before any scroll preserves it.
            liveState.pageY = CGFloat(max(loaded.scroll, 0))
            dirty = false
            loadError = nil
        } catch {
            loadError = String(describing: error)
        }
    }

    /// Puts ink sync wrote underneath the editor onto the canvas.
    ///
    /// Never while a stroke is being drawn: replacing `drawing` reloads the canvas, and that
    /// cancels the stroke in flight — losing exactly the kind of ink this exists to protect. The
    /// flag keeps until the pencil lifts, which `onIdle` reports.
    ///
    /// The reconciling itself is `savePage`'s: flushing first leaves the file holding the union of
    /// both copies, so this only has to decide whether the canvas is now out of date and reload.
    private func foldInRemoteInk() {
        guard remoteInkPending, !liveState.isDrawing, let pageId else { return }
        saveNow()
        guard let onDisk = try? store.loadPage(notebookId: notebookId, pageId: pageId) else {
            return  // a torn or missing read is not a reason to drop what is on the canvas
        }
        remoteInkPending = false

        let erased = Set(onDisk.deletedStrokes.map(\.id))
        let arrived = onDisk.strokes.contains { !canvasStrokeIDs.contains($0.id) }
        let erasedElsewhere = canvasStrokeIDs.contains { erased.contains($0) }
        // Most applied documents are some other page, or this page's own echo. Reloading for those
        // would throw away the undo stack for nothing.
        guard arrived || erasedElsewhere else { return }
        open(pageId: pageId)
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
        let scroll = max(0, Int(liveState.pageY.rounded()))
        guard dirty || scroll != page.scroll else { return }
        // What the canvas held going into this save. `savePage` needs it to tell ink the user
        // erased from ink that arrived from the BOOX while this page was open — the file cannot
        // answer that, because sync may have rewritten it since.
        let baseline = canvasStrokeIDs
        // `page.strokes` is the set we last loaded or wrote, so identity chains forward across
        // repeated saves: an untouched stroke keeps its id and its exact bytes.
        page.strokes = PencilKitBridge.strokeDTOs(from: drawing, source: page.strokes)
        page.scroll = scroll
        canvasStrokeIDs = Set(page.strokes.map(\.id))
        self.page = page
        do {
            // Take back what was written, not what was offered: it may carry strokes that landed
            // underneath us, and the next save's tombstones are derived against it.
            self.page = try store.savePage(page, baselineStrokeIDs: baseline)
            dirty = false
        } catch {
            // Leave `dirty` set so the next flush retries. Clearing it on a failed write — which
            // is what `try?` did — silently discarded the strokes that failed to land.
            saveError = String(describing: error)
        }
    }
}

/// Reference box for what the canvas is doing right now, written by the canvas coordinator and
/// read by the editor. A plain class (not observable) on purpose: neither scrolling nor drawing
/// may trigger SwiftUI re-renders.
@MainActor
final class CanvasLiveState {
    /// Current scroll offset in unzoomed page space, read at save time.
    var pageY: CGFloat = 0
    /// Whether a stroke is being drawn. Reloading the canvas while one is in flight cancels it.
    var isDrawing = false
}

/// Lets the SwiftUI chrome drive the canvas's zoom. Attached the same way the undo
/// controller attaches to the page's undo manager, and deliberately not observable: the
/// commands travel one way and nothing here feeds back into a re-render.
@MainActor
final class CanvasViewportController {
    private weak var container: CanvasContainerView?

    func attach(_ container: CanvasContainerView) {
        self.container = container
    }

    func fitToWidth() { container?.fitToWidth() }
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
    /// Bumped by the editor whenever it replaces `drawing` behind the canvas's back — a page
    /// (re)load, including one caused by sync writing ink underneath an open page. The same
    /// reload rules apply as for `pageId`, which is why it is a second key rather than a flag.
    var contentRevision: Int = 0
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
    var liveState: CanvasLiveState = CanvasLiveState()
    var viewport: CanvasViewportController = CanvasViewportController()
    var onChanged: () -> Void
    /// The pencil lifted. The editor uses it to retry work it would not do mid-stroke.
    var onIdle: () -> Void = {}

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
        viewport.attach(container)

        // Seed the canvas from the rail: the rail is the only tool UI, so whatever it shows
        // is what the canvas must be holding from the first stroke on.
        var initialTool = toolSelection.pkTool
        if CommandLine.arguments.contains("--uitest-select-eraser") {
            // Erasing is reached by relaunching with this argument rather than by tapping
            // the rail, so the test starts from a known tool without synthesising a tap.
            initialTool = PKEraserTool(.bitmap)
        } else if CommandLine.arguments.contains("--uitest-reset-tool") {
            // A leftover eraser makes drawing tests silently no-op; tests opt into a
            // known pen rather than inheriting one.
            initialTool = PKInkingTool(.pen, color: .black, width: 5)
        }
        canvas.tool = initialTool
        context.coordinator.toolSelection = toolSelection
        // Freezes the rail's current revision as already-applied, so the first update does
        // not stomp the tool we just set (which matters for the eraser test hook).
        context.coordinator.seed(initialTool)
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
        // Load canvas content ONLY when the editor says the drawing was replaced — a page switch
        // or a reload (found by UI-test bisect): assigning canvas.drawing on ordinary renders
        // cancels in-flight strokes, and PKDrawing equality is identity-like, so a != guard cannot
        // prevent that. The editor only bumps `contentRevision` when no stroke is in flight.
        guard context.coordinator.loadedPageId != pageId
            || context.coordinator.loadedRevision != contentRevision
        else { return }
        context.coordinator.loadedPageId = pageId
        context.coordinator.loadedRevision = contentRevision
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

    final class Coordinator: NSObject, PKCanvasViewDelegate, UIPencilInteractionDelegate {
        let parent: EditorCanvasView
        var programmaticUpdate = false
        var loadedPageId: String?
        /// Last `contentRevision` pushed onto the canvas. `-1` means "nothing loaded yet".
        var loadedRevision = -1
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

        /// Pushes the handwriting preferences onto the canvas. Called on creation and on
        /// every SwiftUI update; every step is idempotent and none of them touch
        /// `canvas.drawing` (which would cancel an in-flight stroke).
        func apply(_ newConfig: HandwritingConfig, to container: CanvasContainerView) {
            guard newConfig != config || !didApplyConfig else { return }
            let previousFit = didApplyConfig ? config.pageFit : nil
            config = newConfig
            didApplyConfig = true
            let canvas = container.canvas

            canvas.drawingPolicy = config.fingerDrawing ? .anyInput : .pencilOnly
            canvas.isScrollEnabled = !config.scrollLocked
            container.keepsFitToWidth = config.pageFit == .fitWidth
            // Switching the preference on acts on the page you are looking at, rather than
            // waiting for the next one to be opened.
            if let previousFit, previousFit != config.pageFit, config.pageFit == .fitWidth {
                container.fitToWidth()
            }

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

        /// Records the tool the canvas was created holding: marks the rail's current
        /// revision as applied so the first update does not re-push it, and gives
        /// "previous tool" something to compare against before any tool change.
        func seed(_ tool: PKTool) {
            currentTool = tool
            appliedToolRevision = toolSelection?.revision ?? 0
        }

        /// Applies a tool chosen outside the rail (an Apple Pencil gesture) and mirrors it
        /// back, so the rail always shows what the canvas is actually holding. `adopt`
        /// deliberately does not bump the rail's revision, so this cannot bounce back
        /// through `applyToolIfNeeded`.
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
            // The palette preferences have nothing to open now that the rail is the only
            // tool UI, and it is always on screen.
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
                if currentTool is PKEraserTool {
                    // Falling back to the rail's ink rather than a fixed black: toggling out
                    // of the eraser before ever using another tool (the canvas can open
                    // holding one) must not silently reset the colour the rail is showing.
                    // `toolSelection?.pkTool` can't stand in here — while the eraser is
                    // selected it returns the eraser, and the toggle would do nothing.
                    let ink = toolSelection?.ink.uiColor ?? .black
                    selectFromOutsideTheRail(
                        previousTool
                            ?? PKInkingTool(.pen, color: ink, width: ToolSelection.Kind.pen.width))
                } else {
                    selectFromOutsideTheRail(PKEraserTool(.bitmap))
                }
            case .previousTool:
                if let previousTool { selectFromOutsideTheRail(previousTool) }
            case .undo:
                container?.pageUndoManager.undo()
            }
        }

        private func select(_ tool: PKTool) {
            noteSelection(tool)
            container?.canvas.tool = tool
        }

        private func noteSelection(_ tool: PKTool) {
            previousTool = currentTool
            currentTool = tool
        }

        private var currentTool: PKTool?

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            container?.updateContentGeometry()
            parent.liveState.pageY =
                scrollView.contentOffset.y / max(scrollView.zoomScale, 0.01)
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            container?.canvasZoomDidChange()
            container?.updateContentGeometry()
            parent.liveState.pageY =
                scrollView.contentOffset.y / max(scrollView.zoomScale, 0.01)
        }

        // Bracketing every stroke: the editor must not reload the canvas between these two, and
        // wants to know the moment it may.
        func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
            parent.liveState.isDrawing = true
        }

        func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
            parent.liveState.isDrawing = false
            parent.onIdle()
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
