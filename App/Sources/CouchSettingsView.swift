import NotableKit
import SwiftUI

/// Reconfiguration replaces the controller; observe the host as well as the controller below.
struct HostedCouchSettingsSection: View {
    @Binding var settings: CouchSettings
    @ObservedObject var host: SyncBackendHost

    var body: some View {
        CouchSettingsSection(settings: $settings, host: host)
    }
}

/// CouchDB connection form. Shown in place of the WebDAV fields when the CouchDB backend is
/// selected.
struct CouchSettingsSection: View {
    @Binding var settings: CouchSettings
    @EnvironmentObject private var store: NotebookStore

    let host: SyncBackendHost?

    @State private var isSeeding = false
    @State private var isSyncRequested = false

    var body: some View {
        // First, above the server configuration. A wrong clock corrupts merge outcomes on *both*
        // devices, and the footer sentence it used to share is the one people scroll past.
        if let couch = host?.couch {
            ClockSkewSection(controller: couch)
        }

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

        if let couch = host?.couch {
            ObservedCouchSyncStatus(controller: couch) { isSyncing, detail in
                syncActions(isSyncing: isSyncing, detail: detail)
            }
        } else {
            syncActions(isSyncing: false, detail: nil)
        }
    }

    private func syncActions(isSyncing: Bool, detail: String?) -> some View {
        let busy = isSyncing || isSyncRequested || isSeeding
        return Section {
            Button {
                isSyncRequested = true
                settings.save()
                Task {
                    await host?.syncNow()
                    isSyncRequested = false
                }
            } label: {
                if isSyncing || isSyncRequested {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Syncing…")
                    }
                } else {
                    Label("Sync now", systemImage: "arrow.triangle.2.circlepath")
                }
            }
            .disabled(host == nil || !settings.isConfigured || busy)
            .accessibilityIdentifier("couch.syncNow")

            Button {
                isSeeding = true
                settings.save()
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
                    Label("Upload all notebooks", systemImage: "arrow.up.doc")
                }
            }
            .disabled(host == nil || !settings.isConfigured || busy)
            .accessibilityIdentifier("couch.uploadAll")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if let detail {
                    Text(detail)
                        .accessibilityIdentifier("couch.syncStatus")
                }
                // The first sync against a fresh server has nothing queued, because nothing has
                // changed since it was configured — so seeding has to be something you can ask for.
                Text("Upload all notebooks sends the notebooks, pages and folders on this device "
                    + "to a new server. After that, changes sync automatically when connected.")
            }
        }
    }
}

/// Sync failures and progress can change without changing a notebook or the settings form.
private struct ObservedCouchSyncStatus<Content: View>: View {
    @ObservedObject var controller: CouchSyncController
    @ViewBuilder var content: (Bool, String?) -> Content

    var body: some View {
        content(controller.isSyncing, controller.statusDetail)
    }
}

/// The mass-deletion guard's prompt (protocol §6.7).
///
/// The guard holds a suspiciously large batch of notebook deletions rather than publishing it,
/// because a wiped local database looks exactly like a user who deleted everything. Only a person
/// can tell those apart, so this is where they say which it was — and until they do, the held
/// tombstones sit in the outbox and everything else goes on syncing.
///
/// The persistent clock warning. Its own view for the same reason `HeldDeletionsSection` is: it has
/// to appear and disappear as the measurement moves, which a one-shot read of `host` would not do.
///
/// There is nothing to dismiss and no button to offer — the only fix is in the Settings app, which
/// nothing here can reach, and nothing on this card stops being true by being read.
private struct ClockSkewSection: View {
    @ObservedObject var controller: CouchSyncController

    /// Shown well above the 120s at which a skew is *recorded*. That threshold is loose enough to
    /// absorb a slow link, and a banner that fires for a round-trip hiccup is one that gets ignored
    /// when it matters.
    private var isSevere: Bool {
        guard let skew = controller.clockSkew else { return false }
        return abs(skew.seconds) >= SyncClock.warningSeconds
    }

    var body: some View {
        if isSevere, let skew = controller.clockSkew {
            Section {
                Label {
                    Text("This device’s clock is wrong")
                        .font(.headline)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .accessibilityIdentifier("couch.clockSkew.title")

                Text(skew.summary)
                    .font(.callout)
                    .accessibilityIdentifier("couch.clockSkew.detail")
            } footer: {
                Text("Open your device’s date and time settings and set the time automatically. Bopa "
                    + "corrects new edits for the difference, but edits already made carry the "
                    + "wrong time and your other devices cannot correct them.")
            }
        }
    }
}

/// Split into its own view purely to observe the controller: the section has to appear when a
/// flush finds a batch and vanish when the choice is made.
private struct HeldDeletionsSection: View {
    @ObservedObject var controller: CouchSyncController
    @State private var showingDeleteConfirmation = false
    @State private var deletionsToConfirm: [String] = []

    var body: some View {
        if !controller.heldDeletions.isEmpty {
            Section {
                Button {
                    Task { await controller.discardHeldDeletions() }
                } label: {
                    Label("Keep them on the server", systemImage: "arrow.uturn.backward")
                }
                .accessibilityIdentifier("couch.deletions.keep")

                Button(role: .destructive) {
                    deletionsToConfirm = controller.heldDeletions
                    showingDeleteConfirmation = true
                } label: {
                    Label("Delete them on the server too", systemImage: "trash")
                }
                .accessibilityIdentifier("couch.deletions.approve")
            } header: {
                Text("Deletions on hold")
            } footer: {
                Text(explanation)
            }
            .confirmationDialog(
                "Delete on the server?",
                isPresented: $showingDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete on the server", role: .destructive) {
                    let confirmed = deletionsToConfirm
                    Task { @MainActor in
                        // A changed batch needs a fresh confirmation, even if its count matches.
                        guard controller.heldDeletions == confirmed else { return }
                        await controller.approveHeldDeletions()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Delete \(deletionsToConfirm.count) notebook\(deletionsToConfirm.count == 1 ? "" : "s") "
                    + "from the server and your other synced devices? These are the notebooks "
                    + "already deleted here. This cannot be undone.")
            }
            .onChange(of: controller.heldDeletions) { _, _ in
                showingDeleteConfirmation = false
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
        return "\(notebooks) deleted on this device — most of the library — have not been sent to "
            + "the server yet, in case this device lost its notes rather than you deleting them.\n\n"
            + "Delete them on the server too removes them from your other devices as well.\n\n"
            + "Keep them on the server forgets the deletions on this device instead. Those "
            + "notebooks are still on the server, so they come back here on the next sync."
    }
}
