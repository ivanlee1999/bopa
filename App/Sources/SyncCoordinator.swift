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

    /// Performs one sync run against `rootURL` using `settings`. The default builds a
    /// `SyncEngine` the same way SyncSettingsView used to.
    typealias SyncOperation = @MainActor (SyncSettings, URL) async -> SyncReport

    @Published private(set) var status: Status = .idle
    @Published private(set) var lastSyncedAt: Date?

    /// When the most recent sync attempt started, successful or not. This is the
    /// staleness clock: counting attempts (not successes) means an unreachable server
    /// is retried at most once per interval instead of on every scene activation.
    private(set) var lastAttemptAt: Date?

    private let staleInterval: TimeInterval
    private let now: @MainActor () -> Date
    private let loadSettings: @MainActor () -> SyncSettings
    private let performSync: SyncOperation

    init(
        staleInterval: TimeInterval = 60,
        now: @escaping @MainActor () -> Date = Date.init,
        loadSettings: @escaping @MainActor () -> SyncSettings = SyncSettings.load,
        performSync: SyncOperation? = nil
    ) {
        self.staleInterval = staleInterval
        self.now = now
        self.loadSettings = loadSettings
        self.performSync = performSync ?? { settings, rootURL in
            guard let transport = settings.makeTransport() else {
                var report = SyncReport()
                report.errors.append("sync: server not configured")
                return report
            }
            let engine = SyncEngine(transport: transport, rootURL: rootURL)
            return await engine.sync()
        }
    }

    var isSyncing: Bool {
        if case .syncing = status { return true }
        return false
    }

    /// Runs a sync unless one is already in flight or no server is configured.
    /// `status` flips to `.syncing` before the first suspension point, so re-entrant
    /// calls on the main actor bail out here — runs never overlap.
    func syncNow(store: NotebookStore) async {
        guard !isSyncing else { return }
        let settings = loadSettings()
        guard settings.isConfigured else { return }

        lastAttemptAt = now()
        status = .syncing

        let report = await performSync(settings, store.rootURL)
        let finishedAt = now()
        if Self.isFailure(report) {
            status = .failure(report.errors.joined(separator: "; "), finishedAt)
        } else {
            store.refresh()
            lastSyncedAt = finishedAt
            status = .success(report, finishedAt)
        }
    }

    /// Foreground trigger: syncs only when configured and the last attempt is older
    /// than `staleInterval` (60s by default).
    func syncIfStale(store: NotebookStore) async {
        if let last = lastAttemptAt, now().timeIntervalSince(last) < staleInterval {
            return
        }
        await syncNow(store: store)
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
        if !report.skipped.isEmpty { parts.append("=\(report.skipped.count)") }
        if !report.deletedLocally.isEmpty { parts.append("🗑\(report.deletedLocally.count)") }
        if !report.conflicts.isEmpty { parts.append("⚠︎ conflicts: \(report.conflicts.joined(separator: ", "))") }
        if !report.errors.isEmpty { parts.append("errors: \(report.errors.joined(separator: "; "))") }
        return parts.isEmpty ? "Nothing to sync" : parts.joined(separator: "  ")
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
                        .font(.caption)
                        .lineLimit(2)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.quaternary))
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
            return parts.isEmpty ? "Synced" : "Synced: \(parts.joined(separator: " "))"
        case .failure(let message, _):
            return message
        }
    }
}
