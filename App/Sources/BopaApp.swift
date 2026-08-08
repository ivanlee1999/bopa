import SwiftUI

@main
struct BopaApp: App {
    @StateObject private var store = NotebookStore()

    var body: some Scene {
        WindowGroup {
            if CommandLine.arguments.contains("--bare-canvas") {
                DiagnosticHost()
            } else {
                NavigationStack {
                    LibraryView()
                }
                .environmentObject(store)
            }
        }
    }
}
