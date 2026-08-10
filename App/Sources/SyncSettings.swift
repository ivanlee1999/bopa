import Foundation
import NotableKit
import Security
import SwiftUI

/// WebDAV connection settings. Server URL + username live in UserDefaults; the password
/// lives in the Keychain.
struct SyncSettings: Equatable {
    static let serverKey = "sync.serverURL"
    static let usernameKey = "sync.username"
    static let keychainAccount = "dev.ivan.bopa.webdav"

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
        URL(string: serverURL)?.scheme?.hasPrefix("http") == true
    }

    func makeTransport() -> URLSessionTransport? {
        guard isConfigured, let url = URL(string: serverURL) else { return nil }
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
    @State private var showingFolderPicker = false

    var body: some View {
        Form {
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
            } footer: {
                Text(settings.canBrowse
                    ? "Browse the server to pick the folder bopa and Notable share."
                    : "Fill in the address, username and password to browse the server.")
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
                if let detail = coordinator.statusDetail {
                    Text(detail)
                }
            }
        }
        .navigationTitle("Sync")
        .navigationDestination(isPresented: $showingFolderPicker) {
            RemoteFolderPicker(settings: $settings)
        }
        .onDisappear { settings.save() }
    }
}
