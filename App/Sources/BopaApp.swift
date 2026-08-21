import SwiftUI

@main
struct BopaApp: App {
    @StateObject private var store = NotebookStore()
    @StateObject private var syncCoordinator = SyncCoordinator()
    @StateObject private var handwriting = HandwritingSettings()
    @StateObject private var backendHost = SyncBackendHost()
    @State private var recognition: RecognitionController?
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            if CommandLine.arguments.contains("--bare-canvas") {
                DiagnosticHost()
            } else {
                // No NavigationStack: the library is two plain columns and the editor is
                // presented full screen, so nothing here pushes.
                ZStack(alignment: .top) {
                    LibraryView()
                    SyncStatusCapsule()
                }
                .environmentObject(store)
                .environmentObject(syncCoordinator)
                .environmentObject(handwriting)
                .environmentObject(backendHost)
                .tint(Modernist.ink)
                // The Modernist tokens describe one ground — a light one. There is no dark
                // variant to switch to, and half of the chrome inverting while the paper
                // stays paper would be worse than not following the system at all.
                .preferredColorScheme(.light)
                .task {
                    // Attached here rather than in init: SwiftUI creates the scene's state
                    // objects independently, so the host cannot take them as constructor
                    // arguments.
                    backendHost.attach(store: store, coordinator: syncCoordinator)
                    // Same reason: the controller needs the store SwiftUI has just made.
                    let controller = RecognitionController(store: store)
                    recognition = controller
                    controller.start()
                }
                .onChange(of: scenePhase, initial: true) { _, phase in
                    switch phase {
                    case .active:
                        backendHost.becameActive()
                        // Text recognized while offline has been waiting for a network; this is
                        // the moment there is most likely to be one.
                        Task { await recognition?.publishPending() }
                    case .background:
                        backendHost.enteredBackground()
                        // Recognition waits out a quiet period the app may not stay awake for.
                        recognition?.flush()
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
                // A WebDAV address was added or cleared. Only the library's sync button cares, so
                // this re-reads that rather than rebuilding the CouchDB stack underneath it.
                .onReceive(NotificationCenter.default.publisher(
                    for: SyncSettings.didChangeNotification)
                ) { _ in
                    backendHost.refreshWebDAVConfiguration()
                }
            }
        }
    }
}
