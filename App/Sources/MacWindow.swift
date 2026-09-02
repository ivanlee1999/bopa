import SwiftUI
import UIKit

#if targetEnvironment(macCatalyst)
/// What the Mac window needs that the iPad's never had: a size it cannot shrink below, and no
/// second toolbar over the app's own.
///
/// Reached through the scene delegate because SwiftUI's `WindowGroup` exposes neither the
/// `UIWindowScene` nor its `titlebar`, and the scene is the only place a window's restrictions
/// can be set before it is shown. The `UIApplicationDelegateAdaptor` in `BopaApp` is what makes
/// UIKit ask for this class at all.
final class MacSceneDelegate: NSObject, UIWindowSceneDelegate {
    /// The narrowest window that still holds the tool rail, a page at fit-to-width and the
    /// page controls without the top bar wrapping. Below it the chrome overlaps the paper.
    static let minimumSize = CGSize(width: 900, height: 620)

    func scene(
        _ scene: UIScene, willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        windowScene.sizeRestrictions?.minimumSize = Self.minimumSize
        // The system title bar stays: it is where the traffic lights live and, without it,
        // they float over whichever of the app's own controls sits in the top-left corner. Its
        // toolbar goes, because the app draws its own bar and two stacked is one too many.
        windowScene.titlebar?.toolbar = nil
        windowScene.titlebar?.titleVisibility = .visible
    }
}

final class MacAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(
            name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = MacSceneDelegate.self
        return configuration
    }
}
#endif

/// Whether this process is the Mac build. A value rather than `#if` at every use, so the SwiftUI
/// bodies that differ between the two read as one condition and not as two files.
enum Platform {
    #if targetEnvironment(macCatalyst)
    static let isMac = true
    #else
    static let isMac = false
    #endif

    /// Opens `directory` in the Finder. On the Mac `open(_:)` on a file URL hands it to the
    /// Finder; there is no `NSWorkspace` in a Catalyst process to ask more directly.
    @MainActor
    static func reveal(_ directory: URL) {
        UIApplication.shared.open(directory)
    }
}
