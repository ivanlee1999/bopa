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
    /// The top of the page after this one, drawn below the seam under continuous scrolling.
    /// Nil at the end of the notebook — there is nothing below the last page to look at.
    @Published private(set) var nextPagePreview: NextPagePreview?
    /// The neighbouring page ids, as of the last load. What the seam commits to, and what
    /// scrolling off the top enters.
    @Published private(set) var nextPageId: String?
    @Published private(set) var previousPageId: String?

    /// The ids of the strokes the canvas is currently showing — what was loaded into it, or what
    /// was last exported out of it. Two jobs: it is the baseline `savePage` derives tombstones
    /// from, and it is how "the file holds ink the canvas does not" is decided.
    private(set) var canvasStrokeIDs: Set<String> = []
    /// Sync wrote something and the canvas has not caught up. Survives until it is safe to act on.
    private(set) var remoteInkPending = false
    private(set) var dirty = false
    private var saveTask: Task<Void, Never>?
    /// What the canvas is doing right now, written by the canvas coordinator. Owned here because
    /// the save path reads the scroll offset out of it.
    let liveState = CanvasLiveState()

    private var store: NotebookStore?
    private var notebookId = ""
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
        case carried(CGFloat)
        case end

        func resolved(against page: PageFile) -> CGFloat {
            switch self {
            case .carried(let y): return max(y, 0)
            case .end: return CGFloat(page.pageSize.height)
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
        guard reconcileWithStore() else { return }
        remoteInkPending = true
        foldInRemoteInk()
    }

    @objc private func storeDidChangeLocally() {
        reconcileWithStore()
    }

    /// The store changed underneath the editor. If the open page is no longer listed, nothing is
    /// flushed — the page is tombstoned, and `savePage` would refuse the write anyway — and the
    /// editor moves to the page the reader should land on. If the whole notebook is gone, there
    /// is nothing left to show and the editor asks to close.
    ///
    /// - Returns: whether the open page is still live, i.e. whether the caller may keep working
    ///   with it.
    @discardableResult
    private func reconcileWithStore() -> Bool {
        guard let store, let vanished = pageId else { return true }
        guard let manifest = store.manifest(id: notebookId) else {
            requestClose?()
            return false
        }
        guard !manifest.pageIds.contains(vanished) else {
            // Still listed. Keep the order fresh, so a later vanish knows where the page *was*.
            lastKnownPageIds = manifest.pageIds
            // The page order can change without this page moving — a page appended past the end
            // (which is how scrolling off the notebook grows it), inserted by the overview, or
            // arriving from a peer. The seam has to show what is actually next.
            refreshNeighbors()
            return true
        }

        // Tombstoned under the editor. Drop the pending work rather than flushing it — the
        // strokes belong to a page that no longer exists, and letting `open`'s flush try would
        // only raise a save alert about a delete the user just asked for.
        saveTask?.cancel()
        dirty = false
        remoteInkPending = false
        page = nil

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

    func openInitialPage() {
        guard let store else { return }
        // Before the manifest is read, not after: a notebook written when a page was an endless
        // scroll can hold most of its work below the first sheet, and opening it at "page 1 of 1"
        // would show a fraction of what is there. Does nothing to a notebook already in sheets.
        store.splitOversizedPages(in: notebookId)
        guard let manifest = store.manifest(id: notebookId) else { return }
        let initial = manifest.openPageId ?? manifest.pageIds.first
        if let initial { open(pageId: initial) }
    }

    /// - Returns: whether the page loaded. Callers that are retrying something use it; the
    ///   ordinary ones do not, because `loadError` already puts the failure on screen.
    @discardableResult
    func open(pageId newPageId: String) -> Bool {
        // Every route off the current page runs through here, so this is where its debounced
        // work is flushed. The navigator panel's jump used to be the one switch that never did:
        // anything drawn inside the 2s re-arming window was silently lost, along with the
        // unsaved scroll offset. Flushing at the door kills the whole forgot-to-flush class —
        // callers that already saved cost nothing, because saveNow is a no-op when clean.
        saveNow()
        // Consumed here, not on the success path: a load that throws used to leave the sentinel
        // set, and the *next* page opened — an unrelated one, reached from the overview —
        // silently inherited the position and persisted it as its own scroll.
        let entry = entryScroll
        entryScroll = nil
        guard let store else { return false }
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
            shownSurfaces = SurfaceState(of: loaded)
            canvasStrokeIDs = Set(loaded.strokes.map(\.id))
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
            return true
        } catch {
            loadError = String(describing: error)
            return false
        }
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
        return open(pageId: nextPageId)
    }

    /// Enters the previous page at its own end — the position where this page is what shows
    /// under its seam, so scrolling up reads as one continuous surface rather than a jump.
    /// - Returns: whether a page was actually entered — false at the first page, which is the
    ///   case that used to leave the caller's latch stuck for the rest of the session.
    @discardableResult
    func enterPreviousPageAtItsEnd() -> Bool {
        guard let previousPageId else { return false }
        entryScroll = .end
        return open(pageId: previousPageId)
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
        // Re-render the strip so what is under the seam matches what was just written there.
        previewedNeighbor = nil
        refreshNeighbors()
        let kept = drawing.strokes.filter { $0.renderBounds.minY < sheetHeight }
        return PKDrawing(strokes: kept)
    }

    /// Re-reads the neighbours of the open page and renders the strip drawn under the seam.
    ///
    /// The ids are settled synchronously — they are read from a manifest already in memory, and
    /// everything that decides navigation depends on them. The *picture* is not: reading a page
    /// file and rasterizing a strip of it is tens of milliseconds, and this is called from a
    /// store notification that can arrive in the middle of a drag (appending a page off the end
    /// of the notebook does exactly that). Doing it inline blocked the main thread hard enough
    /// that the simulator could not even synthesize the rest of the gesture. So the strip is
    /// rendered off the main actor and published when it is ready; until then the seam shows
    /// blank paper, which is what a freshly appended page looks like anyway.
    private func refreshNeighbors() {
        guard let store, let pageId,
              let manifest = store.manifest(id: notebookId),
              let index = manifest.pageIds.firstIndex(of: pageId)
        else {
            nextPageId = nil
            previousPageId = nil
            nextPagePreview = nil
            previewTask?.cancel()
            return
        }
        previousPageId = index > 0 ? manifest.pageIds[index - 1] : nil
        let following = index + 1 < manifest.pageIds.count ? manifest.pageIds[index + 1] : nil
        nextPageId = following
        guard let following else {
            nextPagePreview = nil
            previewTask?.cancel()
            previewedNeighbor = nil
            return
        }
        // Already rendered for this neighbour *as it currently stands*: re-reading it on every
        // store notification would rasterize a strip per sync tick. Keyed on the file's
        // revision as well as its id, so ink that arrives on the neighbour — written on the
        // BOOX and synced in, or drawn there and scrolled back to — is picked up rather than
        // frozen at whatever the strip held the first time it was rendered.
        let revision = store.pageRevision(notebookId: notebookId, pageId: following)
        guard previewedNeighbor?.id != following || previewedNeighbor?.revision != revision
        else { return }
        previewedNeighbor = (id: following, revision: revision)
        previewTask?.cancel()
        // The page below the seam changed identity; what is on screen belongs to the old one.
        if nextPagePreview?.pageId != following { nextPagePreview = nil }
        previewTask = Task { [notebookId] in
            let rendered = await Self.renderPreview(
                of: following, notebookId: notebookId, store: store)
            guard !Task.isCancelled, previewedNeighbor?.id == following else { return }
            if rendered == nil {
                // Nothing came back — an unreadable file, or a page with nothing in its strip.
                // Do not hold the latch shut on a failure: a page that could not be read must be
                // retried on the next notification rather than previewing as blank for ever.
                previewedNeighbor = nil
            }
            nextPagePreview = rendered
        }
    }

    /// The neighbour the current preview (or the render in flight) is for, and the revision it
    /// was rendered from. Kept separately from `nextPagePreview`, which is nil while a render is
    /// in flight and for a page with nothing to show.
    private var previewedNeighbor: (id: String, revision: String)?
    private var previewTask: Task<Void, Never>?

    /// Reads a neighbour off disk and renders what the seam shows of it, off the main actor.
    ///
    /// A page that cannot be read previews as blank paper rather than failing anything: this is
    /// only a picture of where the scroll is heading, and the page itself is loaded properly
    /// when the scroll commits to it.
    private nonisolated static func renderPreview(
        of neighborId: String, notebookId: String, store: NotebookStore
    ) async -> NextPagePreview? {
        let read: (PageFile, URL, URL)? = await MainActor.run {
            guard let file = try? store.loadPage(notebookId: notebookId, pageId: neighborId)
            else { return nil }
            return (file, store.notebookDirURL(notebookId), store.rootURL)
        }
        guard let (file, notebookDir, storeRoot) = read else { return nil }

        let background = PageBackground(
            background: file.background, backgroundType: file.backgroundType)
        var template = NativeTemplate.blank
        if case .native(let native) = background, native.isDrawable { template = native }
        let strip = NextPagePreviewRenderer.content(
            strokes: PencilKitBridge.drawing(from: file.strokes),
            images: BackgroundRenderer.pageImages(for: file, notebookDir: notebookDir),
            pageSize: file.pageSize)
        return NextPagePreview(
            pageId: neighborId,
            pageSize: file.pageSize,
            template: template,
            content: strip?.image,
            contentHeight: strip?.height ?? 0,
            background: BackgroundRenderer.image(
                for: file, notebookDir: notebookDir, storeRoot: storeRoot))
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
        guard remoteInkPending, !liveState.isDrawing, let pageId, let store else { return }
        saveNow()
        // A failed flush leaves `dirty` set, and reloading now would replace the drawing with
        // the file and clear it — throwing away exactly the strokes the save alert just promised
        // were safe, and cancelling their retry with them. `remoteInkPending` stays set, so the
        // fold runs again at the next pencil-lift or apply, once a save has landed.
        guard !dirty else { return }
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
        self.page = page
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

        init(of page: PageFile) {
            images = page.images
            background = page.background
            backgroundType = page.backgroundType
            pageWidth = page.pageWidth
            pageHeight = page.pageHeight
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

    func scheduleSave() {
        dirty = true
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { saveNow() }
        }
    }

    func saveNow() {
        saveTask?.cancel()
        guard var page, let store else { return }
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
        do {
            let written = try store.savePage(page, baselineStrokeIDs: baseline)
            // Only now that the write landed. The baseline has to keep naming what the canvas
            // held at the last save that *worked*: advancing it before the `try` meant a failed
            // save still consumed an erasure — the erased stroke was no longer in the baseline,
            // so the successful retry derived no tombstone for it and the fold against the file
            // resurrected it. The exported canvas set, deliberately not `written.strokes` — the
            // mismatch between the two is how `foldInRemoteInk` detects ink that arrived from
            // the other device underneath this save.
            canvasStrokeIDs = Set(page.strokes.map(\.id))
            // Take back what was written rather than what was offered: `savePage` reconciles
            // against the file, so only the returned copy matches what is now on disk. That is
            // what `page` is supposed to be, and `page.strokes` is the `source:` the next export
            // re-identifies against. On failure `self.page` stays untouched for the same reason:
            // it still carries the last truly-written DTOs.
            self.page = written
            dirty = false
        } catch {
            // Leave `dirty` set so the next flush retries. Clearing it on a failed write — which
            // is what `try?` did — silently discarded the strokes that failed to land.
            saveError = String(describing: error)
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
