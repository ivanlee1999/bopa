import Foundation
import NotableKit
import SwiftUI

/// Which sync transport bopa uses. Exactly one is live at a time, and `off` means none is —
/// this is the single switch every sync path consults, so selecting one backend genuinely
/// silences the other rather than merely hiding its settings.
///
/// WebDAV stays available while CouchDB is proven out; the intent is for CouchDB to become the
/// only option.
enum SyncBackend: String, CaseIterable, Identifiable {
    case off
    case webdav
    case couchdb

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return "Off"
        case .webdav: return "WebDAV"
        case .couchdb: return "CouchDB"
        }
    }
}

/// CouchDB connection settings. URL, database, username and device id live in UserDefaults;
/// the password lives in the Keychain, as with `SyncSettings`.
struct CouchSettings: Equatable {
    static let backendKey = "sync.backend"
    static let urlKey = "couch.serverURL"
    static let databaseKey = "couch.database"
    static let usernameKey = "couch.username"
    static let deviceIDKey = "couch.deviceID"
    static let keychainAccount = "dev.ivan.bopa.couchdb"

    static let didChangeNotification = Notification.Name("dev.ivan.bopa.couchSettingsDidChange")

    var serverURL: String
    var database: String
    var username: String
    var password: String
    /// Identifies this device in every document it writes. Must differ from the BOOX's, because
    /// it is the tiebreak when two edits share a millisecond.
    var deviceID: String

    static var backend: SyncBackend {
        get {
            UserDefaults.standard.string(forKey: backendKey)
                .flatMap(SyncBackend.init(rawValue:)) ?? .webdav
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: backendKey) }
    }

    static func load() -> CouchSettings {
        CouchSettings(
            serverURL: UserDefaults.standard.string(forKey: urlKey) ?? "",
            database: UserDefaults.standard.string(forKey: databaseKey) ?? "notes",
            username: UserDefaults.standard.string(forKey: usernameKey) ?? "",
            password: Keychain.load(account: keychainAccount) ?? "",
            deviceID: UserDefaults.standard.string(forKey: deviceIDKey) ?? defaultDeviceID)
    }

    func save() {
        UserDefaults.standard.set(serverURL, forKey: Self.urlKey)
        UserDefaults.standard.set(database.isEmpty ? "notes" : database, forKey: Self.databaseKey)
        UserDefaults.standard.set(username, forKey: Self.usernameKey)
        UserDefaults.standard.set(
            deviceID.isEmpty ? Self.defaultDeviceID : deviceID, forKey: Self.deviceIDKey)
        Keychain.save(account: Self.keychainAccount, value: password)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    /// "ipad" by default, to pair with notable's "boox". Distinctness is what matters, not the
    /// spelling — two devices sharing an id would break the merge's tiebreak.
    static let defaultDeviceID = "ipad"

    var isConfigured: Bool {
        URL(string: serverURL)?.scheme?.hasPrefix("http") == true && !database.isEmpty
    }

    /// Warns about the one misconfiguration that silently breaks merging.
    var deviceIDWarning: String? {
        deviceID.trimmingCharacters(in: .whitespaces).isEmpty
            ? "Give this device a name. It identifies your edits when two devices change the "
                + "same page at once."
            : nil
    }

    func makeClient() -> CouchDBClient? {
        guard isConfigured, let url = URL(string: serverURL) else { return nil }
        return CouchDBClient(
            transport: URLSessionTransport(
                baseURL: url,
                username: username.isEmpty ? nil : username,
                password: password.isEmpty ? nil : password),
            database: database)
    }
}

// MARK: - Assembly

/// Builds the store, engine and controller as one unit, since they must share a device id and a
/// state file. Returns nil until CouchDB is configured.
///
/// Not main-actor isolated: the engine persists its state from whatever context a sync runs on,
/// so the load/save pair has to be callable from off the main actor.
enum CouchSyncStack {
    /// Where this server's sync state lives. Named after the server and database, because that is
    /// what the state describes: `lastSeq` is a position in *one* server's change feed, and the
    /// revisions are that server's revisions.
    ///
    /// All of it used to live in a single file, so pointing the app at a different server — or a
    /// different database on the same one — handed the new server the old one's checkpoint. A
    /// foreign `since` skips changes rather than failing loudly, and stale revisions suppress real
    /// updates as though they were this device's own echoes.
    ///
    /// Credentials and the device id are deliberately *not* part of the name: changing a password
    /// does not change what is on the server, and discarding the checkpoint would mean replaying
    /// the whole feed for nothing.
    ///
    /// Hashed to keep a URL's punctuation out of a file name. Anyone upgrading replays from the
    /// start once, which is slow and correct rather than fast and wrong.
    static func stateFileName(for settings: CouchSettings) -> String {
        let identity = [endpointIdentity(settings.serverURL), settings.database]
            // NUL-separated, so a value that contains the separator cannot forge a name matching a
            // different configuration.
            .joined(separator: "\0")
        return ".bopa-couch-state-\(CouchAssetID.sha256Hex(Data(identity.utf8))).json"
    }

    /// The part of a server address that says *which server*, with the differences that are not
    /// differences folded away: a trailing slash and the case of the scheme and host are how the
    /// same endpoint gets typed twice, and re-typing it must not throw the checkpoint away.
    /// Userinfo is dropped for the same reason the password is — it is a credential, not a place.
    private static func endpointIdentity(_ serverURL: String) -> String {
        let trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed) else { return trimmed }
        components.user = nil
        components.password = nil
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        while components.path.hasSuffix("/") { components.path.removeLast() }
        return components.string ?? trimmed
    }

    /// - Parameter onState: every sync state the engine persists, plus the one it starts from.
    ///   The state carries the rev map, which is this backend's record of what the server holds —
    ///   the fact the library's provenance badges are drawn from. Reporting the loaded state too
    ///   is what makes those badges right on launch, before anything has synced this session.
    @MainActor
    static func make(
        settings: CouchSettings = .load(), rootURL: URL, onChange: @escaping @Sendable () -> Void,
        onState: (@Sendable (CouchSyncState) -> Void)? = nil
    ) -> (store: FileCouchStore, engine: CouchSyncEngine, controller: CouchSyncController)? {
        guard let client = settings.makeClient() else { return nil }

        let store = FileCouchStore(rootURL: rootURL, deviceID: settings.deviceID)
        store.didApplyChanges = onChange

        let stateURL = rootURL.appendingPathComponent(stateFileName(for: settings))
        let initialState = loadState(stateURL)
        onState?(initialState)
        let engine = CouchSyncEngine(
            client: client, store: store, deviceID: settings.deviceID,
            state: initialState,
            onStateChange: { state in
                save(state, to: stateURL)
                onState?(state)
            })
        return (store, engine, CouchSyncController(engine: engine))
    }

    /// A missing or unreadable state file is not an error: every document re-pushes and the feed
    /// replays from the start, which is slow but correct because the merges are idempotent.
    static func loadState(_ url: URL) -> CouchSyncState {
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(CouchSyncState.self, from: data)
        else { return CouchSyncState() }
        return state
    }

    static func save(_ state: CouchSyncState, to url: URL) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
