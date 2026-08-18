import Foundation

/// The clock every sync-relevant timestamp is stamped from: this device's wall clock, corrected by
/// the last disagreement measured against the sync server (protocol §7.1).
///
/// `ClockSkewMonitor` notices that this device's clock is wrong. This is what does something about
/// it. The protocol orders everything by client wall-clock instants — §4's `pick` decides each
/// scalar field by `updatedAt`, §6.4 decides delete-versus-edit by comparing a deletion's instant
/// with an edit's — so a device running fast does not merely mis-report a time, it *wins*
/// comparisons it should lose, on both devices. A future-dated tombstone destroys edits made until
/// that date passes, and a future-dated envelope pins a rename or a trash state, so a restored
/// notebook drops back into the Trash on every sync until the stamp comes true.
///
/// Two rules hold this in place:
///
/// - **Stamp time, never apply time.** An instant that arrived from a peer is used exactly as sent.
///   Adjusting one on the way in would make two devices compute different results from the same
///   pair of documents — the convergence the shared vector suite exists to protect. `CouchMerge`
///   stays a pure function of its arguments and knows nothing about this type.
/// - **All of them or none of them.** Correcting deletions while leaving page clocks alone would be
///   worse than correcting neither: on a device an hour fast the deletions would move back an hour
///   while the edits stayed an hour ahead, and §6.4 would resurrect far more eagerly than the
///   uncorrected bug destroys. Every stamp that reaches a synced document reads this clock.
///
/// This is not a hybrid logical clock. Two devices that have both reached the same server agree to
/// within the measurement's precision; a device that has never reached it is exactly as wrong as it
/// was before. §7.1 still names HLCs as the fix, and they are still out of scope.
public final class SyncClock: @unchecked Sendable {

    /// The instance the app stamps from. A shared value rather than an injected one because the
    /// stamps it has to reach are spread across `NotebookStore`'s every mutation and
    /// `FileCouchStore`'s deletion ledger; tests build their own with an explicit `base`.
    public static let shared = SyncClock()

    private let lock = NSLock()
    private let base: @Sendable () -> Date
    private let defaults: UserDefaults
    private var offset: TimeInterval = 0
    private var latest: ClockSkew?

    /// Where the last measurement is persisted, so a launch that has not reached the server yet
    /// still stamps corrected instants.
    public static let skewKey = "couch.lastClockSkewSeconds"

    /// - Parameters:
    ///   - defaults: where the measurement is persisted. Injected so a test can use a scratch
    ///     suite rather than the real one, matching `HandwritingSettings`.
    ///   - base: this device's uncorrected clock.
    public init(
        defaults: UserDefaults = .standard,
        base: @escaping @Sendable () -> Date = Date.init
    ) {
        self.defaults = defaults
        self.base = base
        // Restored before anything can be stamped. The edit that most needs correcting is the one
        // made offline after a sync — it happens before any response could re-measure, and on a
        // device that stays offline for a day, that is all of them.
        if let stored = defaults.object(forKey: Self.skewKey) as? TimeInterval {
            offset = stored
            latest = ClockSkew(seconds: stored)
        }
    }

    /// This device's corrected clock.
    public func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return base().addingTimeInterval(-offset)
    }

    /// This device's corrected clock, already in the wire format.
    public func stamp() -> String { NotableDate.format(now()) }

    /// The last measured skew, or nil when the clocks agreed — what the warning is built from.
    public var skew: ClockSkew? {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }

    /// Records the skew measured against the server, and corrects every stamp from here on.
    ///
    /// Timestamps already written are left alone. Correcting them retroactively would rewrite
    /// history a peer has already merged, and the peer would not make the same correction — the
    /// disagreement is a fact about this device's clock, not about the documents.
    public func note(_ skew: ClockSkew?) {
        lock.lock()
        latest = skew
        offset = skew?.seconds ?? 0
        lock.unlock()
        if let skew {
            defaults.set(skew.seconds, forKey: Self.skewKey)
        } else {
            defaults.removeObject(forKey: Self.skewKey)
        }
    }

    /// Whether the disagreement is large enough to say so persistently rather than in passing.
    ///
    /// Well above the 120s at which a skew is *recorded*: that threshold is loose enough to absorb
    /// a slow link, and a banner that appears for a round-trip hiccup is one that gets ignored when
    /// it matters. Five minutes is past any latency explanation and into "this iPad's date is
    /// wrong", which is something the user can go and fix.
    public static let warningSeconds: TimeInterval = 300

    public var needsAttention: Bool {
        guard let skew else { return false }
        return abs(skew.seconds) >= Self.warningSeconds
    }
}
