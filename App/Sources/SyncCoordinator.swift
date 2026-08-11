import Foundation
import NotableKit
import SwiftUI

/// Owns the sync lifecycle for the app: serializes runs (never two concurrent syncs),
/// tracks status for the UI, and drives the WebDAV engine. The actual engine call is
/// injectable so tests can substitute a fake.
@MainActor
final class SyncCoordinator: ObservableObject {
    enum Status: Equatable {
        case idle
        case syncing
        case success(SyncReport, Date)
        case failure(String, Date)
    }

    /// Performs one sync run against `rootURL` using `settings`. `uploadOnly` carries the
    /// notebooks that must not be written to — see `SyncEngine.sync(uploadOnly:)`.
    typealias SyncOperation = @MainActor (SyncSettings, URL, Set<String>) async -> SyncReport

    /// Suspends for `seconds`. Injectable so the poll loop is testable without real time.
    typealias Sleeper = @Sendable (TimeInterval) async throws -> Void

    @Published private(set) var status: Status = .idle
    @Published private(set) var lastSyncedAt: Date?

    /// The notebook open in the editor, if any. Excluded from downloads for as long as it is
    /// open — the editor holds in-memory state that disk does not, so a download landing under it
    /// would be reverted by the next autosave and then uploaded as the winner.
    @Published var openNotebookId: String?

    /// Notebooks changed on both devices and awaiting a decision. Nothing has been transferred for
    /// these. Derived from the last run and deliberately not persisted.
    @Published private(set) var conflicts: [NotebookConflict] = []

    func conflict(for notebookId: String) -> NotebookConflict? {
        conflicts.first { $0.notebookId == notebookId }
    }

    /// When the most recent sync attempt started, successful or not. This is the
    /// staleness clock: counting attempts (not successes) means an unreachable server
    /// is retried at most once per interval instead of on every scene activation.
    private(set) var lastAttemptAt: Date?

    private let staleInterval: TimeInterval
    private let pollInterval: TimeInterval
    private let editQuietPeriod: TimeInterval
    private let now: @MainActor () -> Date
    private let loadSettings: @MainActor () -> SyncSettings
    private let isAutomaticEnabled: @MainActor () -> Bool
    private let isSelectedBackend: @MainActor () -> Bool
    private let performSync: SyncOperation
    private let sleeper: Sleeper

    private var pollTask: Task<Void, Never>?
    private var editPushTask: Task<Void, Never>?

    init(
        staleInterval: TimeInterval = 60,
        pollInterval: TimeInterval = 120,
        editQuietPeriod: TimeInterval = 20,
        now: @escaping @MainActor () -> Date = Date.init,
        loadSettings: @escaping @MainActor () -> SyncSettings = SyncSettings.load,
        isAutomaticEnabled: @escaping @MainActor () -> Bool = { SyncSettings.isAutomaticEnabled },
        isSelectedBackend: @escaping @MainActor () -> Bool = { CouchSettings.backend == .webdav },
        sleeper: @escaping Sleeper = { try await Task.sleep(for: .seconds($0)) },
        performSync: SyncOperation? = nil
    ) {
        self.staleInterval = staleInterval
        self.pollInterval = pollInterval
        self.editQuietPeriod = editQuietPeriod
        self.now = now
        self.loadSettings = loadSettings
        self.isAutomaticEnabled = isAutomaticEnabled
        self.isSelectedBackend = isSelectedBackend
        self.sleeper = sleeper
        self.performSync = performSync ?? { settings, rootURL, uploadOnly in
            guard let transport = settings.makeTransport() else {
                var report = SyncReport()
                report.errors.append("sync: server not configured")
                return report
            }
            let engine = SyncEngine(transport: transport, rootURL: rootURL)
            return await engine.sync(uploadOnly: uploadOnly)
        }
    }

    var isSyncing: Bool {
        if case .syncing = status { return true }
        return false
    }

    /// Whether WebDAV is the selected backend. Every run checks this, so switching to CouchDB (or
    /// to Off) stops WebDAV dead even on the paths that call the coordinator directly — a stray
    /// caller cannot reopen the case where two engines write the same notebooks at once.
    var isSelected: Bool { isSelectedBackend() }

    /// Runs a sync unless one is already in flight, WebDAV is not the selected backend, or no
    /// server is configured. `status` flips to `.syncing` before the first suspension point, so
    /// re-entrant calls on the main actor bail out here — runs never overlap.
    func syncNow(store: NotebookStore) async {
        guard !isSyncing, isSelectedBackend() else { return }
        let settings = loadSettings()
        guard settings.isConfigured else { return }
        // Claimed here, synchronously, before any await: that is the whole single-flight guard.
        status = .syncing
        await performRun(store: store, settings: settings)
    }

    /// Applies a conflict decision and syncs it, holding the in-flight slot across both.
    ///
    /// Doing this as "rebaseline, then call syncNow" is unsafe: a poll already running would make
    /// `syncNow` bail silently, and worse, that run loaded the sync state *before* the rebaseline
    /// and rewrites it on completion — quietly undoing the decision. So wait for any run to finish
    /// first, then keep the slot for the whole operation. Notable holds its sync mutex across the
    /// same two steps for the same reason.
    func applyResolution(
        store: NotebookStore, _ body: @escaping (SyncEngine) async throws -> Void
    ) async throws {
        guard isSelectedBackend() else { throw BackendNotSelected() }
        let settings = loadSettings()
        guard let transport = settings.makeTransport() else {
            throw WebDAVError.badURL(settings.serverURL)
        }
        // Claim the slot synchronously *before* the decision and hold it through the sync that
        // carries it out, so a poll cannot start in between and write pre-decision sync state
        // back over the rebaseline. A poll that is already running is a known gap — see the
        // KNOWN ISSUE note on `ConflictResolutionView`.
        guard !isSyncing else { throw ResolutionBusy() }
        status = .syncing
        do {
            try await body(SyncEngine(transport: transport, rootURL: store.rootURL))
        } catch {
            status = .idle
            throw error
        }
        await performRun(store: store, settings: settings)
    }

    /// A sync was already running, so the decision was not applied. Surfaced to the user rather
    /// than swallowed, because silently doing nothing is what made this hard to diagnose.
    struct ResolutionBusy: LocalizedError {
        var errorDescription: String? {
            "A sync is in progress. Try again in a moment."
        }
    }

    /// A WebDAV conflict was resolved while WebDAV is no longer the selected backend. The stale
    /// conflict list can outlive a backend switch, and applying its decision would mean writing to
    /// a server bopa has been told to leave alone.
    struct BackendNotSelected: LocalizedError {
        var errorDescription: String? {
            "WebDAV sync is turned off. Turn it back on in Settings to resolve this conflict."
        }
    }

    private func performRun(store: NotebookStore, settings: SyncSettings) async {
        lastAttemptAt = now()
        status = .syncing

        // Read once, here: the editor could close mid-run, and a notebook that was excluded when
        // the run started must stay excluded for the whole of it.
        let uploadOnly = openNotebookId.map { Set([$0]) } ?? []
        let report = await performSync(settings, store.rootURL, uploadOnly)
        let finishedAt = now()
        // Recomputed from scratch every run, never persisted: a conflict is a fact about the two
        // current copies, so a stale flag would be worse than none.
        conflicts = report.conflicts
        if Self.isFailure(report) {
            status = .failure(report.errors.joined(separator: "; "), finishedAt)
        } else {
            store.refresh()
            lastSyncedAt = finishedAt
            status = .success(report, finishedAt)
        }
    }

    /// Foreground trigger: syncs only when automatic sync is on, the server is configured, and the
    /// last attempt is older than `staleInterval` (60s by default).
    func syncIfStale(store: NotebookStore) async {
        guard isAutomaticEnabled() else { return }
        if let last = lastAttemptAt, now().timeIntervalSince(last) < staleInterval {
            return
        }
        await syncNow(store: store)
    }

    /// Any sync bopa decides to do on its own — on launch, on backgrounding, when an editor
    /// closes. Gated on the setting, because "Sync automatically: off" promises that bopa only
    /// syncs when asked, and a launch is not asking.
    func syncIfAutomatic(store: NotebookStore) async {
        guard isAutomaticEnabled() else { return }
        await syncNow(store: store)
    }

    // MARK: - Automatic sync

    /// Starts the poll loop. Idempotent — a second call while running is a no-op.
    ///
    /// WebDAV has no push, so the only way to learn about the BOOX's edits is to ask. Local edits
    /// need no polling (see `noteEdited`), which is why the two run on very different clocks.
    func startAutoSync(store: NotebookStore) {
        guard pollTask == nil else { return }
        let interval = pollInterval
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    guard let sleeper = self?.sleeper else { return }
                    try await sleeper(interval)
                } catch {
                    return  // cancelled
                }
                guard let self, !Task.isCancelled else { return }
                guard self.isAutomaticEnabled() else { continue }
                // A tick landing inside a long run is swallowed by syncNow's own guard.
                await self.syncNow(store: store)
            }
        }
    }

    func stopAutoSync() {
        pollTask?.cancel()
        pollTask = nil
        editPushTask?.cancel()
        editPushTask = nil
    }

    var isAutoSyncRunning: Bool { pollTask != nil }

    /// Signals that something changed locally. Pushes once the editing stops rather than
    /// immediately: `SyncEngine.upload` re-PUTs *every* page of a notebook, so syncing on each
    /// autosave would re-send a whole notebook every couple of seconds while someone is writing.
    /// Repeated calls coalesce — only the last one's timer survives.
    func noteEdited(store: NotebookStore) {
        guard isAutomaticEnabled() else { return }
        editPushTask?.cancel()
        let quiet = editQuietPeriod
        editPushTask = Task { [weak self] in
            do {
                guard let sleeper = self?.sleeper else { return }
                try await sleeper(quiet)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            await self.syncNow(store: store)
        }
    }

    /// A run counts as failed only when it produced errors and moved nothing at all;
    /// partial errors alongside real transfers still surface as a success report
    /// (the summary includes the error text either way).
    private static func isFailure(_ report: SyncReport) -> Bool {
        !report.errors.isEmpty
            && report.uploaded.isEmpty && report.downloaded.isEmpty
            && report.skipped.isEmpty && report.deletedLocally.isEmpty
    }

    /// One-line status detail for the sync settings footer.
    var statusDetail: String? {
        switch status {
        case .idle:
            guard let lastSyncedAt else { return nil }
            return "Last synced \(lastSyncedAt.formatted(.relative(presentation: .named)))"
        case .syncing:
            return "Syncing…"
        case .success(let report, _):
            return Self.summary(of: report)
        case .failure(let message, _):
            return "Sync failed: \(message)"
        }
    }

    static func summary(of report: SyncReport) -> String {
        var parts: [String] = []
        if !report.uploaded.isEmpty { parts.append("↑\(report.uploaded.count)") }
        if !report.downloaded.isEmpty { parts.append("↓\(report.downloaded.count)") }
        if !report.merged.isEmpty { parts.append("⇄\(report.merged.count)") }
        if !report.skipped.isEmpty { parts.append("=\(report.skipped.count)") }
        if !report.deletedLocally.isEmpty { parts.append("🗑\(report.deletedLocally.count)") }
        if !report.conflicts.isEmpty {
            let n = report.conflicts.count
            parts.append("⚠︎ \(n) notebook\(n == 1 ? "" : "s") need\(n == 1 ? "s" : "") you")
        }
        if !report.errors.isEmpty { parts.append("errors: \(report.errors.joined(separator: "; "))") }
        guard parts.isEmpty else { return parts.joined(separator: "  ") }
        return emptyRunSummary(for: report.remoteTree)
    }

    /// A run that moved nothing is ambiguous: it means "already in sync" on the right folder and
    /// "there is nothing here" on the wrong one, and the second is the far more likely reason a
    /// library looks empty. Naming which one it was is the whole point.
    static func emptyRunSummary(for tree: SyncReport.RemoteTreeState) -> String {
        switch tree {
        case .absent:
            return "Synced, but the folder was empty — bopa created the shared tree itself."
        case .empty:
            return "Synced, but there is nothing in the shared folder yet."
        case .populated, .unknown:
            return "Nothing to sync"
        }
    }

    /// Whether the last run found a shared tree that looks like nobody else is using it. Drives the
    /// hint in sync settings; deliberately not a failure, since a genuinely new setup looks the same.
    var lastRunFoundNothing: Bool {
        guard case .success(let report, _) = status else { return false }
        return report.remoteTree == .absent || report.remoteTree == .empty
    }
}

// MARK: - Status capsule

/// Small transient pill overlaid on the window: visible while syncing and for ~3s
/// after completion. Anchored top-center under the safe area because the bottom edge
/// belongs to the PencilKit tool picker, top-leading to the back button, and
/// top-trailing to the navigation toolbar buttons — top-center is empty in both the
/// library and the editor. Hit-testing is disabled so it never swallows touches.
struct SyncStatusCapsule: View {
    @EnvironmentObject private var coordinator: SyncCoordinator
    @State private var visible = false

    var body: some View {
        VStack {
            if visible, let text = capsuleText {
                HStack(spacing: 6) {
                    if coordinator.isSyncing {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(text)
                        .font(Modernist.font(11, .semibold))
                        .lineLimit(2)
                }
                .foregroundStyle(Modernist.paper)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                // A square ink chip, not a floating capsule: the one transient thing in
                // the app still has to look like it belongs to the same drawing.
                .background(Modernist.ink)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: 400)
        .padding(.top, 4)
        .allowsHitTesting(false)
        .task(id: coordinator.status) {
            switch coordinator.status {
            case .idle:
                withAnimation { visible = false }
            case .syncing:
                withAnimation { visible = true }
            case .success, .failure:
                withAnimation { visible = true }
                try? await Task.sleep(for: .seconds(3))
                if !Task.isCancelled {
                    withAnimation { visible = false }
                }
            }
        }
    }

    private var capsuleText: String? {
        switch coordinator.status {
        case .idle:
            return nil
        case .syncing:
            return "Syncing…"
        case .success(let report, _):
            var parts: [String] = []
            if !report.uploaded.isEmpty { parts.append("↑\(report.uploaded.count)") }
            if !report.downloaded.isEmpty { parts.append("↓\(report.downloaded.count)") }
            guard parts.isEmpty else { return "Synced: \(parts.joined(separator: " "))" }
            switch report.remoteTree {
            case .absent, .empty: return "Synced — the shared folder is empty"
            case .populated, .unknown: return "Synced"
            }
        case .failure(let message, _):
            return message
        }
    }
}
