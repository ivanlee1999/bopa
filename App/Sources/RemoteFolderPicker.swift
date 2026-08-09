import Foundation
import NotableKit
import SwiftUI

// MARK: - Path arithmetic

/// Server-absolute WebDAV paths, held **percent-decoded** everywhere in this file.
///
/// That is the same currency `DavResource.path` uses (MultistatusParser decodes hrefs) and the
/// same currency `URLSessionTransport` expects (it percent-encodes `HTTPRequest.path` itself).
/// Keeping one representation is what makes folder names with spaces and non-ASCII work: we
/// never double-encode, and we never compare an encoded path against a decoded one.
enum RemotePath {
    static let root = "/"

    /// Leading slash, no trailing slash, empty => "/".
    static func normalize(_ path: String) -> String {
        var p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty else { return root }
        if !p.hasPrefix("/") { p = "/" + p }
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        return p
    }

    static func components(_ path: String) -> [String] {
        normalize(path).split(separator: "/").map(String.init)
    }

    static func child(_ parent: String, name: String) -> String {
        let base = normalize(parent)
        let leaf = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !leaf.isEmpty else { return base }
        return base == root ? root + leaf : base + "/" + leaf
    }

    static func parent(_ path: String) -> String {
        let parts = components(path)
        guard parts.count > 1 else { return root }
        return root + parts.dropLast().joined(separator: "/")
    }

    /// Absolute URL string for `path` under `hostRoot` — this is what lands in
    /// `SyncSettings.serverURL`, so it must be percent-encoded and round-trip back through
    /// `SyncSettings.remotePath` unchanged.
    static func absoluteURLString(hostRoot: URL, path: String) -> String {
        let p = normalize(path)
        guard var components = URLComponents(url: hostRoot, resolvingAgainstBaseURL: false) else {
            return hostRoot.absoluteString
        }
        components.query = nil
        components.fragment = nil
        if p == root {
            components.percentEncodedPath = ""
        } else {
            // `.urlPathAllowed` keeps "/" literal and encodes spaces, "%", "#", "?" and every
            // non-ASCII scalar as UTF-8 — exactly what URLSessionTransport does to request paths.
            components.percentEncodedPath =
                p.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? p
        }
        return components.url?.absoluteString ?? hostRoot.absoluteString
    }
}

// MARK: - Error text

enum RemoteBrowseError {
    /// Human-readable text for the failure banner. Status codes the user can act on get their
    /// own sentence; everything else falls back to a generic line that still names the code.
    static func message(for error: Error) -> String {
        switch error {
        case let dav as WebDAVError:
            switch dav {
            case .notFound(let path):
                return "Folder not found on the server (404): \(path). It may have been renamed or deleted."
            case .unexpectedStatus(let status, _):
                return message(forStatus: status)
            case .preconditionFailed:
                return "The server rejected the change (412). Try again."
            case .malformedMultistatus:
                return "The server replied with something that isn’t a WebDAV listing."
            case .badURL(let value):
                return "Invalid server address: \(value)"
            }
        case let urlError as URLError:
            return "Couldn’t reach the server: \(urlError.localizedDescription)"
        default:
            return error.localizedDescription
        }
    }

    static func message(forStatus status: Int) -> String {
        switch status {
        case 401:
            return "Sign-in failed (401). Check the username and password."
        case 403:
            return "Access denied (403). This account can’t open that folder."
        case 404:
            return "Folder not found (404). It may have been renamed or deleted."
        case 405:
            return "The server doesn’t allow that here (405)."
        case 409:
            return "The server refused to create the folder (409) — its parent may be missing."
        case 507:
            return "The server is out of space (507)."
        default:
            return "The server returned an unexpected error (\(status))."
        }
    }
}

// MARK: - Browser model

/// Drives one browsing session: current path, its listing, and MKCOL.
///
/// Only PROPFIND (`WebDAVClient.list`) and MKCOL are ever issued — no HEAD or GET on
/// collections, because this user's Synology behind Cloudflare answers 403 to those.
@MainActor
final class RemoteFolderBrowserModel: ObservableObject {
    struct Entry: Identifiable, Equatable {
        var id: String { path }
        var name: String
        var path: String
        var isCollection: Bool
    }

    struct Crumb: Identifiable, Equatable {
        var id: String { path }
        var name: String
        var path: String
    }

    enum LoadState: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    @Published private(set) var path: String
    @Published private(set) var entries: [Entry] = []
    @Published private(set) var state: LoadState = .loading
    @Published private(set) var isCreating = false
    @Published var actionError: String?

    private let client: WebDAVClient?
    /// Guards against a slow listing for an old path landing after the user moved on.
    private var loadToken = 0

    init(transport: HTTPTransport?, startPath: String) {
        self.client = transport.map(WebDAVClient.init(transport:))
        self.path = RemotePath.normalize(startPath)
    }

    var isAtRoot: Bool { path == RemotePath.root }
    var collections: [Entry] { entries.filter(\.isCollection) }
    var files: [Entry] { entries.filter { !$0.isCollection } }

    /// "Server" stands in for the host root, which has no name of its own.
    var breadcrumbs: [Crumb] {
        var crumbs = [Crumb(name: "Server", path: RemotePath.root)]
        var accumulated = ""
        for component in RemotePath.components(path) {
            accumulated += "/" + component
            crumbs.append(Crumb(name: component, path: accumulated))
        }
        return crumbs
    }

    func load() async {
        guard let client else {
            state = .failed("Enter the server address, username and password first.")
            return
        }
        loadToken += 1
        let token = loadToken
        state = .loading
        entries = []
        do {
            let resources = try await client.list(path)
            guard token == loadToken else { return }
            entries = Self.sorted(resources)
            state = .loaded
        } catch {
            guard token == loadToken else { return }
            state = .failed(RemoteBrowseError.message(for: error))
        }
    }

    func open(_ entry: Entry) async {
        guard entry.isCollection else { return }
        path = RemotePath.normalize(entry.path)
        await load()
    }

    func goUp() async {
        guard !isAtRoot else { return }
        path = RemotePath.parent(path)
        await load()
    }

    func go(to newPath: String) async {
        let target = RemotePath.normalize(newPath)
        guard target != path else { return }
        path = target
        await load()
    }

    /// MKCOL inside the current folder, then re-list. `WebDAVClient.makeCollection` swallows
    /// 405 ("already exists"), so duplicates are caught locally against the listing instead —
    /// otherwise the user would get a silent no-op.
    func createFolder(named rawName: String) async {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let client, !name.isEmpty else { return }
        guard !name.contains("/") else {
            actionError = "Folder names can’t contain “/”."
            return
        }
        if entries.contains(where: { $0.name.compare(name, options: .caseInsensitive) == .orderedSame }) {
            actionError = "“\(name)” already exists here."
            return
        }
        isCreating = true
        defer { isCreating = false }
        do {
            try await client.makeCollection(RemotePath.child(path, name: name))
        } catch {
            actionError = RemoteBrowseError.message(for: error)
            return
        }
        await load()
    }

    /// Collections first, then files; both cases sorted the way Finder would.
    private static func sorted(_ resources: [DavResource]) -> [Entry] {
        resources
            .map { Entry(name: $0.name, path: RemotePath.normalize($0.path), isCollection: $0.isCollection) }
            .sorted {
                if $0.isCollection != $1.isCollection { return $0.isCollection }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }
}

// MARK: - UI

/// Browses the WebDAV share and writes the chosen folder back into `SyncSettings.serverURL`.
///
/// Browsing always starts at the host root (scheme://host) with the current setting's path
/// preselected, so the whole share is reachable even when the saved URL points deep into it.
struct RemoteFolderPicker: View {
    @Binding var settings: SyncSettings
    @Environment(\.dismiss) private var dismiss

    @StateObject private var model: RemoteFolderBrowserModel
    private let hostRoot: URL?

    @State private var showingNewFolder = false
    @State private var newFolderName = ""

    init(settings: Binding<SyncSettings>) {
        _settings = settings
        let snapshot = settings.wrappedValue
        hostRoot = snapshot.hostRootURL
        _model = StateObject(wrappedValue: RemoteFolderBrowserModel(
            transport: snapshot.makeBrowsingTransport(),
            startPath: snapshot.remotePath))
    }

    var body: some View {
        VStack(spacing: 0) {
            pathBar
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
                        folderRows
                        fileRows
                    }
                }
            }
            .listStyle(.plain)
        }
        .safeAreaInset(edge: .bottom) { bottomBar }
        .navigationTitle("Choose folder")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    newFolderName = ""
                    showingNewFolder = true
                } label: {
                    Label("New folder…", systemImage: "folder.badge.plus")
                }
                .disabled(model.state != .loaded || model.isCreating)
                .accessibilityIdentifier("folderPicker.newFolder")
            }
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    Task { await model.goUp() }
                } label: {
                    Label("Up", systemImage: "arrow.up")
                }
                .disabled(model.isAtRoot)
                .accessibilityIdentifier("folderPicker.up")
            }
        }
        .task { await model.load() }
        .alert("New folder", isPresented: $showingNewFolder) {
            TextField("Name", text: $newFolderName)
                .autocorrectionDisabled()
            Button("Cancel", role: .cancel) { newFolderName = "" }
            Button("Create") {
                let name = newFolderName
                newFolderName = ""
                Task { await model.createFolder(named: name) }
            }
        } message: {
            Text("Creates a folder inside \(model.path).")
        }
        .alert("Couldn’t do that", isPresented: actionErrorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.actionError ?? "")
        }
    }

    private var pathBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(model.breadcrumbs.enumerated()), id: \.element.id) { index, crumb in
                        if index > 0 {
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Button(crumb.name) { Task { await model.go(to: crumb.path) } }
                            .font(.subheadline)
                            .disabled(crumb.path == model.path)
                    }
                }
                .padding(.horizontal, 16)
            }
            Text(model.path)
                .font(.footnote.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
                .padding(.horizontal, 16)
                .accessibilityIdentifier("folderPicker.currentPath")
        }
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var folderRows: some View {
        ForEach(model.collections) { entry in
            Button {
                Task { await model.open(entry) }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "folder")
                        .foregroundStyle(Color.accentColor)
                    Text(entry.name)
                        .foregroundStyle(.primary)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
        }
    }

    /// Files are listed but dimmed and inert. Hiding them entirely would leave a folder full of
    /// documents looking identical to an empty one, which makes "am I in the right place?"
    /// impossible to answer; dimming says "visible, not selectable" without another explanation.
    private var fileRows: some View {
        ForEach(model.files) { entry in
            HStack(spacing: 10) {
                Image(systemName: "doc")
                Text(entry.name)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.tertiary)
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 8) {
            Button {
                if let hostRoot {
                    settings.serverURL = RemotePath.absoluteURLString(hostRoot: hostRoot, path: model.path)
                    settings.save()
                }
                dismiss()
            } label: {
                Text("Use this folder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(hostRoot == nil || model.state != .loaded)
            .accessibilityIdentifier("folderPicker.use")

            Text("bopa creates and uses a “notable” subfolder inside the folder you choose. "
                + "Point Notable on the BOOX at the same folder so both apps share it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(16)
        .background(.bar)
    }

    private var actionErrorBinding: Binding<Bool> {
        Binding(
            get: { model.actionError != nil },
            set: { if !$0 { model.actionError = nil } })
    }
}
