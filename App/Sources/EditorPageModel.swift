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

    /// Connects the store, the way the undo controller attaches to the undo manager — SwiftUI
    /// builds its state objects before the environment is readable, so this cannot be an
    /// initializer. Also where the model starts listening for sync writing under its feet.
    func attach(store: NotebookStore, notebookId: String) {
        guard self.store == nil else { return }
        self.store = store
        self.notebookId = notebookId
        // The CouchDB pull loop rewrites page files with no regard for what is open, so the
        // editor has to hear about it or it would keep drawing on a stale copy.
        NotificationCenter.default.addObserver(
            self, selector: #selector(storeDidApplyRemoteChanges),
            name: NotebookStore.didApplyRemoteChangesNotification, object: nil)
    }

    @objc private func storeDidApplyRemoteChanges() {
        remoteInkPending = true
        foldInRemoteInk()
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
            canvasStrokeIDs = Set(loaded.strokes.map(\.id))
            contentRevision += 1
            // Seed with the persisted offset so a save before any scroll preserves it.
            liveState.pageY = CGFloat(max(loaded.scroll, 0))
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
        // Most applied documents are some other page, or this page's own echo. Reloading for those
        // would throw away the undo stack for nothing.
        guard arrived || erasedElsewhere else {
            remoteInkPending = false  // the canvas already matches the file
            return
        }
        if open(pageId: pageId) { remoteInkPending = false }
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
