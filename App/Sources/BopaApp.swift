import SwiftUI

@main
struct BopaApp: App {
    #if targetEnvironment(macCatalyst)
    // Only for the scene delegate that sizes the window; see `MacWindow.swift`.
    @UIApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate
    #endif
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
                // A WebDAV address was added or cleared. Only the library's sync button cares, so
                // this re-reads that rather than rebuilding the CouchDB stack underneath it.
                .onReceive(NotificationCenter.default.publisher(
                    for: SyncSettings.didChangeNotification)
                ) { _ in
                    backendHost.refreshWebDAVConfiguration()
                }
            }
        }
        #if targetEnvironment(macCatalyst)
        .commands { NotebookAppCommands() }
        #endif
    }
}

/// Scene-scoped commands follow the active library/editor and are removed while a modal
/// form is open. PencilKit keeps its own undo, redo, copy, and paste responder commands.
struct LibraryMenuActions {
    let newNotebook: () -> Void
    let newFolder: () -> Void
    let search: () -> Void
    let settings: () -> Void
    let toggleFolders: () -> Void
}

struct EditorMenuActions {
    let pages: () -> Void
    let close: () -> Void
}

private struct LibraryMenuActionsKey: FocusedValueKey {
    typealias Value = LibraryMenuActions
}

private struct EditorMenuActionsKey: FocusedValueKey {
    typealias Value = EditorMenuActions
}

extension FocusedValues {
    var libraryMenuActions: LibraryMenuActions? {
        get { self[LibraryMenuActionsKey.self] }
        set { self[LibraryMenuActionsKey.self] = newValue }
    }
    var editorMenuActions: EditorMenuActions? {
        get { self[EditorMenuActionsKey.self] }
        set { self[EditorMenuActionsKey.self] = newValue }
    }
}

#if targetEnvironment(macCatalyst)
private struct NotebookAppCommands: Commands {
    @FocusedValue(\.libraryMenuActions) private var library
    @FocusedValue(\.editorMenuActions) private var editor

    var body: some Commands {
        // Preserve WindowGroup’s New Window command and its ⌘N shortcut.
        CommandGroup(after: .newItem) {
            Button("New notebook") { library?.newNotebook() }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(library == nil)
            Button("New folder") { library?.newFolder() }
                .keyboardShortcut("n", modifiers: [.command, .option, .shift])
                .disabled(library == nil)
        }
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { library?.settings() }
                .keyboardShortcut(",", modifiers: .command)
                .disabled(library == nil)
        }
        CommandMenu("Notebook") {
            Button("Search library") { library?.search() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(library == nil)
            Button("Show or hide folders") { library?.toggleFolders() }
                .keyboardShortcut("s", modifiers: [.command, .control])
                .disabled(library == nil)
            Divider()
            Button("Pages") { editor?.pages() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(editor == nil)
            Button("Close notebook") { editor?.close() }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(editor == nil)
        }
    }
}
#endif
