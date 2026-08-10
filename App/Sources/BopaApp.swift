import SwiftUI

@main
struct BopaApp: App {
    @StateObject private var store = NotebookStore()
    @StateObject private var syncCoordinator = SyncCoordinator()
    @StateObject private var handwriting = HandwritingSettings()
    @StateObject private var backendHost = SyncBackendHost()
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
                .environmentObject(backendHost)
                .task {
                    // Attached here rather than in init: SwiftUI creates the scene's state
                    // objects independently, so the host cannot take them as constructor
                    // arguments.
                    backendHost.attach(store: store, coordinator: syncCoordinator)
                }
                .onChange(of: scenePhase, initial: true) { _, phase in
                    switch phase {
                    case .active:
                        backendHost.becameActive()
                    case .background:
                        backendHost.enteredBackground()
                    default:
                        backendHost.willResignActive()
                    }
                }
                // WebDAV learns about edits here; CouchDB hears through the store's per-document
                // signal instead, which says which documents changed rather than just that
                // something did.
                .onReceive(NotificationCenter.default.publisher(
                    for: NotebookStore.didChangeLocallyNotification)
                ) { _ in
                    backendHost.noteEdited()
                }
                .onReceive(NotificationCenter.default.publisher(
                    for: CouchSettings.didChangeNotification)
                ) { _ in
                    backendHost.configure()
                    if scenePhase == .active { backendHost.becameActive() }
                }
            }
        }
    }
}
