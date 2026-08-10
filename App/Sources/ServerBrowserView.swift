import NotableKit
import SwiftUI

/// A read-only look at the WebDAV share itself — the actual files and folders, not the library.
///
/// This is a diagnostic, which is why it lives in sync settings rather than the sidebar: synced
/// notebooks are ordinary notes in the library, so the only question the raw tree answers is "is
/// my stuff really there, and am I pointed at it?". Reached from the "Browse server" row, which is
/// disabled until `canBrowse`, so the credentials are known good by the time we get here.
struct ServerBrowserView: View {
    /// Passed in from the settings form rather than reloaded, so the address being typed one screen
    /// back is the address browsed here — including edits not yet written to UserDefaults.
    let settings: SyncSettings

    var body: some View {
        ServerBrowser(settings: settings)
            .navigationTitle("Server")
    }
}

/// One browsing session over the share, rooted at the host so the whole server is reachable
/// even when the sync folder sits deep inside it.
private struct ServerBrowser: View {
    let settings: SyncSettings

    @StateObject private var model: RemoteFolderBrowserModel
    /// The tree sync actually reads, so the row for it can be called out. Resolved, not the raw
    /// chosen path — otherwise picking the `notable` folder would badge `<chosen>/notable/notable`,
    /// a directory that no longer exists.
    private let syncTreePath: String

    init(settings: SyncSettings) {
        self.settings = settings
        self.syncTreePath = settings.syncTreePath
        // Browsing starts where the user pointed, even when sync resolves elsewhere: that is the
        // folder they are trying to inspect.
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

    /// The shared tree, whichever spelling the user configured. Compared case-insensitively for the
    /// same reason `RemotePath.syncBase` matches that way.
    private func isSyncTree(_ path: String) -> Bool {
        RemotePath.normalize(path).compare(syncTreePath, options: .caseInsensitive) == .orderedSame
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Notebooks are read from “\(syncTreePath)”.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
            Text("Point Notable on the BOOX at “\(settings.syncRemotePath)”, then sync.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }
}
