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

    init() {
        self.backend = CouchSettings.backend
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
        backend = CouchSettings.backend
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
            // Hand the library's badges back to the WebDAV index; under any other backend the
            // CouchDB rev map is either stale or about nothing.
            store.noteRemoteDocuments(nil)
            return
        }

        let settings = CouchSettings.load()
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
                let onServer = Set(
                    state.revs.keys.filter { id in
                        guard let type = CouchDocID.split(id)?.type else { return false }
                        return type == CouchDocType.notebook || type == CouchDocType.folder
                    })
                Task { @MainActor in store?.noteRemoteDocuments(onServer) }
            })
        else {
            store.didChangeDocuments = nil
            store.noteRemoteDocuments(nil)
            return
        }

        couchStore = stack.store
        engine = stack.engine
        couch = stack.controller

        // Every local mutation queues exactly the documents it touched, then starts the debounce.
        store.didChangeDocuments = { [weak self] documentIDs in
            guard let self, let engine = self.engine else { return }
            Task {
                await engine.markDirty(documentIDs)
                await MainActor.run { self.couch?.noteEdited() }
            }
        }
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
            Task { [couch] in await couch?.pushNow() }
        }
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

    /// Records a local deletion so a tombstone is pushed, including if it happened offline.
    func noteDeleted(notebookId: String) {
        couchStore?.recordDeletion(CouchDocID.notebook(notebookId))
    }

    /// A folder's deletion needs recording for the same reason a notebook's does: rewriting
    /// `folders.json` only says which folders remain, and "absent from a list" is not something the
    /// peer can tell apart from "not arrived yet". Without a tombstone the folder document stays
    /// live on the server and comes back the next time either device syncs.
    func noteDeleted(folderId: String) {
        couchStore?.recordDeletion(CouchDocID.folder(folderId))
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
