import Foundation
import NotableKit
import SwiftUI

/// Owns whichever sync backend is selected and translates the app's lifecycle into it.
///
/// Exists so `BopaApp` does not have to branch on the backend at every callsite: it says
/// "became active", "an edit happened", and this decides whether that means a WebDAV run or a
/// CouchDB pump. Rebuilding on a settings change is the whole reconfiguration path — the
/// CouchDB stack captures its device id and state file at construction.
@MainActor
final class SyncBackendHost: ObservableObject {
    @Published private(set) var backend: SyncBackend
    @Published private(set) var couch: CouchSyncController?

    /// Whether a WebDAV server address is saved. Published because the library's sync button is
    /// drawn from it, and `SyncSettings.load()` is too expensive to call from a SwiftUI body —
    /// it touches the Keychain.
    @Published private(set) var webdavConfigured = SyncSettings.isServerConfigured

    private var store: NotebookStore?
    private var coordinator: SyncCoordinator?
    private var engine: CouchSyncEngine?
    private var couchStore: FileCouchStore?

    /// Asks the system to hold the process open for the final flush. Injected so the lifecycle is
    /// testable; see `BackgroundFlushAssertion`.
    private let backgroundAssertion: any BackgroundFlushAssertion
    private var backgroundFlushToken: Int?
    private var backgroundFlush: Task<Void, Never>?

    /// Where the CouchDB settings come from, injected the way `SyncCoordinator` takes
    /// `loadSettings`. The password lives in the Keychain, and the Keychain is not available to a
    /// test host — `SecItemAdd` fails and `load` reads back nil — so a test that drove this class
    /// through `CouchSettings.load()` would build a stack with no password and see every request
    /// refused. That would make the real wiring untestable, which is exactly the wiring the
    /// app-layer end-to-end tests exist to check.
    private let loadSettings: @MainActor () -> CouchSettings

    /// Which backend is selected, read the same way. Injected for the same reason and one more: a
    /// test that instead *wrote* the real setting would leave the simulator pointed at CouchDB, and
    /// the write outlives the run — `UserDefaults` is flushed asynchronously, so even a careful
    /// restore in `tearDown` can be overtaken by the flush of the value it was undoing. The symptom
    /// is an unrelated WebDAV test failing on later runs for no visible reason.
    private let loadBackend: @MainActor () -> SyncBackend

    init(
        loadSettings: @escaping @MainActor () -> CouchSettings = CouchSettings.load,
        loadBackend: @escaping @MainActor () -> SyncBackend = { CouchSettings.backend },
        backgroundAssertion: any BackgroundFlushAssertion = UIKitBackgroundFlushAssertion()
    ) {
        self.loadSettings = loadSettings
        self.loadBackend = loadBackend
        self.backgroundAssertion = backgroundAssertion
        self.backend = loadBackend()
    }

    /// Connects the app's store and coordinator. Split from `init` because SwiftUI creates the
    /// scene's state objects independently, so this cannot take them as constructor arguments.
    func attach(store: NotebookStore, coordinator: SyncCoordinator) {
        guard self.store == nil else { return }
        self.store = store
        self.coordinator = coordinator
        configure()
    }

    /// Re-reads the WebDAV settings the UI depends on. Cheaper than `configure()`, which would
    /// tear down and rebuild the CouchDB stack for a change that has nothing to do with it.
    func refreshWebDAVConfiguration() {
        webdavConfigured = SyncSettings.isServerConfigured
    }

    /// Rebuilds the CouchDB stack from current settings. Safe to call repeatedly.
    func configure() {
        backend = loadBackend()
        webdavConfigured = SyncSettings.isServerConfigured
        guard let store else { return }
        couch?.stop()
        couch = nil
        engine = nil
        couchStore = nil
        // Whichever backend is now selected, the other one stops here rather than at its next
        // trigger: a poll loop left running would keep syncing over a backend switch.
        if backend != .webdav { coordinator?.stopAutoSync() }

        guard backend == .couchdb else {
            store.didChangeDocuments = nil
            store.didDeleteDocuments = nil
            // Hand the library's badges back to the WebDAV index; under any other backend the
            // CouchDB rev map is either stale or about nothing.
            store.noteRemoteDocuments(nil)
            return
        }

        let settings = loadSettings()
        store.deviceID = settings.deviceID
        guard let stack = CouchSyncStack.make(
            settings: settings, rootURL: store.rootURL,
            onChange: { [weak store] in
                // The engine applies changes off the main actor; the library has to be told on it.
                // The editor too: unlike the WebDAV run, this can rewrite the page someone is
                // drawing on, so "sync touched the disk" has to be an event and not just a refresh.
                Task { @MainActor in
                    store?.refresh()
                    NotificationCenter.default.post(
                        name: NotebookStore.didApplyRemoteChangesNotification, object: nil)
                }
            },
            onState: { [weak store] state in
                // Only the two kinds a badge asks about. Keeping pages and assets out holds this
                // to one entry per library item instead of one per drawn page.
                //
                // Matched on the prefix rather than by splitting each id: this runs over every
                // revision the device knows, on every state the engine persists, and splitting
                // would allocate two strings per page and per image to answer a question about
                // the first word.
                let notebooks = "\(CouchDocType.notebook):"
                let folders = "\(CouchDocType.folder):"
                let onServer = Set(
                    state.revs.keys.filter { $0.hasPrefix(notebooks) || $0.hasPrefix(folders) })
                Task { @MainActor in store?.noteRemoteDocuments(onServer) }
            })
        else {
            store.didChangeDocuments = nil
            store.didDeleteDocuments = nil
            store.noteRemoteDocuments(nil)
            return
        }

        couchStore = stack.store
        engine = stack.engine
        couch = stack.controller

        // A local deletion, recorded durably so the tombstone is pushed even if it happened
        // offline or the app dies before the next sync. Synchronous and ahead of the change
        // signal below, because by the time the store says a folder or notebook is gone it really
        // is gone from disk: a push that ran first would load nothing, read that as "never
        // created", and drop the id from the outbox — leaving the document live on the server.
        store.didDeleteDocuments = { [weak self] documentIDs in
            guard let couchStore = self?.couchStore else { return }
            for documentID in documentIDs { couchStore.recordDeletion(documentID) }
        }

        // Every local mutation queues exactly the documents it touched, then starts the debounce.
        store.didChangeDocuments = { [weak self] documentIDs in
            guard let self, let engine = self.engine else { return }
            Task {
                await engine.markDirty(documentIDs)
                await MainActor.run { self.couch?.noteEdited() }
            }
        }

        // Last, and only now that the queue above exists: anything thrown away before the Trash
        // was a published field left the peer still listing it, and nothing but this will ever
        // send it. A no-op on every launch after the first.
        store.republishStrandedTrashings()
    }

    // MARK: Lifecycle

    func becameActive() {
        guard let store, let coordinator else { return }
        switch backend {
        case .off:
            break
        case .webdav:
            Task { await coordinator.syncIfStale(store: store) }
            coordinator.startAutoSync(store: store)
        case .couchdb:
            couch?.start()
        }
    }

    func willResignActive() {
        coordinator?.stopAutoSync()
        couch?.stop()
    }

    /// Last chance before suspension. The push is per-document, so a truncated run leaves the
    /// remaining documents queued rather than a half-written notebook.
    func enteredBackground() {
        coordinator?.stopAutoSync()
        couch?.stop()
        switch backend {
        case .off:
            break
        case .webdav:
            guard let store, let coordinator else { return }
            Task { await coordinator.syncIfAutomatic(store: store) }
        case .couchdb:
            // Held for the flush, not for the feed. iOS suspends a backgrounded process whenever it
            // likes, and this `Task` was started with nothing asking the system to wait — the last
            // few strokes before someone closed the lid were the ones most likely to be cut off,
            // and the least likely to have been sent by anything else.
            //
            // The window is finite by design, so this is a better chance rather than a guarantee.
            // The outbox stays durable either way: whatever the flush did not reach is still queued
            // for the next launch.
            beginBackgroundFlush()
        }
    }

    /// Runs the final CouchDB flush inside a background assertion, releasing it exactly once.
    private func beginBackgroundFlush() {
        // Recorded before the flush starts, not after: `endBackgroundFlush` has to be able to find
        // this token from the moment anything could call it. A token assigned afterwards would be
        // assigned to a flush that had already finished releasing — and then never released.
        //
        // A nil token is not a reason to skip the work. The system refused the assertion (launched
        // into the background, budget spent); the flush still runs, just unprotected, exactly as it
        // did before this existed.
        backgroundFlushToken = backgroundAssertion.begin("CouchDB final flush") { [weak self] in
            // The system wants the time back. Stop starting new requests and let go — a document
            // interrupted mid-PUT is still dirty, and the next run re-sends it (and merges on the
            // 409 if the write did land).
            self?.backgroundFlush?.cancel()
            self?.endBackgroundFlush()
        }

        backgroundFlush = Task { [weak self, couch] in
            await couch?.pushNow()
            self?.endBackgroundFlush()
        }
    }

    /// Idempotent: completion and expiration race, and ending a `UIBackgroundTaskIdentifier` twice
    /// traps rather than failing quietly.
    private func endBackgroundFlush() {
        backgroundFlush = nil
        guard let token = backgroundFlushToken else { return }
        backgroundFlushToken = nil
        backgroundAssertion.end(token)
    }

    /// A local edit. WebDAV needs telling; CouchDB already heard through `didChangeDocuments`,
    /// which knows *which* documents changed and is therefore the better signal.
    func noteEdited() {
        guard backend == .webdav, let store, let coordinator else { return }
        coordinator.noteEdited(store: store)
    }

    func syncNow() async {
        switch backend {
        case .off:
            break
        case .webdav:
            guard let store, let coordinator else { return }
            await coordinator.syncNow(store: store)
        case .couchdb:
            await couch?.syncNow()
        }
    }

    /// A sync bopa decides to do on its own — closing a notebook, say. Same routing as `syncNow`,
    /// but each backend applies its own "only when asked" setting.
    func syncIfAutomatic() async {
        switch backend {
        case .off:
            break
        case .webdav:
            guard let store, let coordinator else { return }
            await coordinator.syncIfAutomatic(store: store)
        case .couchdb:
            await couch?.pushNow()
        }
    }

    /// Queues everything this device holds — the first sync after pointing at a new server, when
    /// nothing is dirty yet but nothing has been sent either.
    func pushEverything() async {
        guard backend == .couchdb, let engine, let couchStore else { return }
        await engine.markDirty(couchStore.allDocumentIDs())
        await couch?.pushNow()
    }

    var statusDetail: String? {
        switch backend {
        case .off: return nil
        case .webdav: return coordinator?.statusDetail
        case .couchdb: return couch?.statusDetail
        }
    }

    /// Whether a sync run is in flight on the selected backend. `false` when sync is off, so the
    /// UI's spinner and its "Sync now" button read from one place rather than each guessing.
    var isSyncing: Bool {
        switch backend {
        case .off: return false
        case .webdav: return coordinator?.isSyncing ?? false
        case .couchdb: return couch?.isSyncing ?? false
        }
    }

    /// Whether "Sync now" can do anything: a backend is selected *and* configured. Cheap enough
    /// for a SwiftUI body — neither branch touches the Keychain.
    var canSyncNow: Bool {
        switch backend {
        case .off: return false
        case .webdav: return webdavConfigured
        case .couchdb: return couch != nil
        }
    }

    /// Explains a dead "Sync now" button, or nil when there is nothing to explain. Names the
    /// backend that needs attention: under CouchDB, being told to add a WebDAV server is advice
    /// that leads nowhere.
    var unavailableReason: String? {
        guard !canSyncNow else { return nil }
        switch backend {
        case .off: return "Sync is turned off. Choose a backend in Settings."
        case .webdav: return "Add a WebDAV server in Settings to sync."
        case .couchdb: return "Add a CouchDB server in Settings to sync."
        }
    }
}
