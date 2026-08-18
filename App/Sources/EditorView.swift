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
    /// Everything about the open page — what is loaded, what the canvas holds, when it is
    /// saved. A model rather than `@State` so those rules are unit-testable; see its header.
    @StateObject private var model = EditorPageModel()
    @State private var actionError: LibraryActionError?
    @State private var showingPageOverview = false
    @StateObject private var undoController = CanvasUndoController()
    @State private var viewport = CanvasViewportController()

    private var manifest: NotebookManifest? { store.manifest(id: notebookId) }
    private var pageIndex: Int {
        guard let manifest, let pageId = model.pageId else { return 0 }
        return manifest.pageIds.firstIndex(of: pageId) ?? 0
    }

    /// The current page's native paper. PDF- and image-backed pages draw no template:
    /// their background image already carries the paper.
    private var pageTemplate: NativeTemplate {
        guard let page = model.page else { return .blank }
        let background = PageBackground(background: page.background, backgroundType: page.backgroundType)
        guard case .native(let template) = background, template.isDrawable else { return .blank }
        return template
    }

    /// Only native-backed pages can switch template; changing a PDF-backed page would
    /// throw away the link to its PDF (which the BOOX side also relies on).
    private var canChangeTemplate: Bool {
        guard let page = model.page else { return false }
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
            .onAppear {
                model.attach(store: store, notebookId: notebookId)
                // The model asks to close when its notebook vanishes underneath it — deleted
                // locally or by a merge — because an editor over nothing has nothing to show.
                model.requestClose = { onClose?() }
                if model.pageId == nil { model.openInitialPage() }
            }
            .onDisappear { model.saveNow() }
            // Leaving the app does not pop the editor, so the debounced save has to be flushed
            // here too — otherwise switching apps or locking the iPad within two seconds of the
            // last stroke loses it.
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { model.saveNow() }
            }
            .alert(
                "Couldn’t save this page", isPresented: .constant(model.saveError != nil),
                presenting: model.saveError
            ) { _ in
                Button("OK") { model.saveError = nil }
            } message: { error in
                Text("Your strokes are still here and bopa will try again. \(error)")
            }
            .libraryActionAlert($actionError)
            .sheet(isPresented: $showingPageOverview) {
                NavigationStack {
                    NotebookNavigatorView(
                        notebookId: notebookId,
                        currentPageId: model.pageId,
                        openPage: { model.open(pageId: $0) })
                        .environmentObject(store)
                }
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

            // The count is the way into the overview, not a label beside it: it is already the
            // thing you look at to ask "where am I in this notebook", and a notebook of forty
            // pages cannot be crossed with the two chevrons either side of it.
            Button {
                showingPageOverview = true
            } label: {
                Text("\(pageIndex + 1) / \(manifest.pageIds.count)")
                    .font(Modernist.font(11, .medium).monospacedDigit())
                    .foregroundStyle(Modernist.neutral700)
                    .padding(.horizontal, 6)
                    .frame(height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("All pages")
            .accessibilityIdentifier("editor.pages")

            // Never disabled: on the last page it makes the next one. A page ends at its sheet
            // now, so "keep writing" has to be one tap and not a detour through the panel — this
            // is the turn of the page that carrying on down the canvas used to be.
            Button {
                if pageIndex >= manifest.pageIds.count - 1 {
                    addPage()
                } else {
                    openPage(at: pageIndex + 1)
                }
            } label: {
                Image(systemName: "chevron.right").font(.system(size: 15, weight: .semibold))
            }
            .buttonStyle(RailButtonStyle(selected: false, size: 34))
            .accessibilityLabel(
                pageIndex >= manifest.pageIds.count - 1 ? "New page" : "Next page")

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
            if let loadError = model.loadError {
                ContentUnavailableView(
                    "Could not open page", systemImage: "exclamationmark.triangle",
                    description: Text(loadError))
            } else {
                EditorCanvasView(
                    pageId: model.pageId,
                    contentRevision: model.contentRevision,
                    background: model.pageBackground,
                    images: model.pageImages,
                    pageScroll: model.page?.scroll ?? 0,
                    template: pageTemplate,
                    pageSize: model.page?.pageSize ?? .legacyUndeclared,
                    // The *declared* sheet, not the fallback: an undeclared page has no
                    // agreed sheet, so there is no break to promise and none is drawn.
                    declaredSheet: model.page?.declaredPageSize,
                    drawing: $model.drawing,
                    config: handwriting.config,
                    toolSelection: toolSelection,
                    undoController: undoController,
                    liveState: model.liveState,
                    viewport: viewport,
                    turnPage: turnPage,
                    onChanged: model.scheduleSave,
                    onIdle: model.foldInRemoteInk)

                if canChangeTemplate {
                    Kicker("\(pageTemplate.displayName) · native", color: Modernist.neutral600)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    /// Moves one page in [direction], and on the forward edge of the last page makes the next one.
    ///
    /// The same rule as the next-page button, because it is the same act: a page ends at its sheet,
    /// so running off the end of the last one is how you ask for more paper. Backwards it simply
    /// stops — there is nothing before the first page and inventing one would be a surprise.
    private func turnPage(_ direction: Int) {
        guard let manifest else { return }
        let target = pageIndex + direction
        if target >= manifest.pageIds.count {
            addPage()
        } else if target >= 0 {
            openPage(at: target)
        }
    }

    private func openPage(at index: Int) {
        guard let manifest, manifest.pageIds.indices.contains(index) else { return }
        model.saveNow()
        model.open(pageId: manifest.pageIds[index])
    }

    /// Adding a page is the one editor action that used to be able to fail in silence: a disk that
    /// is full, or a notebook whose manifest cannot be rewritten, produced nothing at all — no
    /// page, no message — and the only reading available to the user was that the button had
    /// missed. It reports through the same alert a failed save does, because it is the same kind
    /// of news.
    private func addPage() {
        model.saveNow()
        do {
            let newPage = try store.addPage(
                to: notebookId, fallbackTemplate: handwriting.config.defaultTemplate)
            model.open(pageId: newPage.id)
        } catch {
            actionError = LibraryActionError(action: "Adding a page", underlying: error)
        }
    }

    private var paperBinding: Binding<NativeTemplate> {
        Binding(get: { pageTemplate }, set: { setTemplate($0) })
    }

    /// The *whether* of changing paper lives here — only native-backed pages may — and the
    /// writing lives in the model, which is what the BOOX reads back after a sync.
    private func setTemplate(_ template: NativeTemplate) {
        guard canChangeTemplate else { return }
        let fields = TemplateApplication.pageFields(for: .native(template))
        model.setPaper(background: fields.background, backgroundType: fields.backgroundType)
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
    /// The sheet this page is laid out on, in page units — the page's own declaration, or
    /// `PageSize.legacyUndeclared` for one written before page sizes existed.
    var pageSize: PageSize = .legacyUndeclared
    /// The sheet the page actually *declares*, or nil for one written before page sizes existed.
    /// What the page-break hairlines are drawn at — an undeclared page has no agreed sheet, so
    /// there is no break to promise.
    var declaredSheet: PageSize?
    @Binding var drawing: PKDrawing
    var config = HandwritingConfig()
    /// The docked rail's choice of tool and ink. Authoritative: a tool picked anywhere
    /// else is mirrored back onto it rather than competing with it.
    var toolSelection: ToolSelection = ToolSelection()
    var undoController: CanvasUndoController = CanvasUndoController()
    var liveState: CanvasLiveState = CanvasLiveState()
    var viewport: CanvasViewportController = CanvasViewportController()
    /// Asked for the page before (-1) or after (+1) when a drag carries past the edge of this one.
    /// The editor decides whether there is one, and whether to make it.
    var turnPage: (Int) -> Void = { _ in }
    var onChanged: () -> Void
    /// The pencil lifted. The editor uses it to retry work it would not do mid-stroke.
    var onIdle: () -> Void = {}

    /// The scroll extent a freshly opened page starts with: two sheets, so there is somewhere
    /// to write before the first stroke grows it.
    /// A page opens exactly one sheet tall.
    ///
    /// It used to open at two, which is why there was always another screenful of blank paper
    /// below the one being written on: it read as a second page that never appeared in the
    /// overview, because it was not a page at all — just more of this one. A page is a sheet now,
    /// and the way to keep writing is the next page.
    ///
    /// This is a floor, not a ceiling. `setContentExtent` still covers whatever a page already
    /// holds, so ink written below the sheet before this changed stays reachable until the split
    /// moves it onto a page of its own.
    static func minimumHeight(for pageSize: PageSize) -> CGFloat {
        CGFloat(pageSize.height)
    }

    func makeUIView(context: Context) -> CanvasContainerView {
        let container = CanvasContainerView()
        context.coordinator.container = container
        let canvas = container.canvas
        canvas.delegate = context.coordinator
        canvas.isAccessibilityElement = true
        canvas.accessibilityIdentifier = "editor.canvas"
        canvas.accessibilityValue = "strokes:0"
        container.pageWidth = CGFloat(pageSize.width)
        container.sheetHeight = declaredSheet.map { CGFloat($0.height) } ?? 0
        container.fitsWholePage = config.pageTurn == .horizontal
        container.setContentExtent(
            pageSize: pageSize, ink: drawing.bounds,
            minimumHeight: Self.minimumHeight(for: pageSize))
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
        // Before the reload guard below: the sheet arrives with the page, which is later than the
        // canvas was created, and on a page switch it can differ from the page just closed.
        container.setPageWidth(CGFloat(pageSize.width))
        container.sheetHeight = declaredSheet.map { CGFloat($0.height) } ?? 0
        container.fitsWholePage = config.pageTurn == .horizontal
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
        // Sized from the page being loaded rather than grown into: pages in a notebook can
        // declare different sheets, and the extent left over from the previous page is not this
        // page's.
        container.setContentExtent(
            pageSize: pageSize, ink: drawing.bounds,
            minimumHeight: Self.minimumHeight(for: pageSize))
        // A page switch must not be undoable into the previous page's drawing.
        container.pageUndoManager.removeAllActions()
        undoController.refresh()
        // Restore the persisted scroll position for this page.
        container.setInitialScroll(pageY: CGFloat(pageScroll))
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
            // A page now fits the screen, so there is nothing to scroll and nothing to drag past
            // unless the axis is allowed to give. Bounce is the gesture: it is what lets a page
            // that fits exactly still be pulled off the end, and it is enabled only on the axis
            // the reader turns pages on, so the other one stays still.
            canvas.alwaysBounceVertical = config.pageTurn == .vertical && !config.scrollLocked
            canvas.alwaysBounceHorizontal = config.pageTurn == .horizontal && !config.scrollLocked
            container.keepsFitToWidth = config.pageFit == .fitWidth
            // Sideways turning shows one whole page; downward turning fits the width and lets the
            // page run off the bottom, which is the way you are about to travel.
            container.fitsWholePage = config.pageTurn == .horizontal
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
                            ?? PKInkingTool(
                                .pen, color: ink,
                                width: ToolSelection.Kind.pen.baseWidth
                                    * (toolSelection?.width.scale ?? 1)))
                } else {
                    // The rail's own eraser mode, not a fixed one: a pencil double-tap means
                    // "erase", and which kind of erasing is a choice the user has already made.
                    selectFromOutsideTheRail(
                        toolSelection?.eraserMode.pkEraser ?? PKEraserTool(.bitmap))
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

        /// Turning the page by dragging past the end of this one.
        ///
        /// Read on release rather than while dragging: a page turn mid-gesture would fire on the
        /// way past a boundary the reader was only scrolling through, and on an e-ink panel every
        /// one of those costs a full refresh. Distance decides it, not velocity — a flick and a
        /// slow deliberate pull should both turn exactly one page.
        func scrollViewDidEndDragging(
            _ scrollView: UIScrollView, willDecelerate decelerate: Bool
        ) {
            let inset = scrollView.adjustedContentInset
            let overshoot: CGFloat
            switch parent.config.pageTurn {
            case .vertical:
                overshoot = Self.overshoot(
                    offset: scrollView.contentOffset.y,
                    contentLength: scrollView.contentSize.height,
                    boundsLength: scrollView.bounds.height,
                    leadingInset: inset.top,
                    trailingInset: inset.bottom)
            case .horizontal:
                overshoot = Self.overshoot(
                    offset: scrollView.contentOffset.x,
                    contentLength: scrollView.contentSize.width,
                    boundsLength: scrollView.bounds.width,
                    leadingInset: inset.left,
                    trailingInset: inset.right)
            }
            guard abs(overshoot) >= Self.pageTurnThreshold else { return }
            parent.turnPage(overshoot > 0 ? 1 : -1)
        }

        /// How far a released drag pulled past where the axis can actually rest, signed —
        /// positive past the end, negative before the start, zero anywhere the scroll view would
        /// settle on its own.
        ///
        /// The resting range comes from the insets, not from zero. A page narrower than the
        /// viewport — every 'Side to side' page on a landscape iPad — is centred with contentInset
        /// slack and rests at offset `-slack`. Measured against zero, that rest position read as
        /// a full-slack pull backwards: 'previous page' fired on every release (a guarded no-op
        /// on page 1, so turning simply never worked), and a forward turn needed the slack *plus*
        /// the threshold of rubber-banding.
        static func overshoot(
            offset: CGFloat, contentLength: CGFloat, boundsLength: CGFloat,
            leadingInset: CGFloat, trailingInset: CGFloat
        ) -> CGFloat {
            let minOffset = -leadingInset
            let maxOffset = max(contentLength - boundsLength + trailingInset, minOffset)
            if offset > maxOffset { return offset - maxOffset }
            if offset < minOffset { return offset - minOffset }
            return 0
        }

        /// How far past the edge counts as asking for the next page. Generous enough that the
        /// rubber-banding of an ordinary scroll to the bottom does not turn a page by itself.
        static let pageTurnThreshold: CGFloat = 120

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
            container?.growContent(toCover: drawing.bounds)
        }
    }
}
