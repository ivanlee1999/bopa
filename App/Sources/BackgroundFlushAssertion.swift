import Foundation
import UIKit

/// Permission to keep running for a moment after the app leaves the screen.
///
/// A seam rather than a direct `UIApplication` call so the lifecycle can be tested: the thing worth
/// asserting is that exactly one assertion is taken and exactly one is released, on both the
/// completion and the expiration path, and a double release of a real `UIBackgroundTaskIdentifier`
/// is a crash rather than a test failure.
@MainActor
protocol BackgroundFlushAssertion {
    /// Takes an assertion, or returns nil when the system will not grant one — the app was launched
    /// into the background, or the budget is already spent. Callers must still do the work; they
    /// just cannot count on finishing it.
    ///
    /// `onExpire` runs when the system wants the time back. It is the last warning before
    /// suspension, and it arrives on the main actor.
    func begin(_ name: String, onExpire: @escaping @MainActor () -> Void) -> Int?

    /// Releases an assertion. Called exactly once per `begin` that returned a token.
    func end(_ token: Int)
}

/// The real thing.
///
/// `beginBackgroundTask` buys a finite, system-decided window — tens of seconds, never a promise.
/// That is the right shape for a final flush and the wrong shape for anything ongoing, which is why
/// the change feed is stopped before this is taken rather than kept alive inside it.
@MainActor
struct UIKitBackgroundFlushAssertion: BackgroundFlushAssertion {
    func begin(_ name: String, onExpire: @escaping @MainActor () -> Void) -> Int? {
        let identifier = UIApplication.shared.beginBackgroundTask(withName: name) {
            // UIKit documents this handler as running on the main thread.
            MainActor.assumeIsolated { onExpire() }
        }
        guard identifier != .invalid else { return nil }
        return identifier.rawValue
    }

    func end(_ token: Int) {
        UIApplication.shared.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: token))
    }
}
