import SwiftUI

@main
struct BopaApp: App {
    @StateObject private var store = NotebookStore()
    @StateObject private var syncCoordinator = SyncCoordinator()
    @StateObject private var handwriting = HandwritingSettings()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            if CommandLine.arguments.contains("--bare-canvas") {
                DiagnosticHost()
            } else {
                ZStack(alignment: .top) {
                    NavigationStack {
                        LibraryView()
                    }
                    SyncStatusCapsule()
                }
                .environmentObject(store)
                .environmentObject(syncCoordinator)
                .environmentObject(handwriting)
                .onChange(of: scenePhase, initial: true) { _, phase in
                    switch phase {
                    case .active:
                        Task { await syncCoordinator.syncIfStale(store: store) }
                        syncCoordinator.startAutoSync(store: store)
                    case .background:
                        // Stop the clock first, then take one last pass so work made in this
                        // session is on the server before the app is suspended. iOS may cut this
                        // short; the engine writes the manifest last, so a truncated run leaves
                        // the server recoverable on the next one.
                        syncCoordinator.stopAutoSync()
                        Task { await syncCoordinator.syncNow(store: store) }
                    default:
                        syncCoordinator.stopAutoSync()
                    }
                }
                // Local edits need no polling to be noticed — only a pause to be worth pushing.
                .onReceive(NotificationCenter.default.publisher(
                    for: NotebookStore.didChangeLocallyNotification)
                ) { _ in
                    syncCoordinator.noteEdited(store: store)
                }
            }
        }
    }
}
