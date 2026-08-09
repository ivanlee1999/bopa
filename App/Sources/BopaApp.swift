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
                    guard phase == .active else { return }
                    Task { await syncCoordinator.syncIfStale(store: store) }
                }
            }
        }
    }
}
