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

        // Only rendered when there is something on hold, and only this subview observes the
        // controller: the choice has to appear and disappear as the guard decides, which a
        // one-shot read of `host` would not do.
        if let couch = host?.couch {
            HeldDeletionsSection(controller: couch)
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

/// The mass-deletion guard's prompt (protocol §6.7).
///
/// The guard holds a suspiciously large batch of notebook deletions rather than publishing it,
/// because a wiped local database looks exactly like a user who deleted everything. Only a person
/// can tell those apart, so this is where they say which it was — and until they do, the held
/// tombstones sit in the outbox and everything else goes on syncing.
///
/// Split into its own view purely to observe the controller: the section has to appear when a
/// flush finds a batch and vanish when the choice is made.
private struct HeldDeletionsSection: View {
    @ObservedObject var controller: CouchSyncController

    var body: some View {
        if !controller.heldDeletions.isEmpty {
            Section {
                Button(role: .destructive) {
                    Task { await controller.approveHeldDeletions() }
                } label: {
                    Label("Delete them on the server too", systemImage: "trash")
                }
                .accessibilityIdentifier("couch.deletions.approve")

                Button {
                    Task { await controller.discardHeldDeletions() }
                } label: {
                    Label("Keep them on the server", systemImage: "arrow.uturn.backward")
                }
                .accessibilityIdentifier("couch.deletions.keep")
            } header: {
                Text("Deletions on hold")
            } footer: {
                Text(explanation)
            }
        }
    }

    /// Both outcomes stated plainly, including the one that is easy to read as "cancel": keeping
    /// them on the server means they come back here. That is the recovery path for a device whose
    /// database was wiped, so the user has to know it before choosing — it is the feature, not a
    /// side effect to be surprised by afterwards.
    private var explanation: String {
        let count = controller.heldDeletions.count
        let notebooks = count == 1 ? "1 notebook" : "\(count) notebooks"
        return "\(notebooks) deleted on this iPad — most of the library — have not been sent to "
            + "the server yet, in case this iPad lost its notes rather than you deleting them.\n\n"
            + "Delete them on the server too removes them from your other devices as well.\n\n"
            + "Keep them on the server forgets the deletions on this iPad instead. Those "
            + "notebooks are still on the server, so they come back here on the next sync."
    }
}
