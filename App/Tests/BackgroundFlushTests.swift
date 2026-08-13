import NotableKit
import XCTest

@testable import Bopa

/// The final push when the app leaves the screen.
///
/// iOS suspends a backgrounded process whenever it likes. The last strokes before someone closed
/// the lid are the ones most likely to be cut off and the least likely to have been sent by
/// anything else, and the flush that carries them used to be a bare `Task` with nothing asking the
/// system to wait.
///
/// What is asserted here is the bookkeeping, not the timing: exactly one assertion is taken, and
/// exactly one is released, on both the completion and the expiration path. Releasing a real
/// `UIBackgroundTaskIdentifier` twice traps the process, and never releasing one is what makes iOS
/// kill an app for overrunning its budget — so "exactly once" is the property, and a double is a
/// crash rather than a test failure if it is ever got wrong.
@MainActor
final class BackgroundFlushTests: XCTestCase {

    private final class AssertionSpy: BackgroundFlushAssertion {
        private(set) var begun = 0
        private(set) var ended: [Int] = []
        private var expire: (@MainActor () -> Void)?
        /// Stands in for a system that will not grant one — launched into the background, or the
        /// budget already spent.
        var refuse = false

        func begin(_ name: String, onExpire: @escaping @MainActor () -> Void) -> Int? {
            begun += 1
            expire = onExpire
            return refuse ? nil : begun
        }

        func end(_ token: Int) { ended.append(token) }

        /// The system asking for its time back.
        func fireExpiration() { expire?() }
    }

    private func makeHost(_ assertion: AssertionSpy) -> SyncBackendHost {
        // No CouchDB settings worth reaching: `configure()` is never called, so no stack is built
        // and `couch` stays nil. The lifecycle bookkeeping is what is under test, and it has to
        // hold even when there is nothing to flush — a host that skipped the release when the
        // stack was absent would leak the assertion every time.
        SyncBackendHost(
            loadSettings: { CouchSettings(
                serverURL: "http://127.0.0.1:5984", database: "notes",
                username: "sync", password: "pw", deviceID: "ipad") },
            loadBackend: { .couchdb },
            backgroundAssertion: assertion)
    }

    func testBackgroundingTakesExactlyOneAssertionAndReleasesIt() async throws {
        let assertion = AssertionSpy()
        let host = makeHost(assertion)

        host.enteredBackground()
        // The flush runs as a task; let it finish.
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(assertion.begun, 1)
        XCTAssertEqual(assertion.ended, [1], "the assertion must be released exactly once")
    }

    /// Completion and expiration race. Both paths end the assertion, and ending twice traps.
    func testAnExpirationAfterCompletionDoesNotReleaseTwice() async throws {
        let assertion = AssertionSpy()
        let host = makeHost(assertion)

        host.enteredBackground()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(assertion.ended, [1])

        // The system asks for the time back after the flush already finished and let go.
        assertion.fireExpiration()

        XCTAssertEqual(assertion.ended, [1], "a late expiration must not end the assertion again")
    }

    /// Expiration arriving first is the ordinary case on a busy device.
    func testAnExpirationReleasesTheAssertionAndTheLaterCompletionDoesNot() async throws {
        let assertion = AssertionSpy()
        let host = makeHost(assertion)

        host.enteredBackground()
        assertion.fireExpiration()
        XCTAssertEqual(assertion.ended, [1], "expiration should let go immediately")

        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(assertion.ended, [1], "and the flush finishing must not end it again")
    }

    /// A refused assertion is not a reason to skip the work: the flush still runs, unprotected,
    /// exactly as it did before any of this existed. What must not happen is releasing a token
    /// that was never granted.
    func testARefusedAssertionStillFlushesAndReleasesNothing() async throws {
        let assertion = AssertionSpy()
        assertion.refuse = true
        let host = makeHost(assertion)

        host.enteredBackground()
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(assertion.begun, 1)
        XCTAssertTrue(assertion.ended.isEmpty, "nothing was granted, so nothing may be released")
    }

    /// Backgrounding twice — the app returning and leaving again — must not accumulate assertions.
    func testASecondBackgroundingTakesAFreshAssertionAndReleasesBoth() async throws {
        let assertion = AssertionSpy()
        let host = makeHost(assertion)

        host.enteredBackground()
        try await Task.sleep(for: .milliseconds(50))
        host.enteredBackground()
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(assertion.begun, 2)
        XCTAssertEqual(assertion.ended, [1, 2], "each assertion released exactly once, in order")
    }

    /// The feed is stopped before the assertion is taken. `beginBackgroundTask` buys a finite,
    /// system-decided window, which is the right shape for a final flush and the wrong shape for a
    /// long poll that is designed to sit open — holding one for the feed is how an app spends its
    /// whole background budget waiting for a server to say nothing.
    func testTheChangeFeedIsNotKeptAliveInTheBackground() async throws {
        let assertion = AssertionSpy()
        let host = makeHost(assertion)

        host.enteredBackground()
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertFalse(host.couch?.isRunning ?? false, "the long poll must not survive backgrounding")
    }
}
