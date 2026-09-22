import NotableKit
import PencilKit
import UIKit

/// The editor's ownership of one open page: loading it, holding what the canvas shows, and
/// writing it back. Everything here used to be `@State` inside `EditorView`, which made the
/// rules that decide whether ink survives — the debounced flush, the failed-save retry, the
/// fold-in of ink sync wrote underneath — reachable only by a finger on a simulator. As a model
/// object the same rules are plain methods a unit test can drive.
///
/// `NSObject` for the same reason as `CanvasUndoController`: notifications are observed by
/// selector, which keeps every handler on the main actor without a `Sendable` closure in sight.
@MainActor
final class EditorPageModel: NSObject, ObservableObject {

    // What the view draws. `drawing` is bound straight into the canvas; the rest is read-only
    // to it.
    @Published var drawing = PKDrawing()
    @Published private(set) var pageId: String?
    @Published private(set) var page: PageFile?
    @Published private(set) var pageBackground: UIImage?
    @Published private(set) var pageImages: [PageImage] = []
    /// Bumped whenever `drawing` is replaced from outside the canvas, which is the only cue
    /// `EditorCanvasView` has to reload it without a page switch.
    @Published private(set) var contentRevision = 0
    @Published private(set) var loadError: String?
    @Published var saveError: String?
    /// The page after this one, drawn below the seam under continuous scrolling. Nil at the end
    /// of the notebook — there is nothing below the last page to look at — and while the first
    /// picture of a new neighbour is still being prepared.
    @Published private(set) var nextPagePreview: PagePreview?
    /// The page before this one, drawn above the top of the sheet: the mirror of
    /// `nextPagePreview`, so scrolling up runs on into it the way scrolling down runs on into the
    /// next.
    @Published private(set) var previousPagePreview: PagePreview?
    /// The neighbouring page ids, as of the last load. What the seam commits to, and what
    /// scrolling off the top enters.
    @Published private(set) var nextPageId: String?
    @Published private(set) var previousPageId: String?
    /// The page's text boxes, oldest first — what the canvas draws and hit-tests. A projection
    /// of `page.blocks`, which stays the truth: a block of another kind, or a flowing one, is
    /// carried through the file untouched by anything here.
    @Published private(set) var textBlocks: [CouchBlock] = []
    /// The box being typed into, if any.
    ///
    /// Held here rather than in the view because two other things have to know: the editor's
    /// keyboard shortcuts must not fire into a page turn while somebody is typing `[`, and a
    /// commit has to be able to ask whether the box it is committing still exists.
    @Published private(set) var editingBlockID: String?

    /// The ids of the strokes the canvas is currently showing — what was loaded into it, or what
    /// was last exported out of it. Two jobs: it is the baseline `savePage` derives tombstones
    /// from, and it is how "the file holds ink the canvas does not" is decided.
    private(set) var canvasStrokeIDs: Set<String> = []
    /// The block ids the last successful save wrote — the block half of `canvasStrokeIDs`, and
    /// what turns a box deleted here into a tombstone the other device honours.
    private(set) var blockBaseline: Set<String> = []
    /// Sync wrote something and the canvas has not caught up. Survives until it is safe to act on.
    private(set) var remoteInkPending = false
    private(set) var dirty = false
    private var saveTask: Task<Void, Never>?
    /// What the canvas is doing right now, written by the canvas coordinator. Owned here because
    /// the save path reads the scroll offset out of it.
    let liveState = CanvasLiveState()

    private var store: NotebookStore?
    private var notebookId = ""
    /// Stamped into every block this editor writes; the merge's tiebreak when two edits share a
    /// millisecond. Read once at attach — changing the device id mid-session is a settings
    /// action that restarts sync anyway.
    private var deviceID = CouchSettings.defaultDeviceID
    private var lastKnownNotebookTitle = "Notebook"
    /// A remote removal cannot save into the tombstoned source. Retry writes a separate
    /// handwriting notebook, reusing its destination if its first page write failed.
    private var recoveryPending = false
    private var recoveryNotebook: NotebookManifest?
    private var recoveryStrokes: [StrokeDTO]?
    private var recoveringMissingPage = false
    private var savingPage = false
    private enum StoreChangeDuringSave { case local, remote }
    private var storeChangeDuringSave: StoreChangeDuringSave?
    /// The notebook's page order as this editor last saw it with its page still listed — what
    /// the landing decision reads when the page vanishes, since by then the manifest no longer
    /// says where it was.
    private var lastKnownPageIds: [String] = []
    /// Asked to dismiss the editor when there is nothing left to show — the notebook itself is
    /// gone, or its last page is. Handed in by the view, which owns the navigation.
    var requestClose: (() -> Void)?
    /// Where the page about to be opened should be scrolled to, when the scroll — not the
    /// page's own saved position — decides. Set immediately before `open`, consumed by it.
    ///
    /// `.end` rather than a large number: the page's own height is only known once it is
    /// loaded, and a sentinel offset would be published (and saved) as the page's scroll
    /// position before the canvas ever laid out and clamped it.
    enum EntryScroll {
        /// Measured from the top of the page being entered.
        case carried(CGFloat)
        /// Measured from the *bottom* of the page being entered — how a backward crossing
        /// arrives, since it knows where the view sits relative to the page it is leaving, whose
        /// top is the end of this one.
        case fromEnd(CGFloat)

        /// Either can be negative: a page with a page above it scrolls into the room above its
        /// top, and a crossing may land there.
        func resolved(against page: PageFile) -> CGFloat {
            switch self {
            case .carried(let y): return y
            case .fromEnd(let y): return CGFloat(page.pageSize.height) + y
            }
        }
    }

    private var entryScroll: EntryScroll?
    /// The scroll position the open page was entered at — what the canvas restores. Distinct
    /// from `liveState.pageY`, which follows the finger from then on.
    @Published private(set) var openScroll: CGFloat = 0

    /// Connects the store, the way the undo controller attaches to the undo manager — SwiftUI
    /// builds its state objects before the environment is readable, so this cannot be an
    /// initializer. Also where the model starts listening for the store changing under its feet.
    func attach(store: NotebookStore, notebookId: String) {
        guard self.store == nil else { return }
        self.store = store
        self.notebookId = notebookId
        deviceID = CouchSettings.load().deviceID
        lastKnownNotebookTitle = store.manifest(id: notebookId)?.title ?? "Notebook"
        // The CouchDB pull loop rewrites page files with no regard for what is open, so the
        // editor has to hear about it or it would keep drawing on a stale copy.
        NotificationCenter.default.addObserver(
            self, selector: #selector(storeDidApplyRemoteChanges),
            name: NotebookStore.didApplyRemoteChangesNotification, object: nil)
        // Local mutations too: the page overview can delete the page this editor has open, and
        // an editor that does not hear about it keeps writing into a tombstoned ghost file.
        NotificationCenter.default.addObserver(
            self, selector: #selector(storeDidChangeLocally),
            name: NotebookStore.didChangeLocallyNotification, object: nil)
    }

    @objc private func storeDidApplyRemoteChanges() {
        if savingPage {
            storeChangeDuringSave = .remote
            return
        }
        guard reconcileWithStore(remoteChange: true) else { return }
        remoteInkPending = true
        foldInRemoteInk()
    }

    @objc private func storeDidChangeLocally() {
        if savingPage {
            if storeChangeDuringSave == nil { storeChangeDuringSave = .local }
            return
        }
        reconcileWithStore()
    }

    /// Remote removal preserves unsaved handwriting in a separate notebook before leaving.
    /// Explicit local deletion keeps its existing meaning: the page and its edits are deleted.
    /// Neither path writes into the tombstoned source.
    ///
    /// - Returns: whether the open page is still live, i.e. whether the caller may keep working
    ///   with it.
    @discardableResult
    private func reconcileWithStore(remoteChange: Bool = false) -> Bool {
        // Recovery uses ordinary store APIs, whose local notifications are synchronous.
        // Re-entering here would treat the unfinished recovery as another disappearance.
        guard !recoveringMissingPage else { return false }
        guard let store, let vanished = pageId else { return true }
        let manifest = store.manifest(id: notebookId)
        if let manifest, manifest.pageIds.contains(vanished) {
            lastKnownNotebookTitle = manifest.title
            // Still listed. Keep the order fresh, so a later vanish knows where the page *was*.
            lastKnownPageIds = manifest.pageIds
            // The page order can change without this page moving — a page appended past the end
            // (which is how scrolling off the notebook grows it), inserted by the overview, or
            // arriving from a peer. The seam has to show what is actually next.
            refreshNeighbors()
            return true
        }

        if remoteChange, dirty || liveState.isDrawing { recoveryPending = true }
        if recoveryPending {
            guard !liveState.isDrawing else { return false }
            guard recoverUnsavedHandwriting() else { return false }
        }

        // Tombstoned under the editor. Drop the pending work rather than flushing it — the
        // strokes belong to a page that no longer exists, and letting `open`'s flush try would
        // only raise a save alert about a delete the user just asked for.
        saveTask?.cancel()
        dirty = false
        remoteInkPending = false
        page = nil

        guard let manifest else {
            requestClose?()
            return false
        }

        let landing = EditorPageRecovery.landingPageId(
            vanished: vanished,
            previousOrder: lastKnownPageIds,
            pageIds: manifest.pageIds,
            openPageId: manifest.openPageId)
        if let landing {
            open(pageId: landing)
        } else {
            requestClose?()
        }
        return false
    }

    /// Saves what the live canvas still holds under fresh notebook/page/stroke IDs. The copy
    /// is explicitly handwriting: deleted PDF/image files and other attachments may no longer
    /// exist, so it preserves ink coordinates, sheet size, and native paper without dangling
    /// references or claiming to recover those assets.
    private func recoverUnsavedHandwriting() -> Bool {
        guard let store, let source = page else { return false }
        recoveringMissingPage = true
        defer { recoveringMissingPage = false }
        saveTask?.cancel()
        do {
            if recoveryNotebook == nil {
                let background = PageBackground(
                    background: source.background, backgroundType: source.backgroundType)
                let template: NativeTemplate
                if case .native(let native) = background, native.isDrawable {
                    template = native
                } else {
                    template = .blank
                }
                recoveryNotebook = try store.createNotebook(
                    title: "Recovered handwriting — \(lastKnownNotebookTitle)",
                    template: template, pageSize: source.pageSize)
            }
            guard let destination = recoveryNotebook, let destinationPage = destination.pageIds.first
            else { return false }
            var recovered = try store.loadPage(
                notebookId: destination.notebookId, pageId: destinationPage)
            recovered.title = source.title
            recovered.scroll = max(0, Int(liveState.pageY.rounded()))
            // Keep the recovery IDs across retries so subsequent edits keep their identity
            // within the recovery copy, just as ordinary autosaves do.
            let strokes: [StrokeDTO]
            if let recoveryStrokes {
                strokes = PencilKitBridge.strokeDTOs(from: drawing, source: recoveryStrokes)
            } else {
                strokes = PencilKitBridge.strokeDTOs(from: drawing, source: source.strokes).map { stroke in
                    var copy = stroke
                    copy.id = UUID().uuidString.lowercased()
                    return copy
                }
            }
            recoveryStrokes = strokes
            recovered.strokes = strokes
            _ = try store.savePage(recovered)
            dirty = false
            recoveryPending = false
            recoveryNotebook = nil
            recoveryStrokes = nil
            saveError = nil
            return true
        } catch {
            saveError = "This page was removed on another device. Couldn’t save a recovered handwriting copy: \(error)"
            return false
        }
    }

    func openInitialPage(preferredPageId: String? = nil) {
        guard let store else { return }
        // Before the manifest is read, not after: a notebook written when a page was an endless
        // scroll can hold most of its work below the first sheet, and opening it at "page 1 of 1"
        // would show a fraction of what is there. Does nothing to a notebook already in sheets.
        store.splitOversizedPages(in: notebookId)
        guard let manifest = store.manifest(id: notebookId) else { return }
        let initial = preferredPageId.flatMap { manifest.pageIds.contains($0) ? $0 : nil }
            ?? store.lastOpenedPage(in: manifest)
        if let initial { open(pageId: initial) }
    }

    /// - Returns: whether the page loaded. Callers that are retrying something use it; the
    ///   ordinary ones do not, because `loadError` already puts the failure on screen.
    ///
    /// - Parameter persistingScroll: whether the page being left should be written just because
    ///   its scroll position moved. A seam crossing passes false: scrolling through the notebook
    ///   is not an edit, and writing a page file for it put a disk write, a library rescan and a
    ///   sync push into the middle of every scroll that crossed a page — and pushed a new revision
    ///   of the page to the other device for no change a reader could see. Unsaved ink is written
    ///   either way.
    @discardableResult
    func open(pageId newPageId: String, persistingScroll: Bool = true) -> Bool {
        // Every route off the current page runs through here, so this is where its debounced
        // work is flushed. The navigator panel's jump used to be the one switch that never did:
        // anything drawn inside the 2s re-arming window was silently lost, along with the
        // unsaved scroll offset. Flushing at the door kills the whole forgot-to-flush class —
        // callers that already saved cost nothing, because saveNow is a no-op when clean.
        // Consumed here, not on the success path: a load that throws used to leave the sentinel
        // set, and the *next* page opened — an unrelated one, reached from the overview —
        // silently inherited the position and persisted it as its own scroll.
        let entry = entryScroll
        entryScroll = nil
        // A failed flush must keep the current canvas alive. Loading another page here used
        // to replace the unsaved drawing and clear `dirty` despite the save error.
        guard saveNow(persistingScroll: persistingScroll) else { return false }
        guard let store else { return false }
        do {
            let loaded: PageFile
            // Read ahead while the reader was on a neighbouring page, and still exactly what is
            // on disk: open from that rather than reading and decoding the file again. This is
            // what keeps a seam crossing — which lands here from inside a scroll callback — from
            // stalling the scroll. Anything else reads the file as it always did.
            if let ready = prepared[newPageId],
               ready.revision == store.pageRevision(notebookId: notebookId, pageId: newPageId)
            {
                loaded = ready.file
                drawing = ready.drawing
                pageBackground = ready.background
                pageImages = ready.images
            } else {
                loaded = try store.loadPage(notebookId: notebookId, pageId: newPageId)
                drawing = PencilKitBridge.drawing(from: loaded.strokes)
                let notebookDir = store.notebookDirURL(notebookId)
                pageBackground = BackgroundRenderer.image(
                    for: loaded,
                    notebookDir: notebookDir,
                    storeRoot: store.rootURL)
                pageImages = BackgroundRenderer.pageImages(for: loaded, notebookDir: notebookDir)
            }
            page = loaded
            pageId = newPageId
            shownSurfaces = SurfaceState(of: loaded)
            canvasStrokeIDs = Set(loaded.strokes.map(\.id))
            blockBaseline = Set(loaded.blocks.map(\.id))
            textBlocks = TextBoxLayout.textBoxes(in: loaded.blocks)
            // A page switch leaves no box open. The caller commits first (see `endEditing`);
            // this only makes sure nothing points at a box on a page that is no longer here.
            editingBlockID = nil
            contentRevision += 1
            // Seed with the persisted offset so a save before any scroll preserves it, unless
            // the page is being entered at a position the scroll itself chose — carried across
            // a seam, or landing at the far end when scrolling backwards into it.
            openScroll = entry?.resolved(against: loaded) ?? CGFloat(max(loaded.scroll, 0))
            liveState.pageY = openScroll
            lastKnownPageIds = store.manifest(id: notebookId)?.pageIds ?? []
            refreshNeighbors()
            dirty = false
            loadError = nil
            store.rememberOpenedPage(newPageId, in: notebookId)
            return true
        } catch {
            loadError = String(describing: error)
            return false
        }
    }

    /// The library button may dismiss only after the current page is safely on disk.
    /// Deletion recovery calls `requestClose` directly because there is no live page to save.
    @discardableResult
    func close() -> Bool {
        guard saveNow() else { return false }
        requestClose?()
        return true
    }

    /// Enters the page below the seam, carrying the overshoot with it: what was scroll past this
    /// page's end becomes ordinary scroll on the next one, so nothing on screen moves.
    /// - Returns: whether a page was actually entered, so the caller only latches on a real
    ///   crossing. A latch set for a crossing that never happened has no page load coming to
    ///   clear it.
    @discardableResult
    func enterNextPageAcrossSeam(carrying scroll: CGFloat) -> Bool {
        guard let nextPageId else { return false }
        entryScroll = .carried(scroll)
        return open(pageId: nextPageId, persistingScroll: false)
    }

    /// Enters the page above, at the position that shows what is on screen now: `offset` is
    /// where the view sits measured from the top of the page being left, which is the bottom of
    /// the one being entered.
    /// - Returns: whether a page was actually entered — false at the first page, which is the
    ///   case that used to leave the caller's latch stuck for the rest of the session.
    @discardableResult
    func enterPreviousPageAcrossSeam(carrying offset: CGFloat) -> Bool {
        guard let previousPageId else { return false }
        entryScroll = .fromEnd(offset)
        return open(pageId: previousPageId, persistingScroll: false)
    }

    /// Files ink drawn below the seam onto the page it was drawn *on*, rather than leaving it
    /// on the current page past the bottom of its own sheet.
    ///
    /// Continuous scrolling puts a viewport of the next page on screen below the seam, and the
    /// canvas — which belongs to the current page — is the live surface over all of it. Without
    /// this, writing there produced exactly the thing a page-is-a-sheet model exists to prevent:
    /// ink stored below the sheet, invisible to the overview, to export and to the BOOX, on a
    /// page that reports itself one sheet tall.
    ///
    /// A stroke belongs to the sheet its *top edge* falls in and travels whole — the same rule
    /// `PageSplit` applies, and the same one the BOOX app uses for the same case, so writing
    /// across the seam from above stays put while writing below it lands where the eye says.
    /// Deliberately not undoable here: the undo stack belongs to the page being edited, and an
    /// entry pointing into another page would delete rows out from under it.
    ///
    /// - Returns: the drawing with those strokes removed, or nil when none crossed.
    func fileInkBelowTheSeam(from drawing: PKDrawing, sheetHeight: CGFloat) -> PKDrawing? {
        guard sheetHeight > 0, let nextPageId, let store else { return nil }
        let below = drawing.strokes.filter { $0.renderBounds.minY >= sheetHeight }
        guard !below.isEmpty else { return nil }

        let moved = PKDrawing(strokes: below)
            .transformed(using: CGAffineTransform(translationX: 0, y: -sheetHeight))
        do {
            var neighbor = try store.loadPage(notebookId: notebookId, pageId: nextPageId)
            let existing = neighbor.strokes
            neighbor.strokes = existing + PencilKitBridge.strokeDTOs(from: moved)
            // The neighbour's own strokes are the baseline, so this reads as an addition rather
            // than as "everything else was erased".
            _ = try store.savePage(neighbor, baselineStrokeIDs: Set(existing.map(\.id)))
        } catch {
            // The ink is still on the canvas and still on this page; refusing to move it is
            // better than dropping it, and the save alert already covers a broken store.
            saveError = String(describing: error)
            return nil
        }
        // The neighbour's file just changed, so its revision did: this re-prepares it, and the
        // picture under the seam catches up with what was just written there.
        refreshNeighbors()
        let kept = drawing.strokes.filter { $0.renderBounds.minY < sheetHeight }
        return PKDrawing(strokes: kept)
    }

    /// Files ink drawn in the room above the page onto the page it was drawn *on* — the one
    /// before — the mirror of `fileInkBelowTheSeam`.
    ///
    /// Only the strokes the caller names as just drawn are candidates. Ink already on the page
    /// that happens to start a little above its top — a page from the BOOX, or from before
    /// sheets were agreed — has always been this page's, and lifting the pencil somewhere else
    /// on the page must not move it.
    ///
    /// Same top-edge rule as below the seam: a stroke whose top edge is above this page's top
    /// belongs to the page above, and travels whole. Not undoable, for the same reason.
    ///
    /// - Returns: the drawing with those strokes removed, or nil when none crossed.
    func fileInkAboveTheTop(from drawing: PKDrawing, newStrokes: Range<Int>) -> PKDrawing? {
        guard let previousPageId, let store else { return nil }
        let candidates = newStrokes.clamped(to: drawing.strokes.indices)
        let above = Set(candidates.filter { drawing.strokes[$0].renderBounds.minY < 0 })
        guard !above.isEmpty else { return nil }
        do {
            var neighbor = try store.loadPage(notebookId: notebookId, pageId: previousPageId)
            let moved = PKDrawing(strokes: above.sorted().map { drawing.strokes[$0] })
                .transformed(
                    using: CGAffineTransform(
                        translationX: 0, y: CGFloat(neighbor.pageSize.height)))
            let existing = neighbor.strokes
            neighbor.strokes = existing + PencilKitBridge.strokeDTOs(from: moved)
            _ = try store.savePage(neighbor, baselineStrokeIDs: Set(existing.map(\.id)))
        } catch {
            saveError = String(describing: error)
            return nil
        }
        refreshNeighbors()
        return PKDrawing(
            strokes: drawing.strokes.enumerated()
                .filter { !above.contains($0.offset) }
                .map(\.element))
    }

    /// Re-reads the neighbours of the open page and makes sure each is prepared.
    ///
    /// The ids are settled synchronously — they are read from a manifest already in memory, and
    /// everything that decides navigation depends on them. The pages themselves are not: reading
    /// a page file, rebuilding its ink and rasterizing a picture of it is tens of milliseconds,
    /// and this runs right after a crossing, while the scroll that made it is still moving. So
    /// each neighbour is prepared off the main actor and published when it is ready. Until then
    /// the seam shows the last picture of that page if there is one, or blank paper.
    private func refreshNeighbors() {
        guard let store, let pageId,
              let manifest = store.manifest(id: notebookId),
              let index = manifest.pageIds.firstIndex(of: pageId)
        else {
            nextPageId = nil
            previousPageId = nil
            for job in preparing.values { job.task.cancel() }
            preparing = [:]
            prepared = [:]
            publishPreviews()
            return
        }
        let previous = index > 0 ? manifest.pageIds[index - 1] : nil
        let following = index + 1 < manifest.pageIds.count ? manifest.pageIds[index + 1] : nil
        previousPageId = previous
        nextPageId = following

        // The open page is kept too: unedited, its prepared copy is still exactly the file, and
        // it is the page the next crossing will leave — so scrolling back to it is instant.
        let wanted = Set([previous, pageId, following].compactMap { $0 })
        prepared = prepared.filter { wanted.contains($0.key) }
        for (id, job) in preparing where !wanted.contains(id) {
            job.task.cancel()
            preparing[id] = nil
        }
        for neighbor in [previous, following].compactMap({ $0 }) {
            prepare(neighbor, store: store)
        }
        publishPreviews()
    }

    /// Starts reading `id` ahead of the scroll, unless a copy of its current revision is already
    /// held or on its way. Keyed on the file's revision as well as its id, so ink that arrives
    /// on a neighbour — written on the BOOX and synced in, or filed there across a seam — is
    /// picked up rather than frozen at whatever the page held the first time it was read.
    private func prepare(_ id: String, store: NotebookStore) {
        let revision = store.pageRevision(notebookId: notebookId, pageId: id)
        guard prepared[id]?.revision != revision, preparing[id]?.revision != revision
        else { return }
        preparing[id]?.task.cancel()
        let task = Task { [weak self, notebookId] in
            let ready = await Task.detached(priority: .userInitiated) {
                PreparedPage.read(pageId: id, notebookId: notebookId, store: store)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.preparing[id] = nil
            // Nothing came back — an unreadable or missing file. Nothing is recorded, so the next
            // refresh tries again rather than the neighbour staying blank for good.
            guard let ready,
                  [self.pageId, self.previousPageId, self.nextPageId].contains(id)
            else { return }
            self.prepared[id] = ready
            self.publishPreviews()
        }
        preparing[id] = (revision, task)
    }

    /// Puts the prepared pictures of the two neighbours on screen. A neighbour whose newest
    /// revision is still being prepared keeps showing its previous picture meanwhile: a moment
    /// of the page as it was reads far better than a flash of blank paper where ink should be.
    private func publishPreviews() {
        let next = nextPageId.flatMap { prepared[$0]?.preview }
        let previous = previousPageId.flatMap { prepared[$0]?.preview }
        // Compared first: every assignment to a published property re-renders the editor, and
        // this runs on every store notification.
        if next != nextPagePreview { nextPagePreview = next }
        if previous != previousPagePreview { previousPagePreview = previous }
    }

    /// Pages read ahead of the scroll: the neighbours of the open page, and the open page itself
    /// for as long as its copy is current. Never opened from once the file has moved on.
    private var prepared: [String: PreparedPage] = [:]
    /// Reads in flight, and the revision each was started for.
    private var preparing: [String: (revision: String, task: Task<Void, Never>)] = [:]

    /// Waits for every read-ahead in flight. For tests, which otherwise could not tell a
    /// neighbour that is not ready yet from one that will never be.
    func waitForNeighbors() async {
        while let job = preparing.values.first {
            await job.task.value
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
    ///
    /// The flag is cleared only once that has actually happened. Sync writes these files while this
    /// reads them, so a read here can lose a race it will win a moment later — and dropping the
    /// flag on the way past would leave the canvas stale until some *other* document happened to
    /// arrive. Retries are driven by pencil-lifts and further applies, so a page that cannot be
    /// read at all costs a file read, not a spin.
    func foldInRemoteInk() {
        if recoveryPending {
            if !liveState.isDrawing { saveNow() }
            return
        }
        guard remoteInkPending, !liveState.isDrawing, let pageId, let store else { return }
        // A failed flush leaves `dirty` set, and reloading now would replace the drawing with
        // the file and clear it — throwing away exactly the strokes the save alert just promised
        // were safe, and cancelling their retry with them. `remoteInkPending` stays set, so the
        // fold runs again at the next pencil-lift or apply, once a save has landed.
        guard saveNow() else { return }
        guard let onDisk = try? store.loadPage(notebookId: notebookId, pageId: pageId) else {
            return  // a torn or missing read is not a reason to drop what is on the canvas
        }

        let erased = Set(onDisk.deletedStrokes.map(\.id))
        let arrived = onDisk.strokes.contains { !canvasStrokeIDs.contains($0.id) }
        let erasedElsewhere = canvasStrokeIDs.contains { erased.contains($0) }
        if arrived || erasedElsewhere {
            if open(pageId: pageId) { remoteInkPending = false }
            return
        }
        // No ink moved, but a page is more than its ink. This decision used to be stroke-based
        // alone, which read an image dropped on the BOOX — or a paper change, or a resize — as
        // "the canvas already matches the file" and swallowed it for as long as the page stayed
        // open: every later apply re-armed the flag, and the stroke comparison cleared it again.
        // The surfaces the canvas does not hold are compared and refreshed here instead; most
        // applied documents are still some other page or this page's own echo, and those change
        // nothing and cost nothing.
        refreshNonInkSurfaces(from: onDisk)
        remoteInkPending = false  // the canvas now matches the file
    }

    /// Puts everything a page shows *besides* ink — its images, its paper, its sheet — onto the
    /// published state, from a copy of the file that is already known to agree with the canvas
    /// about the ink. Deliberately not a reload through `open`: replacing the drawing for a
    /// surface change would cancel the undo stack for strokes that never moved.
    private func refreshNonInkSurfaces(from onDisk: PageFile) {
        guard var page, let store else { return }
        // Compared against what the *canvas* shows, not against `page`: `savePage` unions
        // remotely-arrived images into what it returns, so after any flush `page` can already
        // carry an image the screen has never drawn — and a comparison against it would read the
        // arrival as "nothing changed" and swallow the image all over again.
        let arrivedSurfaces = SurfaceState(of: onDisk)
        guard arrivedSurfaces != shownSurfaces else { return }
        // Only the surface fields, not the whole file: `page.strokes` has to keep naming what
        // this editor last loaded or wrote, because it is the `source:` the next export
        // re-identifies against.
        page.images = onDisk.images
        page.background = onDisk.background
        page.backgroundType = onDisk.backgroundType
        page.pageWidth = onDisk.pageWidth
        page.pageHeight = onDisk.pageHeight
        // `page` is what the next save writes, and a copy that stopped tracking the file would
        // hand `savePage` a stale list to fold back in.
        page.blocks = onDisk.blocks
        page.deletedBlocks = onDisk.deletedBlocks
        self.page = page
        textBlocks = TextBoxLayout.textBoxes(in: page.blocks)
        // The file is the baseline again. Without this, a box the BOOX added while this page was
        // open would be absent from the baseline, and the next local save would derive a
        // tombstone for a block nobody deleted.
        blockBaseline = Set(page.blocks.map(\.id))
        let notebookDir = store.notebookDirURL(notebookId)
        pageBackground = BackgroundRenderer.image(
            for: page, notebookDir: notebookDir, storeRoot: store.rootURL)
        pageImages = BackgroundRenderer.pageImages(for: page, notebookDir: notebookDir)
        shownSurfaces = arrivedSurfaces
    }

    /// The non-ink surfaces as the canvas last drew them — what `foldInRemoteInk` compares an
    /// applied file against. A separate record rather than a reading of `page`, because `page`
    /// tracks the *file* (it absorbs `savePage`'s unions) while this has to track the *screen*.
    private var shownSurfaces: SurfaceState?

    private struct SurfaceState: Equatable {
        let images: [ImageDTO]
        let background: String
        let backgroundType: String
        let pageWidth: Int?
        let pageHeight: Int?
        let blocks: [CouchBlock]
        let deletedBlocks: [CouchTombstone]

        init(of page: PageFile) {
            images = page.images
            background = page.background
            backgroundType = page.backgroundType
            pageWidth = page.pageWidth
            pageHeight = page.pageHeight
            blocks = page.blocks
            deletedBlocks = page.deletedBlocks
        }
    }

    /// Writes the chosen paper into the page file (`backgroundType: "native"`), which is what
    /// the BOOX reads back after a sync. The caller decides *whether* the page may change paper;
    /// this only applies the change.
    func setPaper(background: String, backgroundType: String) {
        guard var page else { return }
        guard background != page.background || backgroundType != page.backgroundType
        else { return }
        page.background = background
        page.backgroundType = backgroundType
        self.page = page
        // The screen follows this choice immediately (the template is derived from `page`), so
        // the record of what it shows has to follow too — or the next remote apply would read
        // the user's own paper change back off the file as an arrival and refresh for nothing.
        shownSurfaces = SurfaceState(of: page)
        dirty = true
        saveNow()
    }

    // MARK: Text boxes

    /// A new, empty box with its top-left at `point` (page units), ready to be typed into.
    ///
    /// Not added to the page: an empty box is not content, and a user who taps the paper by
    /// accident and taps away again should leave nothing behind. It joins `page.blocks` on the
    /// first commit that has text in it.
    func newTextBlock(at point: CGPoint) -> CouchBlock? {
        guard let page else { return nil }
        let metrics = TextBoxMetrics.standard
        let sheet = page.pageSize
        // Clamped so the box starts on the paper. A box may still *end* past the bottom — the
        // page grows downward as you write, and typing at the foot of a sheet is ordinary.
        let x = min(max(point.x, 0), max(CGFloat(sheet.width) - metrics.minimumWidth, 0))
        let y = max(point.y, 0)
        let width = TextBoxLayout.defaultWidth(x: x, pageWidth: CGFloat(sheet.width))
        let stamp = SyncClock.shared.stamp()
        return CouchBlock(
            id: UUID().uuidString.lowercased(),
            kind: "md",
            // Empty is legal for a positioned block and sorts first (protocol §3.3.1). A key is
            // what orders a page's *flow*, and a box that carries its own coordinates is not in
            // one — so there is nothing to mint, and nothing for two devices to disagree about.
            orderKey: "",
            text: "",
            x: Int(x.rounded()), y: Int(y.rounded()),
            width: Int(width.rounded()),
            height: Int(TextBoxLayout.measuredHeight(source: "", width: width).rounded()),
            createdAt: stamp, updatedAt: stamp, deviceId: deviceID)
    }

    /// Marks `block` as the one being typed into, so the canvas stops drawing it underneath the
    /// text view and the page-turn shortcuts hold off.
    func beginEditing(_ block: CouchBlock) {
        editingBlockID = block.id
    }

    /// Writes what was typed and ends the session.
    ///
    /// An empty box is deleted rather than stored: a box with nothing in it is invisible, so
    /// leaving one behind would litter the page with things only a stray tap can find.
    func commitEditing(_ block: CouchBlock, text: String) {
        editingBlockID = nil
        guard page != nil else { return }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            deleteTextBlock(id: block.id)
            return
        }
        var updated = block
        updated.text = text
        updated.height = Int(TextBoxLayout.measuredHeight(
            source: text, width: CGFloat(updated.width ?? 0)).rounded())
        // A box the other device deleted while it was being typed into comes back under a new
        // id. The tombstone would suppress the old one on the next merge, so keeping it would
        // quietly throw the typing away — and §3.3.1 says as much: retyping a deleted paragraph
        // mints a new id, which is exactly what makes remove-wins safe here.
        if page?.deletedBlocks.contains(where: { $0.id == updated.id }) == true {
            updated.id = UUID().uuidString.lowercased()
            updated.createdAt = SyncClock.shared.stamp()
        }
        upsert(updated)
    }

    /// Abandons the session without writing. A box that was never committed simply never existed.
    func cancelEditing() {
        editingBlockID = nil
    }

    func moveTextBlock(id: String, to point: CGPoint) {
        guard let page, var block = page.blocks.first(where: { $0.id == id }) else { return }
        let sheet = page.pageSize
        let metrics = TextBoxMetrics.standard
        block.x = Int(min(max(point.x, 0), max(CGFloat(sheet.width) - metrics.minimumWidth, 0))
            .rounded())
        block.y = Int(max(point.y, 0).rounded())
        upsert(block)
    }

    /// Sets a box's wrap width. Its height follows from the text, so it is remeasured here
    /// rather than dragged.
    func resizeTextBlock(id: String, width: CGFloat) {
        guard let page, var block = page.blocks.first(where: { $0.id == id }) else { return }
        let metrics = TextBoxMetrics.standard
        let sheet = page.pageSize
        let clamped = min(
            max(width, metrics.minimumWidth),
            max(CGFloat(sheet.width) - CGFloat(block.x ?? 0), metrics.minimumWidth))
        block.width = Int(clamped.rounded())
        block.height = Int(TextBoxLayout.measuredHeight(
            source: block.text ?? "", width: clamped).rounded())
        upsert(block)
    }

    func deleteTextBlock(id: String) {
        guard var page, page.blocks.contains(where: { $0.id == id }) else { return }
        if editingBlockID == id { editingBlockID = nil }
        page.blocks.removeAll { $0.id == id }
        // No tombstone written here. `savePage` derives it by comparing what is written against
        // `blockBaseline`, the same way an erased stroke is recorded — so a delete that never
        // reaches disk never claims to have happened.
        commit(page)
    }

    /// The box with this id as the page currently holds it, or nil if there is none.
    func textBlock(id: String) -> CouchBlock? {
        page?.blocks.first { $0.id == id }
    }

    /// Puts a box back the way it was, or takes it away again if it was not there before.
    ///
    /// The one operation undo needs, because every change to a text box — typing into a new one,
    /// editing an old one, moving, resizing, deleting — is "this block used to look like this".
    /// The restored copy is stamped fresh rather than carrying its old clock: undoing is a new
    /// edit, and one wearing a stale timestamp would lose to the very change it is undoing.
    func restoreTextBlock(id: String, to previous: CouchBlock?) {
        if let previous {
            upsert(previous)
        } else {
            deleteTextBlock(id: id)
        }
    }

    /// Adds or replaces `block`, stamping it as this device's latest word on it. Every path that
    /// changes a box goes through here, because the merge decides by `updatedAt` and a write
    /// that forgot to bump it would silently lose to the copy it was editing.
    private func upsert(_ block: CouchBlock) {
        guard var page else { return }
        var stamped = block
        stamped.updatedAt = SyncClock.shared.stamp()
        stamped.deviceId = deviceID
        if let index = page.blocks.firstIndex(where: { $0.id == stamped.id }) {
            page.blocks[index] = stamped
        } else {
            page.blocks.append(stamped)
        }
        commit(page)
    }

    private func commit(_ updated: PageFile) {
        page = updated
        textBlocks = TextBoxLayout.textBoxes(in: updated.blocks)
        // The screen already shows this change, so the record of what it shows has to follow it
        // — or the next remote apply would read the user's own typing back off the file as an
        // arrival and refresh the page for nothing. Same reason `setPaper` does it.
        shownSurfaces = SurfaceState(of: updated)
        dirty = true
        scheduleSave()
    }

    func scheduleSave() {
        dirty = true
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { saveNow() }
        }
    }

    /// Whether the page is safely saved. Navigation must honour a failure; background flushes
    /// keep the model alive and can retry when the app becomes active again.
    ///
    /// - Parameter persistingScroll: false writes only when there is unsaved content — the scroll
    ///   position alone is not worth a write. See `open(pageId:persistingScroll:)`.
    @discardableResult
    func saveNow(persistingScroll: Bool = true) -> Bool {
        guard !savingPage else { return false }
        saveTask?.cancel()
        if recoveryPending {
            guard !liveState.isDrawing else { return false }
            guard recoverUnsavedHandwriting() else { return false }
            // The retry finished: leave the removed page normally instead of keeping an
            // editor open over a notebook that can never accept another save.
            reconcileWithStore()
            return true
        }
        guard var page, let store else { return !dirty }
        let scroll = max(0, Int(liveState.pageY.rounded()))
        guard dirty || (persistingScroll && scroll != page.scroll) else { return true }
        // What the canvas held going into this save. `savePage` needs it to tell ink the user
        // erased from ink that arrived from the BOOX while this page was open — the file cannot
        // answer that, because sync may have rewritten it since.
        let baseline = canvasStrokeIDs
        // `page.strokes` is the set we last loaded or wrote, so identity chains forward across
        // repeated saves: an untouched stroke keeps its id and its exact bytes.
        page.strokes = PencilKitBridge.strokeDTOs(from: drawing, source: page.strokes)
        page.scroll = scroll
        // The store refreshes and notifies synchronously before returning. Defer those
        // callbacks so a disappearance cannot replace the canvas halfway through this save.
        savingPage = true
        defer {
            savingPage = false
            let change = storeChangeDuringSave
            storeChangeDuringSave = nil
            switch change {
            case .remote:
                storeDidApplyRemoteChanges()
            case .local:
                // This notification came from our own save, not an explicit local delete.
                // A disappearance seen here must preserve any edits the save still owes.
                reconcileWithStore(remoteChange: true)
            case nil:
                break
            }
        }
        do {
            let written = try store.savePage(
                page, baselineStrokeIDs: baseline, baselineBlockIDs: blockBaseline)
            // Only now that the write landed. The baseline has to keep naming what the canvas
            // held at the last save that *worked*: advancing it before the `try` meant a failed
            // save still consumed an erasure — the erased stroke was no longer in the baseline,
            // so the successful retry derived no tombstone for it and the fold against the file
            // resurrected it. The exported canvas set, deliberately not `written.strokes` — the
            // mismatch between the two is how `foldInRemoteInk` detects ink that arrived from
            // the other device underneath this save.
            canvasStrokeIDs = Set(page.strokes.map(\.id))
            // What the file now holds, not what was offered: a box that arrived from the BOOX
            // during this save is in `written` and must be in the baseline, or the next save
            // would read it as one this editor deleted and tombstone it.
            blockBaseline = Set(written.blocks.map(\.id))
            // Take back what was written rather than what was offered: `savePage` reconciles
            // against the file, so only the returned copy matches what is now on disk. That is
            // what `page` is supposed to be, and `page.strokes` is the `source:` the next export
            // re-identifies against. On failure `self.page` stays untouched for the same reason:
            // it still carries the last truly-written DTOs.
            self.page = written
            textBlocks = TextBoxLayout.textBoxes(in: written.blocks)
            dirty = false
            saveError = nil
            return true
        } catch {
            // Leave `dirty` set so the next flush retries. Clearing it on a failed write — which
            // is what `try?` did — silently discarded the strokes that failed to land.
            saveError = String(describing: error)
            if error is NotebookStore.PageRemovedDuringSaveError {
                storeChangeDuringSave = .remote
            }
            return false
        }
    }
}

/// Where the editor lands when the page it had open disappears from the notebook's list —
/// deleted from the page overview underneath it, or removed by a merge. Pure so the decision
/// can be tested as a table rather than a gesture.
enum EditorPageRecovery {
    /// - Parameters:
    ///   - vanished: the page the editor had open, no longer in `pageIds`.
    ///   - previousOrder: the page list as the editor last saw it with `vanished` still in it —
    ///     the only remaining record of where the page *was*.
    ///   - pageIds: the notebook's list as it is now.
    ///   - openPageId: the manifest's own idea of the open page, which a merge may have
    ///     retargeted deliberately.
    /// - Returns: the page to open, or nil when the notebook has none left to offer.
    static func landingPageId(
        vanished: String,
        previousOrder: [String],
        pageIds: [String],
        openPageId: String?
    ) -> String? {
        guard !pageIds.isEmpty else { return nil }
        let surviving = Set(pageIds)

        // The nearest surviving neighbor first: the page that took the vanished one's place,
        // else the closest one before it. That is where a reader who just deleted "this page"
        // expects to be standing. The manifest's `openPageId` is deliberately *not* preferred
        // over it — bopa never updates that field as you navigate, so it usually still names
        // wherever the notebook happened to be opened.
        if let index = previousOrder.firstIndex(of: vanished) {
            if let after = previousOrder[(index + 1)...].first(where: surviving.contains) {
                return after
            }
            if let before = previousOrder[..<index].last(where: surviving.contains) {
                return before
            }
        }
        // No usable memory of where the page was; fall back to what the manifest says, then to
        // the front of the notebook.
        if let openPageId, surviving.contains(openPageId) { return openPageId }
        return pageIds.first
    }
}
