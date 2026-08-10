import NotableKit
import SwiftUI

/// CouchDB connection form. Shown in place of the WebDAV fields when the CouchDB backend is
/// selected.
struct CouchSettingsSection: View {
    @Binding var settings: CouchSettings
    @EnvironmentObject private var store: NotebookStore

    let host: SyncBackendHost?

    @State private var isSeeding = false

    var body: some View {
        Section("CouchDB server") {
            TextField("https://couch.example.com", text: $settings.serverURL)
                .textContentType(.URL)
                .keyboardType(.URL)
                .autocapitalization(.none)
                .autocorrectionDisabled()
                .accessibilityIdentifier("couch.serverURL")
            TextField("Database", text: $settings.database)
                .autocapitalization(.none)
                .autocorrectionDisabled()
                .accessibilityIdentifier("couch.database")
            TextField("Username", text: $settings.username)
                .autocapitalization(.none)
                .autocorrectionDisabled()
                .accessibilityIdentifier("couch.username")
            SecureField("Password", text: $settings.password)
                .accessibilityIdentifier("couch.password")
        }

        Section {
            TextField("This device", text: $settings.deviceID)
                .autocapitalization(.none)
                .autocorrectionDisabled()
                .accessibilityIdentifier("couch.deviceID")
        } footer: {
            Text(settings.deviceIDWarning
                ?? "Names this device in your notes. Give each device a different name — it is "
                    + "what decides the winner when both change the same thing at the same moment.")
        }

        Section {
            Button {
                settings.save()
                Task { await host?.syncNow() }
            } label: {
                Label("Sync now", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(!settings.isConfigured)

            Button {
                settings.save()
                isSeeding = true
                Task {
                    await host?.pushEverything()
                    isSeeding = false
                }
            } label: {
                if isSeeding {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Uploading…")
                    }
                } else {
                    Label("Upload everything on this iPad", systemImage: "arrow.up.doc")
                }
            }
            .disabled(!settings.isConfigured || isSeeding)
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if let detail = host?.statusDetail {
                    Text(detail)
                }
                // The first sync against a fresh server has nothing queued, because nothing has
                // changed since it was configured — so seeding has to be something you can ask for.
                Text("Upload everything sends every notebook on this iPad, for the first sync "
                    + "against a new server. After that, changes sync on their own.")
            }
        }
    }
}
