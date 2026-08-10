import NotableKit
import SwiftUI

/// What the sidebar's "Server" row opens: a read-only view of the WebDAV share itself —
/// the actual files and folders, not the synced library.
///
/// The library only ever shows notebooks that sync pulled down out of `<folder>/notable`,
/// so when nothing appears there the question is always "what is actually on the server,
/// and am I pointed at the right folder?". This answers it without leaving the app.
struct ServerBrowserView: View {
    @EnvironmentObject private var store: NotebookStore
    @EnvironmentObject private var coordinator: SyncCoordinator

    /// Re-read on appear and whenever the settings are saved, so editing the server address
    /// anywhere in the app is reflected here without a restart.
    @State private var settings = SyncSettings.load()
    /// Bumped alongside `settings` so the browser — and its transport — is rebuilt even when
    /// only the password changed, which the identity below cannot see.
    @State private var revision = 0
    @State private var showingSettings = false

    var body: some View {
        Group {
            if settings.hostRootURL == nil {
                ContentUnavailableView {
                    Label("No server yet", systemImage: "externaldrive.badge.questionmark")
                } description: {
                    Text("Add your WebDAV address, username and password to browse the server.")
                } actions: {
                    Button("Open sync settings") { showingSettings = true }
                        .buttonStyle(.borderedProminent)
                }
            } else if !settings.canBrowse {
                ContentUnavailableView {
                    Label("Sign-in needed", systemImage: "person.badge.key")
                } description: {
                    Text("Browsing the server needs a username and password.")
                } actions: {
                    Button("Open sync settings") { showingSettings = true }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                // `.id` rebuilds the browser — and its transport — when the settings change;
                // a StateObject would otherwise keep the stale one.
                ServerBrowser(settings: settings)
                    .id(revision)
            }
        }
        .navigationTitle("Server")
        .toolbar {
            Button {
                Task { await coordinator.syncNow(store: store) }
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
            }
            .disabled(!settings.isConfigured || coordinator.isSyncing)
            .accessibilityIdentifier("server.syncNow")
            Button {
                showingSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
            .accessibilityIdentifier("server.settings")
        }
        .sheet(isPresented: $showingSettings) {
            NavigationStack {
                SyncSettingsView()
            }
        }
        .onAppear { reload() }
        .onReceive(NotificationCenter.default.publisher(for: SyncSettings.didChangeNotification)) { _ in
            reload()
        }
    }

    private func reload() {
        let latest = SyncSettings.load()
        guard latest != settings else { return }
        settings = latest
        revision += 1
    }
}

/// One browsing session over the share, rooted at the host so the whole server is reachable
/// even when the sync folder sits deep inside it.
private struct ServerBrowser: View {
    let settings: SyncSettings

    @StateObject private var model: RemoteFolderBrowserModel
    /// The folder sync is pointed at, so rows under it can be called out as the shared tree.
    private let syncPath: String

    init(settings: SyncSettings) {
        self.settings = settings
        self.syncPath = settings.remotePath
        _model = StateObject(wrappedValue: RemoteFolderBrowserModel(
            transport: settings.makeBrowsingTransport(),
            startPath: settings.remotePath))
    }

    var body: some View {
        VStack(spacing: 0) {
            RemoteBreadcrumbBar(
                breadcrumbs: model.breadcrumbs, path: model.path,
                pathAccessibilityIdentifier: "server.currentPath",
                go: { path in Task { await model.go(to: path) } })
            Divider()
            List {
                switch model.state {
                case .loading:
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Loading…").foregroundStyle(.secondary)
                    }
                case .failed(let message):
                    VStack(alignment: .leading, spacing: 10) {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .font(.callout)
                        Button("Try again") { Task { await model.load() } }
                            .font(.callout)
                    }
                    .padding(.vertical, 4)
                case .loaded:
                    if model.entries.isEmpty {
                        Text("This folder is empty.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.collections) { entry in
                            folderRow(entry)
                        }
                        ForEach(model.files) { entry in
                            fileRow(entry)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .refreshable { await model.load() }
        }
        .safeAreaInset(edge: .bottom) { footer }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    Task { await model.goUp() }
                } label: {
                    Label("Up", systemImage: "arrow.up")
                }
                .disabled(model.isAtRoot)
                .accessibilityIdentifier("server.up")
            }
        }
        .task { await model.load() }
    }

    private func folderRow(_ entry: RemoteFolderBrowserModel.Entry) -> some View {
        Button {
            Task { await model.open(entry) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "folder")
                    .foregroundStyle(Color.accentColor)
                Text(entry.name)
                    .foregroundStyle(.primary)
                if isSyncTree(entry.path) {
                    Text("synced")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
    }

    /// Files are shown but inert — there is nothing to open here, and hiding them would make a
    /// folder full of documents look identical to an empty one.
    private func fileRow(_ entry: RemoteFolderBrowserModel.Entry) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "doc")
            Text(entry.name)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.tertiary)
    }

    /// The `notable` folder inside the chosen sync folder is the tree bopa and Notable share;
    /// everything else on the server is just along for the ride.
    private func isSyncTree(_ path: String) -> Bool {
        RemotePath.normalize(path) == RemotePath.child(syncPath, name: "notable")
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Sync folder: \(syncPath)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
            Text("Notebooks are read from “\(RemotePath.child(syncPath, name: "notable"))”. "
                + "Point Notable on the BOOX at the same folder, then sync.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }
}
