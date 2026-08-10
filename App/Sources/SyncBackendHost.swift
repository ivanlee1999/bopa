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

    /// Rebuilds the CouchDB stack from current settings. Safe to call repeatedly.
    func configure() {
        backend = CouchSettings.backend
        guard let store else { return }
        couch?.stop()
        couch = nil
        engine = nil
        couchStore = nil

        guard backend == .couchdb else {
            store.didChangeDocuments = nil
            return
        }

        let settings = CouchSettings.load()
        store.deviceID = settings.deviceID
        guard let stack = CouchSyncStack.make(
            settings: settings, rootURL: store.rootURL,
            onChange: { [weak store] in
                // The engine applies changes off the main actor; the library has to be told on it.
                Task { @MainActor in store?.refresh() }
            })
        else {
            store.didChangeDocuments = nil
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
        case .webdav:
            guard let store, let coordinator else { return }
            await coordinator.syncNow(store: store)
        case .couchdb:
            await couch?.syncNow()
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

    var statusDetail: String? {
        backend == .couchdb ? couch?.statusDetail : coordinator?.statusDetail
    }
}
