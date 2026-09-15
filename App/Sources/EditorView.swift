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
    var initialPageId: String?
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
                if model.pageId == nil { model.openInitialPage(preferredPageId: initialPageId) }
            }
            .focusedSceneValue(\.editorMenuActions,
                showingPageOverview || model.saveError != nil || actionError != nil ? nil : EditorMenuActions(
                    pages: showPages,
                    close: { model.close() }))
            // Leaving the text tool ends the session. Watched here rather than in the canvas's
            // update pass so the model is written outside the render.
            .onChange(of: toolSelection.kind) { _, kind in
                if kind != .text { commitOpenTextBox() }
            }
            .onDisappear {
                commitOpenTextBox()
                model.saveNow()
            }
            // Leaving the app does not pop the editor, so the debounced save has to be flushed
            // here too — otherwise switching apps or locking the iPad within two seconds of the
            // last stroke loses it.
            // Returning to the app retries a flush that failed while leaving it.
            .onChange(of: scenePhase) { _, _ in model.saveNow() }
            .alert(
                "Couldn’t save this page", isPresented: .constant(model.saveError != nil),
                presenting: model.saveError
            ) { _ in
                Button("Retry") { model.saveNow() }
                Button("Keep editing", role: .cancel) { model.saveError = nil }
            } message: { error in
                Text("Your strokes are still on this page. Save successfully before switching pages or closing this notebook. \(error)")
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
                model.close()
            } label: {
                Image(systemName: "chevron.backward")
                    .font(.system(size: 17, weight: .semibold))
            }
            .buttonStyle(RailButtonStyle(selected: false, size: Modernist.hitCompact))
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
            .buttonStyle(RailButtonStyle(selected: false, size: Modernist.hitCompact))
            .disabled(pageIndex == 0)
            .keyboardShortcut("[", modifiers: .command)
            // A bracket typed into a text box is a bracket, not a page turn. On the Mac the
            // shortcut fires even while a text view holds the keyboard, so it is taken away for
            // as long as one does.
            .disabled(model.editingBlockID != nil)
            .accessibilityLabel("Previous page")

            // The count is the way into the overview, not a label beside it: it is already the
            // thing you look at to ask "where am I in this notebook", and a notebook of forty
            // pages cannot be crossed with the two chevrons either side of it.
            Button(action: showPages) {
                Text("\(pageIndex + 1) / \(manifest.pageIds.count)")
                    .font(Modernist.font(11, .medium).monospacedDigit())
                    .foregroundStyle(Modernist.neutral700)
                    .padding(.horizontal, 6)
                    .frame(minWidth: Modernist.hitCompact, minHeight: Modernist.hitCompact)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("All pages")
            .accessibilityValue("Page \(pageIndex + 1) of \(manifest.pageIds.count)")
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
            .buttonStyle(RailButtonStyle(selected: false, size: Modernist.hitCompact))
            // The keyboard's page turns. On the Mac they are the only way to move between pages
            // besides these buttons: a mouse wheel has no drag phase, so scrolling past the end
            // of a page — the touch gesture that appends and enters pages — never fires there,
            // and relaxing that guard would let momentum walk the whole notebook.
            .keyboardShortcut("]", modifiers: .command)
            .disabled(model.editingBlockID != nil)
            .accessibilityLabel(
                pageIndex >= manifest.pageIds.count - 1 ? "New page" : "Next page")

            Button {
                addPage()
            } label: {
                Image(systemName: "plus").font(.system(size: 16, weight: .semibold))
            }
            .buttonStyle(RailButtonStyle(selected: false, size: Modernist.hitCompact))
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(model.editingBlockID != nil)
            .accessibilityLabel("Add page")
        }
    }

    /// Writes back whatever box is open. Every route off this page calls it first: a box left
    /// open is a text view floating over a page it no longer belongs to, and its typing would be
    /// committed onto whatever page arrived next.
    private func commitOpenTextBox() {
        guard let finished = viewport.endTextEditing() else { return }
        model.commitEditing(finished.block, text: finished.text)
    }

    private func showPages() {
        commitOpenTextBox()
        guard model.saveNow() else { return }
        showingPageOverview = true
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

            Picker("Page navigation", selection: $handwriting.config.pageNavigation) {
                ForEach(PageNavigation.allCases) { navigation in
                    Text(navigation.title).tag(navigation)
                }
            }

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
                Label(
                    handwriting.config.pageNavigation.isPaged ? "Fit whole page" : "Fit page width",
                    systemImage: handwriting.config.pageNavigation.isPaged
                        ? "arrow.up.left.and.arrow.down.right" : "arrow.left.and.right")
            }
            .accessibilityIdentifier("editor.fitWidth")
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 16, weight: .semibold))
                .frame(width: Modernist.hitCompact, height: Modernist.hitCompact)
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
                    pageScroll: model.openScroll,
                    template: pageTemplate,
                    pageSize: model.page?.pageSize ?? .legacyUndeclared,
                    textBlocks: model.textBlocks,
                    nextPage: model.nextPagePreview,
                    hasNextPage: model.nextPageId != nil,
                    drawing: $model.drawing,
                    config: handwriting.config,
                    toolSelection: toolSelection,
                    undoController: undoController,
                    liveState: model.liveState,
                    viewport: viewport,
                    turnPage: turnPage,
                    crossSeam: crossSeam,
                    appendPage: appendPageWithoutLeaving,
                    fileInkBelowTheSeam: model.fileInkBelowTheSeam,
                    makeTextBlock: { model.newTextBlock(at: $0).map { block in
                        model.beginEditing(block)
                        return block
                    } },
                    commitTextBlock: { model.commitEditing($0, text: $1) },
                    moveTextBlock: { model.moveTextBlock(id: $0, to: $1) },
                    resizeTextBlock: { model.resizeTextBlock(id: $0, width: $1) },
                    currentTextBlock: { model.textBlock(id: $0) },
                    restoreTextBlock: { model.restoreTextBlock(id: $0, to: $1) },
                    onChanged: model.scheduleSave,
                    onIdle: model.foldInRemoteInk)

                if canChangeTemplate {
                    Kicker("\(pageTemplate.displayName) paper", color: Modernist.neutral600)
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
        commitOpenTextBox()
        model.open(pageId: manifest.pageIds[index])
    }

    /// Crossing the boundary between two pages by scrolling, in continuous mode.
    ///
    /// Not a page turn: nothing on screen moves. Forward, the scroll has already carried the
    /// view past this page's end and filled the screen with the next page's preview, so the
    /// real page opens at the position that draws the identical picture. Backward, the previous
    /// page opens at *its* end, which is the position that draws this page under its seam.
    ///
    /// Forward at the end of the notebook makes the next page first — the same rule as running
    /// off the end anywhere else, which is what keeps "scroll to keep writing" true on the last
    /// page too.
    /// - Returns: whether a page was actually entered. The caller latches on this, so a
    ///   crossing that could not happen — pulling back at the very first page — does not leave
    ///   the latch set with no page load coming to clear it, which silently killed every
    ///   subsequent crossing for the rest of the session.
    private func crossSeam(_ direction: Int, _ carried: CGFloat) -> Bool {
        commitOpenTextBox()
        if direction > 0 {
            return model.enterNextPageAcrossSeam(carrying: carried)
        }
        return model.enterPreviousPageAtItsEnd()
    }

    /// Grows the notebook by a page without going to it.
    ///
    /// What scrolling off the end of the last page does under continuous scrolling. The page is
    /// *appended*, not opened: the seam and the new blank sheet appear below the one being
    /// written on and the same scroll carries straight onto them, which is what "one long
    /// surface" has to mean at the end of the notebook too. Entering it is then the ordinary
    /// seam crossing, made by scrolling on. (Xournal++ appends on scroll-to-end the same way,
    /// deliberately without jumping; the BOOX app does this as of 0.44.0.)
    ///
    /// Failure is reported through the same alert a failed save uses — a disk that is full
    /// produces no page, and silence would read as the scroll simply not working.
    private func appendPageWithoutLeaving() {
        commitOpenTextBox()
        guard model.nextPageId == nil else { return }
        guard model.saveNow() else { return }
        do {
            _ = try store.addPage(
                to: notebookId, fallbackTemplate: handwriting.config.defaultTemplate)
        } catch {
            actionError = LibraryActionError(action: "Adding a page", underlying: error)
        }
    }

    /// Adding a page is the one editor action that used to be able to fail in silence: a disk that
    /// is full, or a notebook whose manifest cannot be rewritten, produced nothing at all — no
    /// page, no message — and the only reading available to the user was that the button had
    /// missed. It reports through the same alert a failed save does, because it is the same kind
    /// of news.
    private func addPage() {
        commitOpenTextBox()
        guard model.saveNow() else { return }
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
        // Paper is chosen for the notebook, not for the sheet: the pages added after this one
        // start on it too — here and on the BOOX, which reads the same manifest field. Reported
        // through the same alert a failed page add uses, because a choice that silently did not
        // stick reads as the picker having missed.
        guard PageBackground(fields: fields).canBeNotebookDefault else { return }
        do {
            try store.setNotebookDefaultBackground(notebookId, to: fields)
        } catch {
            actionError = LibraryActionError(action: "Changing the paper", underlying: error)
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

    /// Closes any open text box and hands back what was typed, for the caller to commit.
    ///
    /// Here rather than on the coordinator because the callers are SwiftUI actions — a rail tap,
    /// a page turn, the view going away — and the coordinator is not reachable from them. It also
    /// keeps the model write out of `updateUIView`, where publishing a change mid-render is
    /// exactly the thing SwiftUI complains about.
    func endTextEditing() -> (block: CouchBlock, text: String)? { container?.endTextEditing() }
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
    /// The page's text boxes, drawn below the ink.
    var textBlocks: [CouchBlock] = []
    /// The unzoomed page-space y offset the page opens at — its persisted position, or the
    /// one the scroll carried across a seam.
    var pageScroll: CGFloat = 0
    /// Native paper drawn behind the ink (`.blank` for PDF-backed pages).
    var template: NativeTemplate = .blank
    /// The sheet this page is laid out on, in page units — the page's own declaration, or
    /// `PageSize.legacyUndeclared` for one written before page sizes existed. Every page
    /// resolves to a real sheet: the fallback is the same constant `PageSplit` divides
    /// undeclared pages by (and the Android app now lays them out at), so an undeclared page
    /// is one ordinary bounded page, not an endless canvas.
    var pageSize: PageSize = .legacyUndeclared
    /// The top of the page after this one, drawn below the seam under continuous scrolling.
    var nextPage: NextPagePreview?
    /// Whether a page exists below this one at all — known synchronously, unlike `nextPage`,
    /// which is rendered off the main actor. This is what sizes the scroll.
    var hasNextPage = false
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
    /// Scrolling has carried the view across the boundary between two pages: direction, and the
    /// scroll to carry onto the page being entered so nothing on screen moves.
    var crossSeam: (Int, CGFloat) -> Bool = { _, _ in false }
    /// Scrolling has run off the end of the last page: grow the notebook, without leaving.
    var appendPage: () -> Void = {}
    /// Hands ink drawn below the seam to the page under it, returning what is left on this one.
    var fileInkBelowTheSeam: (PKDrawing, CGFloat) -> PKDrawing? = { _, _ in nil }
    /// Asked to put a new box where the user tapped; answered with the box to type into, or
    /// nil if there is no page to put one on.
    var makeTextBlock: (CGPoint) -> CouchBlock? = { _ in nil }
    /// Typing finished: the box, and what was in it. An empty one is a delete.
    var commitTextBlock: (CouchBlock, String) -> Void = { _, _ in }
    var moveTextBlock: (String, CGPoint) -> Void = { _, _ in }
    var resizeTextBlock: (String, CGFloat) -> Void = { _, _ in }
    /// The box with this id as the page holds it now — read at undo time, so the redo step is
    /// built from what is actually there rather than from a guess made before the edit landed.
    var currentTextBlock: (String) -> CouchBlock? = { _ in nil }
    /// Puts a box back the way it was, or removes it if it was not there.
    var restoreTextBlock: (String, CouchBlock?) -> Void = { _, _ in }
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
        container.sheetHeight = CGFloat(pageSize.height)
        container.fitsWholePage = config.pageNavigation.isPaged
        container.hasNextPage = !config.pageNavigation.isPaged && hasNextPage
        container.nextPage = config.pageNavigation.isPaged ? nil : nextPage
        container.setContentExtent(
            pageSize: pageSize, ink: drawing.bounds,
            minimumHeight: Self.minimumHeight(for: pageSize))
        canvas.minimumZoomScale = 0.25
        canvas.maximumZoomScale = 3

        undoController.attach(container.pageUndoManager)
        viewport.attach(container)

        // Seed the canvas from the rail: the rail is the only tool UI, so whatever it shows
        // is what the canvas must be holding from the first stroke on.
        // Nil only for the text tool, which the rail never opens on — but the canvas has to
        // hold something, and a pen is what every other route into this view assumes.
        var initialTool = toolSelection.pkTool
            ?? PKInkingTool(.pen, color: toolSelection.ink.uiColor, width: 5)
        if CommandLine.arguments.contains("--uitest-select-eraser") {
            // Erasing is reached by relaunching with this argument rather than by tapping
            // the rail, so the test starts from a known tool without synthesising a tap.
            initialTool = PKEraserTool(.bitmap)
        } else if CommandLine.arguments.contains("--uitest-reset-tool") {
            // A leftover eraser makes drawing tests silently no-op; tests opt into a
            // known pen rather than inheriting one.
            initialTool = PKInkingTool(.pen, color: .black, width: 5)
        } else if CommandLine.arguments.contains("--uitest-select-text") {
            // Typing is reached the same way erasing is: relaunched into, so the test starts
            // from a known tool without hunting for a rail button.
            toolSelection.select(.text)
        }
        canvas.tool = initialTool
        context.coordinator.toolSelection = toolSelection
        // Freezes the rail's current revision as already-applied, so the first update does
        // not stomp the tool we just set (which matters for the eraser test hook).
        context.coordinator.seed(initialTool)
        context.coordinator.apply(config, to: container)
        container.textDelegate = context.coordinator
        container.textEditor.delegate = context.coordinator
        container.textEditor.installAccessoryBar()
        container.textEditor.onDone = { [weak coordinator = context.coordinator] in
            coordinator?.endTextEditing()
        }
        container.textEditor.onDelete = { [weak coordinator = context.coordinator] in
            coordinator?.deleteEditingTextBlock()
        }
        canvas.becomeFirstResponder()
        return container
    }

    func updateUIView(_ container: CanvasContainerView, context: Context) {
        // Before anything reads it: the coordinator's copy is what every delegate callback sees.
        context.coordinator.parent = self
        let canvas = container.canvas
        context.coordinator.apply(config, to: container)
        context.coordinator.toolSelection = toolSelection
        context.coordinator.applyToolIfNeeded()
        container.setTemplate(template)
        // Before the reload guard below: the sheet arrives with the page, which is later than the
        // canvas was created, and on a page switch it can differ from the page just closed.
        container.setPageWidth(CGFloat(pageSize.width))
        container.sheetHeight = CGFloat(pageSize.height)
        container.fitsWholePage = config.pageNavigation.isPaged
        // What the seam shows, and whether there is anything under it. Set before the extent
        // below, which is sized from `hasNextPage`.
        container.hasNextPage = !config.pageNavigation.isPaged && hasNextPage
        container.nextPage = config.pageNavigation.isPaged ? nil : nextPage
        // Background and images may arrive/change without a page switch; both setters are
        // idempotent and never touch canvas.drawing.
        container.setBackground(background)
        container.setImages(images)
        container.setTextBlocks(textBlocks)
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
        // Restore the scroll position this page opens at.
        container.setInitialScroll(pageY: pageScroll)
        // The page asked for by a seam crossing has arrived; further scrolling may ask again.
        context.coordinator.noteSeamCrossingLanded()
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, PKCanvasViewDelegate, UIPencilInteractionDelegate,
        UITextViewDelegate, CanvasContainerTextDelegate
    {
        /// The current value of the representable struct.
        ///
        /// A `var`, reassigned on every `updateUIView`. SwiftUI creates the coordinator once and
        /// never refreshes what it captured, so a `let` here is frozen at the value the *first*
        /// body evaluation produced — which happens before `.onAppear` opens a page at all. Any
        /// delegate callback reading `parent.pageSize` through that copy was measuring the scroll
        /// against `PageSize.legacyUndeclared` on every page of every notebook.
        var parent: EditorCanvasView
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
            let previousNavigation = didApplyConfig ? config.pageNavigation : nil
            config = newConfig
            didApplyConfig = true
            let canvas = container.canvas

            // Pencil-only would make the canvas inert on the Mac, where nothing is a pencil:
            // the trackpad and the mouse are the only input, and both must draw.
            canvas.drawingPolicy = config.fingerDrawing || Platform.isMac ? .anyInput : .pencilOnly
            canvas.isScrollEnabled = !config.scrollLocked
            // Bounce carries the intentional pull past a real sheet's edge. It is the signal for
            // entering the next page, or making one when this is the final page.
            canvas.alwaysBounceVertical = !config.scrollLocked
            canvas.alwaysBounceHorizontal = false
            container.keepsFitToWidth = config.pageFit == .fitWidth
            container.fitsWholePage = config.pageNavigation.isPaged
            // A navigation-mode change must re-fit the page currently on screen. Otherwise a
            // notebook would keep the previous mode's geometry until it was closed and reopened.
            if config.pageFit == .fitWidth,
               (previousFit != config.pageFit || previousNavigation != config.pageNavigation) {
                container.fitToWidth()
            }

            // Only claim the pencil gestures when the user asked for something other than
            // the system behaviour; otherwise leave them to PencilKit.
            let wantsPencilGestures = !Platform.isMac
                && (config.doubleTapAction != .system || config.squeezeAction != .system)
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
            // The session itself is closed by `EditorView`, watching the same selection — this
            // runs inside a SwiftUI update, where writing the typed text back to the model would
            // be publishing a change mid-render.
            container?.isTextMode = toolSelection.isTextTool
            // Nil is the text tool, which is not a PencilKit tool at all. The canvas keeps
            // whatever it was holding; its drawing gesture is off while text mode is on, so
            // what that is cannot matter until the rail comes back to a tool that draws.
            if let tool = toolSelection.pkTool { select(tool) }
        }

        // MARK: - Text boxes

        /// Commits whatever box is open, if any. Safe to call when none is.
        ///
        /// Every route out of a text box runs through here — a tap elsewhere, a tool change, a
        /// page turn, the Done key — because a box left open is a text view floating over a page
        /// it no longer belongs to.
        func endTextEditing() {
            guard let container, let finished = container.endTextEditing() else { return }
            let previous = parent.currentTextBlock(finished.block.id)
            parent.commitTextBlock(finished.block, finished.text)
            registerTextUndo(
                id: finished.block.id, previous: previous,
                name: previous == nil ? "Text" : "Edit Text")
        }

        /// Puts one whole edit on the page's undo stack.
        ///
        /// A session, not a keystroke: the text view keeps its own manager for letter-by-letter
        /// undo while a box is open (see `TextBoxEditorView`), and what the rail's button should
        /// reach for afterwards is the paragraph, the move, the deletion — the same granularity a
        /// stroke has.
        private func registerTextUndo(id: String, previous: CouchBlock?, name: String) {
            guard let manager = container?.pageUndoManager else { return }
            manager.registerUndo(withTarget: self) { target in
                // UndoManager calls this on the thread that registered it, which is the main one.
                MainActor.assumeIsolated {
                    let undone = target.parent.currentTextBlock(id)
                    target.parent.restoreTextBlock(id, previous)
                    // Registering from inside an undo is what makes it redoable, and the same
                    // call serves both directions for ever after.
                    target.registerTextUndo(id: id, previous: undone, name: name)
                }
            }
            manager.setActionName(name)
        }

        func canvasContainer(
            _ container: CanvasContainerView, didTapEmptyPageAt point: CGPoint
        ) {
            guard let block = parent.makeTextBlock(point) else { return }
            container.beginTextEditing(block, source: "")
        }

        func canvasContainer(_ container: CanvasContainerView, didTapTextBlock id: String) {
            guard let block = container.textBlocks.first(where: { $0.id == id }) else { return }
            // The source, not the rendered text: while a box is open it *is* markdown, and a
            // heading whose hashes vanished the moment it was tapped could never be unmade.
            container.beginTextEditing(block, source: block.text ?? "")
        }

        func canvasContainer(
            _ container: CanvasContainerView, didMoveTextBlock id: String, to point: CGPoint
        ) {
            let previous = parent.currentTextBlock(id)
            parent.moveTextBlock(id, point)
            registerTextUndo(id: id, previous: previous, name: "Move Text")
        }

        func canvasContainer(
            _ container: CanvasContainerView, didResizeTextBlock id: String, to width: CGFloat
        ) {
            let previous = parent.currentTextBlock(id)
            parent.resizeTextBlock(id, width)
            registerTextUndo(id: id, previous: previous, name: "Resize Text")
        }

        func canvasContainerDidTapOutsideEditor(_ container: CanvasContainerView) {
            endTextEditing()
        }

        /// Throws the open box away. Routed through the empty commit rather than a separate
        /// delete, so "a box with nothing in it does not exist" stays one rule.
        func deleteEditingTextBlock() {
            container?.textEditor.text = ""
            endTextEditing()
        }

        // MARK: UITextViewDelegate

        func textViewDidChange(_ textView: UITextView) {
            // The box grows downward as it fills, so the caret cannot run out of the bottom of a
            // box whose committed height is a line old.
            container?.textEditorContentChanged()
            scrollEditorIntoView()
        }

        func textView(
            _ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String
        ) -> Bool {
            true
        }

        /// Keeps the caret above the keyboard by scrolling the page, not by moving the box: the
        /// box is at a place on the paper the user chose, and sliding it up would rewrite that.
        private func scrollEditorIntoView() {
            guard let container, !container.textEditor.isHidden else { return }
            let canvas = container.canvas
            // `keyboardLayoutGuide` tracks the keyboard on iPad and collapses to nothing on the
            // Mac, where there is none — so the same arithmetic serves both.
            let visible = container.bounds.height
                - container.keyboardLayoutGuide.layoutFrame.height
            let caret = container.textEditor.frame.maxY
            guard caret > visible, visible > 0 else { return }
            let extra = (caret - visible) / max(canvas.zoomScale, 0.01)
            canvas.setContentOffset(
                CGPoint(
                    x: canvas.contentOffset.x,
                    y: canvas.contentOffset.y + extra * canvas.zoomScale),
                animated: true)
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
                    // The rail's own eraser, not a fixed one: a pencil double-tap means
                    // "erase", and which kind of erasing — and how broadly — are choices the
                    // user has already made.
                    selectFromOutsideTheRail(
                        toolSelection?.pkEraserTool ?? PKEraserTool(.bitmap))
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
            commitSeamCrossingIfReached(scrollView)
        }

        /// Whether a seam crossing has been asked for and the page has not arrived yet. Between
        /// the two the scroll is still sitting past the old page's end, so every further tick
        /// would ask again and skip a page. Cleared when the canvas loads the new page.
        private var seamCrossingInFlight = false

        func noteSeamCrossingLanded() { seamCrossingInFlight = false }

        /// One page appended per drag, at most.
        ///
        /// The append is asked for from a scroll callback that runs at display rate, and it is
        /// answered by a disk write. It happens that the store's change notification is posted
        /// synchronously, so `nextPageId` is already set by the time the next callback runs and
        /// the guard there holds — but "a notification is synchronous" is a thin thread to hang
        /// the difference between one new page and thirty on. The Android app latches the same
        /// way (`edgeTurnTaken`), released when the gesture ends.
        private var appendedDuringThisDrag = false

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            appendedDuringThisDrag = false
        }

        /// The switch to the next page, made while scrolling rather than on release.
        ///
        /// Continuous scrolling has no page-turn gesture: the reader simply scrolls, the next
        /// page comes up under the seam, and at the moment the seam reaches the top of the
        /// screen the pages are showing the identical picture — so the swap is invisible and is
        /// made there, not at a threshold or a release. That is what "one long surface" has to
        /// mean; anything read on release is a page turn wearing a scroll's clothes.
        private func commitSeamCrossingIfReached(_ scrollView: UIScrollView) {
            guard let container, !seamCrossingInFlight, !parent.config.pageNavigation.isPaged
            else { return }
            let scale = max(scrollView.zoomScale, 0.01)
            let offsetY = scrollView.contentOffset.y / scale
            // From the container, which `updateUIView` sets from the open page every render.
            let sheetHeight = container.sheetHeight

            if container.seamActive,
               SeamGeometry.shouldEnterNextPage(offsetY: offsetY, sheetHeight: sheetHeight) {
                seamCrossingInFlight = parent.crossSeam(
                    1, SeamGeometry.carriedScroll(offsetY: offsetY, sheetHeight: sheetHeight))
                return
            }
            // The end of the notebook: there is no seam because there is no page below yet.
            // Pulling past the end asks for one, and gets it appended in place — the seam then
            // opens under the same scroll, which crosses it on its own if the finger keeps
            // going. Guarded by the same threshold a page turn used, so an ordinary scroll that
            // merely reaches the bottom does not silently grow the notebook.
            if !container.seamActive, scrollView.isDragging {
                let past = Self.overshoot(
                    offset: scrollView.contentOffset.y,
                    contentLength: scrollView.contentSize.height,
                    boundsLength: scrollView.bounds.height,
                    leadingInset: scrollView.adjustedContentInset.top,
                    trailingInset: scrollView.adjustedContentInset.bottom)
                if past >= Self.pageTurnThreshold, !appendedDuringThisDrag {
                    appendedDuringThisDrag = true
                    parent.appendPage()
                    return
                }
                // Deliberately falls through when the drag is *not* past the bottom. Returning
                // unconditionally here made the backward check below unreachable on the last
                // page of every notebook — the page with no seam, and the one a reader is most
                // often on — so scrolling back was impossible from exactly there.
            }
            // Backwards, and only while the finger is down: released momentum carries the
            // scroll to rest at the top of every page, and entering the previous page on each
            // of those would walk the notebook backwards on its own.
            if scrollView.isDragging,
               SeamGeometry.shouldEnterPreviousPage(
                offsetY: scrollView.contentOffset.y,
                leadingInset: scrollView.adjustedContentInset.top,
                threshold: Self.pageTurnThreshold) {
                seamCrossingInFlight = parent.crossSeam(-1, 0)
            }
        }

        /// Moving to the adjacent physical page by dragging past this one's vertical edge —
        /// **Pagination's** navigation, and only its own.
        ///
        /// Read on release rather than while dragging: a page turn mid-gesture would fire on the
        /// way past a boundary the reader was only scrolling through, and on an e-ink panel every
        /// one of those costs a full refresh. Distance decides it, not velocity — a flick and a
        /// slow deliberate pull should both turn exactly one page.
        ///
        /// Under continuous scrolling there is no such gesture: scrolling *is* the navigation,
        /// and the crossing is committed at the seam while the finger moves. Leaving this live
        /// in both modes gave continuous scrolling two ways to change page — the seam, and a
        /// pull-release that jumped a whole page — which is the exact duplication the Android
        /// side just removed.
        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate _: Bool) {
            guard parent.config.pageNavigation.isPaged else { return }
            let inset = scrollView.adjustedContentInset
            let vertical = Self.overshoot(
                offset: scrollView.contentOffset.y,
                contentLength: scrollView.contentSize.height,
                boundsLength: scrollView.bounds.height,
                leadingInset: inset.top,
                trailingInset: inset.bottom)
            guard abs(vertical) >= Self.pageTurnThreshold else { return }
            parent.turnPage(vertical > 0 ? 1 : -1)
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

        /// How far past the edge counts as asking for the next page. UIScrollView compresses a
        /// finger's travel while rubber-banding, so the old 120pt content-offset threshold needed
        /// an implausibly long pull and made vertical page creation appear broken.
        static let pageTurnThreshold: CGFloat = 48

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
            // At the lift, so a stroke is moved whole and only once it is finished.
            fileAnyInkBelowTheSeam(canvasView)
            parent.onIdle()
        }

        /// Moves ink drawn in the band below the seam onto the page it was drawn on.
        ///
        /// The canvas is the current page's, and it is the live surface over the next page's
        /// preview too — so without this, writing below the seam stored ink under the current
        /// page's own sheet, where nothing that thinks in pages can reach it.
        private func fileAnyInkBelowTheSeam(_ canvasView: PKCanvasView) {
            guard let container, container.seamActive else { return }
            guard let remaining = parent.fileInkBelowTheSeam(
                canvasView.drawing, container.sheetHeight)
            else { return }
            programmaticUpdate = true
            canvasView.drawing = remaining
            programmaticUpdate = false
            parent.drawing = remaining
            canvasView.accessibilityValue = "strokes:\(remaining.strokes.count)"
            parent.onChanged()
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
