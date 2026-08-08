import Foundation
import NotableKit
import Security
import SwiftUI

/// WebDAV connection settings. Server URL + username live in UserDefaults; the password
/// lives in the Keychain.
struct SyncSettings {
    static let serverKey = "sync.serverURL"
    static let usernameKey = "sync.username"
    static let keychainAccount = "dev.ivan.bopa.webdav"

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
    @Environment(\.dismiss) private var dismiss

    @State private var settings = SyncSettings.load()
    @State private var syncing = false
    @State private var lastResult: String?

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
                Button {
                    Task { await syncNow() }
                } label: {
                    if syncing {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Syncing…")
                        }
                    } else {
                        Label("Sync now", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .disabled(!settings.isConfigured || syncing)
            } footer: {
                if let lastResult {
                    Text(lastResult)
                }
            }
        }
        .navigationTitle("Sync")
        .onDisappear { settings.save() }
    }

    @MainActor
    private func syncNow() async {
        settings.save()
        guard let transport = settings.makeTransport() else { return }
        syncing = true
        defer { syncing = false }

        let engine = SyncEngine(transport: transport, rootURL: store.rootURL)
        let report = await engine.sync()
        store.refresh()

        var parts: [String] = []
        if !report.uploaded.isEmpty { parts.append("↑\(report.uploaded.count)") }
        if !report.downloaded.isEmpty { parts.append("↓\(report.downloaded.count)") }
        if !report.skipped.isEmpty { parts.append("=\(report.skipped.count)") }
        if !report.deletedLocally.isEmpty { parts.append("🗑\(report.deletedLocally.count)") }
        if !report.conflicts.isEmpty { parts.append("⚠︎ conflicts: \(report.conflicts.joined(separator: ", "))") }
        if !report.errors.isEmpty { parts.append("errors: \(report.errors.joined(separator: "; "))") }
        lastResult = parts.isEmpty ? "Nothing to sync" : parts.joined(separator: "  ")
    }
}
