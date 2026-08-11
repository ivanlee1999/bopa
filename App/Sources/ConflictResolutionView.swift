import NotableKit
import SwiftUI

/// Settles a notebook that was changed on this iPad and on the BOOX since they last agreed.
///
/// Opened *instead of* the editor when a notebook is conflicted, which is what Notable does on the
/// BOOX — so the same situation looks the same on both devices. Nothing has been transferred by the
/// time this appears: both copies are intact, and they stay that way until a choice is made.
///
/// KNOWN ISSUE — applying a decision does not yet take effect against a real server. The
/// rebaseline itself is correct and persists (verified against `rclone serve webdav`: after
/// "Keep my version" the stored manifest ETag matches the server's current one and the local
/// anchor is older than the local `updatedAt`, which is exactly the state the planner turns into
/// an upload), but the sync that follows does not transfer. The engine-level equivalents —
/// `testKeepMineUploadsOnTheNextRun` and `testUseRemoteReplacesTheLocalCopyAndSettles` — pass
/// against `MockWebDAVServer`, so the fault is somewhere the mock does not model. Detection is
/// unaffected and is the part that protects data: a conflicted notebook is never written to on
/// either side. Do not ship the resolution buttons as working until this is understood.
struct ConflictResolutionView: View {
    @EnvironmentObject private var store: NotebookStore
    @EnvironmentObject private var coordinator: SyncCoordinator
    @Environment(\.dismiss) private var dismiss

    let conflict: NotebookConflict

    @State private var pageChoices: [String: PageResolution] = [:]
    @State private var applying = false
    @State private var applyError: String?

    private var title: String {
        store.manifest(id: conflict.notebookId)?.title ?? "This notebook"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("“\(title)” was changed here and on your BOOX since they last agreed. "
                        + "Nothing has been copied either way yet.")
                        .font(.callout)
                } header: {
                    Label("Both devices changed this", systemImage: "exclamationmark.triangle")
                }

                if conflict.structural {
                    structuralSection
                } else {
                    pageSection
                }
            }
            .navigationTitle("Resolve conflict")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Later") { dismiss() }
                        .accessibilityIdentifier("conflict.later")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if applying {
                        ProgressView()
                    } else if !conflict.structural {
                        Button("Apply") { apply() }
                            .disabled(pageChoices.isEmpty)
                            .accessibilityIdentifier("conflict.apply")
                    }
                }
            }
            .alert("Couldn’t apply that", isPresented: .constant(applyError != nil)) {
                Button("OK") { applyError = nil }
            } message: {
                Text(applyError ?? "")
            }
        }
    }

    /// Pages added, removed or reordered — there is no per-page answer to give, because the two
    /// notebooks no longer describe the same set of pages.
    private var structuralSection: some View {
        Section {
            Button {
                resolveNotebook(.keepMine)
            } label: {
                Label("Keep my version", systemImage: "ipad")
            }
            .accessibilityIdentifier("conflict.keepMine")
            Button {
                resolveNotebook(.useRemote)
            } label: {
                Label("Use the BOOX version", systemImage: "tablet")
            }
            .accessibilityIdentifier("conflict.useRemote")
        } footer: {
            Text("The two versions disagree about the notebook itself — pages added, removed or "
                + "reordered, or its title or paper changed. That has to be settled as a whole.")
        }
        .disabled(applying)
    }

    private var pageSection: some View {
        Section {
            ForEach(Array(conflict.pageIds.enumerated()), id: \.element) { index, pageId in
                Picker(pageLabel(for: pageId, fallbackIndex: index), selection: choice(for: pageId)) {
                    Text("Keep mine").tag(PageResolution.keepMine)
                    Text("Use BOOX").tag(PageResolution.useRemote)
                    Text("Decide later").tag(PageResolution.skip)
                }
                .pickerStyle(.menu)
            }
        } header: {
            Text("\(conflict.pageIds.count) page\(conflict.pageIds.count == 1 ? "" : "s") "
                + "edited on both")
        } footer: {
            Text("Pages you changed on only one device are already merged — these are the ones "
                + "written on both. Anything left as “Decide later” is asked again next sync.")
        }
        .disabled(applying)
    }

    /// Page number rather than the raw uuid, matching how Notable labels the same list.
    private func pageLabel(for pageId: String, fallbackIndex: Int) -> String {
        guard let pageIds = store.manifest(id: conflict.notebookId)?.pageIds,
              let position = pageIds.firstIndex(of: pageId)
        else { return "Page \(fallbackIndex + 1)" }
        return "Page \(position + 1)"
    }

    private func choice(for pageId: String) -> Binding<PageResolution> {
        Binding(
            get: { pageChoices[pageId] ?? .skip },
            set: { pageChoices[pageId] = $0 })
    }

    private func apply() {
        run { engine in
            for (pageId, resolution) in pageChoices where resolution != .skip {
                try await engine.resolvePage(
                    notebookId: conflict.notebookId, pageId: pageId, resolution: resolution)
            }
        }
    }

    private func resolveNotebook(_ resolution: NotebookResolution) {
        run { engine in
            try await engine.resolveNotebook(
                notebookId: conflict.notebookId, resolution: resolution)
        }
    }

    /// Applies a decision and syncs it. Goes through the coordinator so the rebaseline and the
    /// transfer share one in-flight slot — a poll landing between them would otherwise undo the
    /// decision by rewriting the sync state it just adjusted.
    private func run(_ body: @escaping (SyncEngine) async throws -> Void) {
        applying = true
        Task {
            do {
                try await coordinator.applyResolution(store: store, body)
                applying = false
                dismiss()
            } catch {
                applying = false
                // An error that wrote a message for the user gets to show it; anything else falls
                // back to its structure. `localizedDescription` is not the fallback: on a plain
                // Swift error it yields "The operation couldn't be completed", which says less
                // than `WebDAVError.badURL("…")` does.
                applyError = (error as? LocalizedError)?.errorDescription
                    ?? String(describing: error)
            }
        }
    }
}
