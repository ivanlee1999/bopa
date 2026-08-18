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
            // Seed with the persisted offset so a save before any scroll preserves it.
            liveState.pageY = CGFloat(max(loaded.scroll, 0))
            lastKnownPageIds = store.manifest(id: notebookId)?.pageIds ?? []
            dirty = false
            loadError = nil
            return true
        } catch {
            loadError = String(describing: error)
            return false
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
