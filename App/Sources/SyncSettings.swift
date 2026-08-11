import Foundation
import NotableKit
import Security
import SwiftUI

/// WebDAV connection settings. Server URL + username live in UserDefaults; the password
/// lives in the Keychain.
struct SyncSettings: Equatable {
    static let serverKey = "sync.serverURL"
    static let usernameKey = "sync.username"
    static let automaticKey = "sync.automatic"
    static let keychainAccount = "dev.ivan.bopa.webdav"

    /// Whether bopa syncs on its own. Defaults to **on** — an absent key is not "off", it is a
    /// user who has never had an opinion, and a note app that only syncs when asked is the thing
    /// this setting exists to avoid. Kept off `SyncSettings` proper so reading it never touches
    /// the Keychain.
    static var isAutomaticEnabled: Bool {
        get { UserDefaults.standard.object(forKey: automaticKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: automaticKey) }
    }

    /// Posted by `save()`. Views holding a loaded copy re-read on this rather than on a
    /// sheet's `onDismiss`: the settings form writes in its own `onDisappear`, which SwiftUI
    /// runs *after* the presenter's dismiss handler, so reloading there reads stale values.
    static let didChangeNotification = Notification.Name("dev.ivan.bopa.syncSettingsDidChange")

    var serverURL: String
    var username: String
    var password: String

    static func load() -> SyncSettings {
        SyncSettings(
            serverURL: UserDefaults.standard.string(forKey: serverKey) ?? "",
            username: UserDefaults.standard.string(forKey: usernameKey) ?? "",
            password: Keychain.load(account: keychainAccount) ?? "")
    }

    func save() {
        UserDefaults.standard.set(serverURL, forKey: Self.serverKey)
        UserDefaults.standard.set(username, forKey: Self.usernameKey)
        Keychain.save(account: Self.keychainAccount, value: password)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    var isConfigured: Bool {
        Self.isServerAddress(serverURL)
    }

    /// Whether a server address has been saved, without loading the whole settings object.
    /// `load()` reads the Keychain, which is too much to do from a SwiftUI body that re-renders
    /// on every store change — the sidebar's sync button only needs to know if syncing is possible.
    static var isServerConfigured: Bool {
        isServerAddress(UserDefaults.standard.string(forKey: serverKey) ?? "")
    }

    static func isServerAddress(_ string: String) -> Bool {
        URL(string: string)?.scheme?.hasPrefix("http") == true
    }

    /// Transport for the sync engine, rooted at the *resolved* base (see `syncBaseURL`) rather than
    /// the raw `serverURL`, so pointing at the `notable` folder itself works as well as pointing at
    /// its parent.
    func makeTransport() -> URLSessionTransport? {
        guard isConfigured, let url = syncBaseURL else { return nil }
        return URLSessionTransport(
            baseURL: url,
            username: username.isEmpty ? nil : username,
            password: password.isEmpty ? nil : password)
    }
}

// MARK: - Browsing

extension SyncSettings {
    /// `serverURL` parsed leniently: a missing scheme is assumed to be https so "host/path"
    /// typed by hand still resolves.
    private var parsedComponents: URLComponents? {
        let trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let components = URLComponents(string: trimmed), components.scheme != nil {
            return components
        }
        return URLComponents(string: "https://" + trimmed)
    }

    /// `scheme://host[:port]`, with any path stripped. The folder picker browses from here so
    /// the entire share is reachable, not just the subtree the user happened to type.
    var hostRootURL: URL? {
        guard var components = parsedComponents,
              components.scheme?.hasPrefix("http") == true,
              let host = components.host, !host.isEmpty
        else { return nil }
        components.percentEncodedPath = ""
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        return components.url
    }

    /// Currently chosen folder as a server-absolute, percent-**decoded** path — the same
    /// currency `WebDAVClient`/`DavResource` use. "/" when the URL carries no path.
    var remotePath: String {
        RemotePath.normalize(parsedComponents?.path ?? "")
    }

    /// Right-hand text of the "Folder" row.
    var remotePathDisplay: String {
        hostRootURL == nil ? "Not set" : remotePath
    }

    // MARK: Sync root resolution

    /// The chosen folder with a trailing `notable` segment resolved away — what the sync transport
    /// is actually rooted at.
    ///
    /// Derived, never stored: a `serverURL` saved before this rule existed heals itself on the next
    /// sync, without the user re-picking anything.
    var syncRemotePath: String { RemotePath.syncBase(remotePath) }

    /// The shared tree itself. The same string whether the user picked the parent or the `notable`
    /// folder, which is what makes it safe to show as "where your notebooks live".
    var syncTreePath: String { RemotePath.syncTree(remotePath) }

    /// True when the user pointed at the `notable` folder itself and we resolved upward. Drives the
    /// disclosure text — the resolution should be visible, not magic.
    var didResolveSyncRoot: Bool { syncRemotePath != remotePath }

    /// `serverURL` with only its path rewritten to `syncRemotePath`.
    ///
    /// Built from `parsedComponents` rather than `hostRootURL` so a port, query, fragment or inline
    /// credentials survive exactly as they do today.
    var syncBaseURL: URL? {
        guard var components = parsedComponents else { return nil }
        let resolved = RemotePath.syncBase(components.path)
        // `.urlPathAllowed` keeps "/" literal and encodes spaces and non-ASCII as UTF-8 — the same
        // recipe as RemotePath.absoluteURLString, so "/Mes documents" round-trips.
        components.percentEncodedPath = resolved == RemotePath.root
            ? ""
            : (resolved.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? resolved)
        return components.url
    }

    /// A host plus Basic-auth credentials are the minimum needed to PROPFIND anything.
    var canBrowse: Bool {
        hostRootURL != nil && !username.isEmpty && !password.isEmpty
    }

    /// Transport rooted at the host so `WebDAVClient.list` can be handed absolute server
    /// paths. Credentials are carried across verbatim from the same fields the sync engine uses.
    func makeBrowsingTransport() -> URLSessionTransport? {
        guard let hostRootURL else { return nil }
        return URLSessionTransport(
            baseURL: hostRootURL,
            username: username.isEmpty ? nil : username,
            password: password.isEmpty ? nil : password)
    }
}

enum Keychain {
    static func save(account: String, value: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var attributes = query
        attributes[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func load(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - UI

struct SyncSettingsView: View {
    @EnvironmentObject private var store: NotebookStore
    @EnvironmentObject private var coordinator: SyncCoordinator
    @Environment(\.dismiss) private var dismiss

    @State private var settings = SyncSettings.load()
    @State private var couchSettings = CouchSettings.load()
    @State private var backend = CouchSettings.backend
    @State private var automatic = SyncSettings.isAutomaticEnabled
    @State private var showingFolderPicker = false

    /// Set by the app so the CouchDB section can drive syncs. Nil in previews and in tests that
    /// render the form on its own.
    var backendHost: SyncBackendHost?

    var body: some View {
        Form {
            Section {
                Picker("Sync with", selection: $backend) {
                    ForEach(SyncBackend.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: backend) { _, newValue in
                    CouchSettings.backend = newValue
                    // Post through the CouchDB channel either way: the app rebuilds whichever
                    // backend is now selected, and stops the other one.
                    NotificationCenter.default.post(
                        name: CouchSettings.didChangeNotification, object: nil)
                }
                .accessibilityIdentifier("sync.backend")
            } footer: {
                Text(backendFooter)
            }

            switch backend {
            case .off:
                EmptyView()
            case .couchdb:
                CouchSettingsSection(settings: $couchSettings, host: backendHost)
            case .webdav:
                webdavSections
            }
        }
        .navigationTitle("Sync")
        .navigationDestination(isPresented: $showingFolderPicker) {
            RemoteFolderPicker(settings: $settings)
        }
        .onDisappear {
            settings.save()
            couchSettings.save()
        }
    }

    /// What the chosen backend means, including the promise Off makes: the settings for the other
    /// two are kept, but nothing runs against them until one is chosen again.
    private var backendFooter: String {
        switch backend {
        case .off:
            return "bopa keeps your notes on this iPad only. Your server settings are kept, so "
                + "turning sync back on picks up where you left off."
        case .couchdb:
            return "Changes appear on your other device within a second or two, and merge "
                + "automatically when you have both been writing offline."
        case .webdav:
            return "Syncs whole notebooks through a shared folder. Slower to notice changes, "
                + "and edits made on both devices at once need sorting out by hand."
        }
    }

    @ViewBuilder
    private var webdavSections: some View {
        Group {
            Section("WebDAV server") {
                TextField("https://server/dav", text: $settings.serverURL)
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
                TextField("Username", text: $settings.username)
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
                SecureField("Password", text: $settings.password)
            }
            Section {
                // Alternative to typing the URL above, not a replacement: the picker just
                // rewrites the same `serverURL` field.
                Button {
                    settings.save()
                    showingFolderPicker = true
                } label: {
                    HStack {
                        Text("Folder")
                            .foregroundStyle(.primary)
                        Spacer(minLength: 12)
                        Text(settings.remotePathDisplay)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .disabled(!settings.canBrowse)
                .accessibilityIdentifier("sync.folderRow")

                NavigationLink {
                    ServerBrowserView(settings: settings)
                } label: {
                    Label("Browse server", systemImage: "externaldrive.connected.to.line.below")
                }
                .disabled(!settings.canBrowse)
                .accessibilityIdentifier("sync.browseServer")
            } footer: {
                Text(folderFooter)
            }
            Section {
                Toggle("Sync automatically", isOn: $automatic)
                    .onChange(of: automatic) { _, enabled in
                        SyncSettings.isAutomaticEnabled = enabled
                        if enabled {
                            coordinator.startAutoSync(store: store)
                        } else {
                            coordinator.stopAutoSync()
                        }
                    }
                    .accessibilityIdentifier("sync.automatic")
            } footer: {
                Text(automatic
                    ? "bopa checks the server every couple of minutes while it is open, and pushes "
                        + "your changes shortly after you stop writing."
                    : "bopa only syncs when you tap Sync now.")
            }
            Section {
                Button {
                    settings.save()
                    Task { await coordinator.syncNow(store: store) }
                } label: {
                    if coordinator.isSyncing {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Syncing…")
                        }
                    } else {
                        Label("Sync now", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .disabled(!settings.isConfigured || coordinator.isSyncing)
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if let detail = coordinator.statusDetail {
                        Text(detail)
                    }
                    // Only meaningful once the root is resolved: it names the tree bopa really
                    // looked in, which is the one thing the user needs to match on the BOOX.
                    if coordinator.lastRunFoundNothing {
                        Text("bopa found nothing in “\(settings.syncTreePath)”. If your BOOX already "
                            + "has notebooks, point Notable at “\(settings.syncRemotePath)” too.")
                    }
                }
            }
        }
    }

    /// Spells out the resolution when the chosen folder *is* the shared tree, so the Folder row and
    /// the tree bopa syncs never silently disagree.
    private var folderFooter: String {
        guard settings.canBrowse else {
            return "Fill in the address, username and password to browse the server."
        }
        return settings.didResolveSyncRoot
            ? "That is the shared folder itself, so bopa syncs straight to it. Point Notable on the "
                + "BOOX at “\(settings.syncRemotePath)”."
            : "Browse the server to pick the folder bopa and Notable share. Notebooks live in "
                + "“\(settings.syncTreePath)”."
    }
}
