import Foundation
import NotableKit
import SwiftUI

/// Turns pages into text in the background, some time after the writing stops.
///
/// A page is recognized only when its text is missing or older than its ink. Text that is current
/// is left alone even when the *other* device's engine produced it: MyScript and Vision do not
/// agree on wording, and treating disagreement as staleness is what turns two devices into a pair
/// that rewrite each other's work indefinitely.
///
/// It listens for remote changes as well as local ones — the iPad recognizes ink drawn on the
/// BOOX too, which is the point of a shared text database, and the absent-or-stale rule is what
/// stops that from becoming the loop above.
@MainActor
final class RecognitionController: ObservableObject {
    typealias Sleeper = @Sendable (TimeInterval) async throws -> Void

    private let store: NotebookStore
    private let recognizer: any TextRecognizing
    private let sleeper: Sleeper
    private let quietPeriod: TimeInterval

    private var sweepTask: Task<Void, Never>?
    private var workerTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    /// Pages already known to be current, keyed by the page-file revision that made them so. A
    /// stat rather than a decode is what keeps the idle sweep cheap on a large library.
    private var settled: [String: String] = [:]

    /// Set while a sweep is running, so the notifications a recognition triggers do not stack up
    /// sweeps behind it.
    private var isWorking = false

    init(
        store: NotebookStore,
        recognizer: any TextRecognizing = VisionPageTextRecognizer(),
        quietPeriod: TimeInterval = 5,
        sleeper: @escaping Sleeper = { try await Task.sleep(for: .seconds($0)) }
    ) {
        self.store = store
        self.recognizer = recognizer
        self.quietPeriod = quietPeriod
        self.sleeper = sleeper
    }

    func start() {
        guard observers.isEmpty else { return }
        for name in [
            NotebookStore.didChangeLocallyNotification,
            NotebookStore.didApplyRemoteChangesNotification,
        ] {
            observers.append(
                NotificationCenter.default.addObserver(
                    forName: name, object: nil, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.scheduleSweep() }
                })
        }
        scheduleSweep()
    }

    func stop() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        sweepTask?.cancel()
        workerTask?.cancel()
        sweepTask = nil
        workerTask = nil
    }

    /// Recognizes everything outstanding now, without waiting out the quiet period. For the app
    /// going to the background, where waiting risks the work never happening.
    func flush() {
        sweepTask?.cancel()
        sweepTask = Task { [weak self] in await self?.sweep() }
    }

    /// Recognizes one page whether or not its text looks current, and returns the result. For the
    /// reader who has looked at the text, decided it is wrong, and asked for another attempt.
    @discardableResult
    func recognizeNow(notebookId: String, pageId: String) async -> PageTextFile? {
        await recognize(notebookId: notebookId, pageId: pageId, force: true)
    }

    private func scheduleSweep() {
        guard RecognitionSettings.load().enabled else { return }
        sweepTask?.cancel()
        sweepTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.sleeper(self.quietPeriod)
            } catch {
                return  // superseded by a later change, or cancelled
            }
            guard !Task.isCancelled else { return }
            await self.sweep()
        }
    }

    /// Recognizes every page whose text is missing or stale, one at a time.
    ///
    /// Serial on purpose: each page becomes a full-page bitmap on its way through Vision, and
    /// running a notebook's worth of those at once is how an app gets killed for memory.
    private func sweep() async {
        guard !isWorking, RecognitionSettings.load().enabled else { return }
        isWorking = true
        defer { isWorking = false }

        // A notebook in the Trash is on its way out; recognizing it would be work for text
        // nobody will read.
        let trashed = Set(store.trashedNotebooks.map(\.notebookId))

        for manifest in store.notebooks where !trashed.contains(manifest.notebookId) {
            for pageId in manifest.pageIds {
                if Task.isCancelled { return }

                let revision = store.pageRevision(notebookId: manifest.notebookId, pageId: pageId)
                if settled[pageId] == revision { continue }

                await recognize(notebookId: manifest.notebookId, pageId: pageId, force: false)
                settled[pageId] = revision
            }
        }

        await publishPending()
    }

    /// Recognizes one page and stores the result, or returns nil when there was nothing to do.
    ///
    /// The page is loaded once and both its ink and its clock come from that copy, so ink that
    /// lands during recognition leaves the page looking stale afterwards and is picked up next
    /// time. Reading the clock afterwards would stamp that ink as already recognized, and it
    /// would never be read at all.
    @discardableResult
    private func recognize(
        notebookId: String,
        pageId: String,
        force: Bool
    ) async -> PageTextFile? {
        guard let page = try? store.loadPage(notebookId: notebookId, pageId: pageId) else {
            return nil
        }

        let existing = store.loadPageText(notebookId: notebookId, pageId: pageId)
        if !force, let existing, !existing.isStale(pageUpdatedAt: page.updatedAt) { return nil }

        guard let recognized = try? await recognizer.recognize(page) else { return nil }

        // Recognition that changed nothing is not an edit: rewriting the file would republish it
        // and wake every reader of the change feed for no reason.
        if let existing,
           existing.text == recognized.text,
           existing.engine == recognized.engine,
           existing.language == recognized.language,
           existing.recognizedClock == page.updatedAt {
            return existing
        }

        let text = PageTextFile(
            pageId: pageId,
            text: recognized.text,
            engine: recognized.engine,
            language: recognized.language,
            recognizedClock: page.updatedAt,
            updatedAt: store.clock.stamp(),
            updatedBy: store.deviceID,
            pendingPush: true)

        do {
            try store.savePageText(text, in: notebookId)
        } catch {
            return nil
        }

        await publish(text, notebookId: notebookId, pageTitle: page.title)
        return text
    }

    /// Sends anything that has not reached the server — after a spell offline, most of all.
    func publishPending() async {
        guard publisher() != nil else { return }
        for manifest in store.notebooks {
            for text in store.pendingPageText(in: manifest.notebookId) {
                let title = try? store.loadPage(
                    notebookId: manifest.notebookId, pageId: text.pageId
                ).title
                await publish(text, notebookId: manifest.notebookId, pageTitle: title ?? nil)
            }
        }
    }

    private func publish(_ text: PageTextFile, notebookId: String, pageTitle: String?) async {
        guard let publisher = publisher() else { return }

        let outcome = await publisher.publish(text, notebookId: notebookId, pageTitle: pageTitle)
        switch outcome {
        case .published, .alreadyCurrent:
            // Text the server already holds is as settled as text this device wrote.
            var settledText = text
            settledText.pendingPush = false
            try? store.savePageText(settledText, in: notebookId)
        case .failed:
            break  // left pending on purpose; publishPending() retries it
        }
    }

    private func publisher() -> PageTextPublisher? {
        let couch = CouchSettings.load()
        let settings = RecognitionSettings.load()
        guard let url = URL(string: couch.serverURL), url.scheme?.hasPrefix("http") == true,
              !settings.database.isEmpty
        else { return nil }

        return PageTextPublisher(
            transport: URLSessionTransport(
                baseURL: url,
                username: couch.username.isEmpty ? nil : couch.username,
                password: couch.password.isEmpty ? nil : couch.password),
            database: settings.database,
            deviceID: couch.deviceID)
    }
}

/// Whether to recognize, and where the text goes. Kept apart from `CouchSettings` because
/// recognition works with sync switched off — the text database is reached directly rather than
/// through the sync engine.
struct RecognitionSettings: Equatable {
    static let enabledKey = "recognition.enabled"
    static let databaseKey = "recognition.database"

    var enabled: Bool
    var database: String

    static func load() -> RecognitionSettings {
        let defaults = UserDefaults.standard
        return RecognitionSettings(
            // Off until asked for: recognition is real work on every page in the library, and it
            // publishes the user's handwriting to a server. Neither should start unannounced.
            enabled: defaults.object(forKey: enabledKey) as? Bool ?? false,
            database: defaults.string(forKey: databaseKey) ?? "notes_text")
    }

    func save() {
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        UserDefaults.standard.set(
            database.isEmpty ? "notes_text" : database, forKey: Self.databaseKey)
    }
}
