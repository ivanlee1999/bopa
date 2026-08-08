import SwiftUI

@main
struct BopaApp: App {
    @StateObject private var store = NotebookStore()

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                LibraryView()
            }
            .environmentObject(store)
        }
    }
}
