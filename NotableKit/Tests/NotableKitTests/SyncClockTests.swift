import XCTest
@testable import NotableKit

/// File scope so the `@Sendable` `base` closures below capture a plain `Date` rather than the test
/// case, which is not `Sendable`.
private let fixed = Date(timeIntervalSince1970: 1_770_000_000)

/// The stamp-time half of protocol §7.1: a measured skew stops being a sentence in the log and
/// starts moving the timestamps this device writes.
///
/// `CouchMerge` is deliberately not exercised here. It must stay a pure function of its two
/// arguments — an instant that arrived from a peer is never adjusted — so the correction is only
/// ever observable at the moment a stamp is made, which is what these assert.
final class SyncClockTests: XCTestCase {

    /// A defaults suite of its own, so these never read or write the real one.
    private func scratchDefaults(_ name: String = #function) -> UserDefaults {
        let suite = "SyncClockTests.\(name)"
        UserDefaults().removePersistentDomain(forName: suite)
        return UserDefaults(suiteName: suite)!
    }

    func testAnUnmeasuredClockStampsTheSystemClockUnchanged() {
        let clock = SyncClock(defaults: scratchDefaults(), base: { fixed })

        XCTAssertEqual(clock.now(), fixed)
        XCTAssertNil(clock.skew)
    }

    func testADeviceRunningAheadStampsTheCorrectedTimeNotItsOwn() {
        let clock = SyncClock(defaults: scratchDefaults(), base: { fixed })

        clock.note(ClockSkew(seconds: 3_600))

        // An hour ahead of the server means every stamp comes back an hour, or this device wins
        // every comparison against a peer whose clock is right.
        XCTAssertEqual(clock.now(), fixed.addingTimeInterval(-3_600))
    }

    func testADeviceRunningBehindStampsForwardByTheSameMeasurement() {
        let clock = SyncClock(defaults: scratchDefaults(), base: { fixed })

        clock.note(ClockSkew(seconds: -1_800))

        XCTAssertEqual(clock.now(), fixed.addingTimeInterval(1_800))
    }

    func testTheWireStampAgreesWithTheCorrectedDate() {
        let clock = SyncClock(defaults: scratchDefaults(), base: { fixed })
        clock.note(ClockSkew(seconds: 7_200))

        // The deletion ledger stamps strings and the prune horizon compares dates. If the two
        // disagreed, correcting one would skew it against the other.
        XCTAssertEqual(clock.stamp(), NotableDate.format(fixed.addingTimeInterval(-7_200)))
    }

    func testAClockThatHasBeenPutRightStopsBeingCorrected() {
        let clock = SyncClock(defaults: scratchDefaults(), base: { fixed })

        clock.note(ClockSkew(seconds: 3_600))
        clock.note(nil)

        XCTAssertEqual(clock.now(), fixed)
        XCTAssertFalse(clock.needsAttention)
    }

    func testTheMeasurementSurvivesARelaunch() {
        // The edit that most needs correcting is the one made offline after a sync: it happens
        // before any response could re-measure, and on a device offline for a day that is all of
        // them.
        let defaults = scratchDefaults()
        SyncClock(defaults: defaults, base: { fixed }).note(ClockSkew(seconds: 3_600))

        let relaunched = SyncClock(defaults: defaults, base: { fixed })

        XCTAssertEqual(relaunched.now(), fixed.addingTimeInterval(-3_600))
        XCTAssertEqual(relaunched.skew?.seconds, 3_600)
    }

    func testAClockPutRightStaysRightAcrossARelaunch() {
        let defaults = scratchDefaults()
        let clock = SyncClock(defaults: defaults, base: { fixed })
        clock.note(ClockSkew(seconds: 3_600))
        clock.note(nil)

        // Clearing has to erase the stored value, not merely the in-memory one, or fixing the
        // clock would be undone by the next launch.
        XCTAssertEqual(SyncClock(defaults: defaults, base: { fixed }).now(), fixed)
    }

    func testThePruneHorizonMovesWithTheCorrection() {
        // The cutoff is compared against instants stamped by this same corrected clock, here and on
        // the peers. Pruning from the raw clock while stamping corrected instants would take the
        // skew straight off the 30-day horizon — on a device a week fast, that drops tombstones the
        // peer still needs, and erased strokes come back.
        let clock = SyncClock(defaults: scratchDefaults(), base: { fixed })
        clock.note(ClockSkew(seconds: 7 * 24 * 60 * 60))

        let justInsideHorizon = CouchTombstone(
            id: "s1",
            deletedAt: NotableDate.format(fixed.addingTimeInterval(-29 * 24 * 60 * 60)))

        // Uncorrected, a week-fast clock's cutoff is 23 days back and this survives by a day less
        // than it should; corrected, the horizon is measured from where the stamps actually are.
        XCTAssertEqual(CouchTombstones.prune([justInsideHorizon], now: clock.now()).count, 1)

        let outsideHorizon = CouchTombstone(
            id: "s2",
            deletedAt: NotableDate.format(fixed.addingTimeInterval(-38 * 24 * 60 * 60)))
        XCTAssertTrue(CouchTombstones.prune([outsideHorizon], now: clock.now()).isEmpty)
    }

    func testASkewWorthMentioningIsNotAlwaysWorthABanner() {
        let clock = SyncClock(defaults: scratchDefaults(), base: { fixed })

        // 120s is the threshold at which a skew is recorded at all, and it is loose enough to catch
        // a slow link. A banner at that scale is one that gets ignored when it matters.
        clock.note(ClockSkew(seconds: 150))
        XCTAssertFalse(clock.needsAttention)

        clock.note(ClockSkew(seconds: 600))
        XCTAssertTrue(clock.needsAttention)
    }

    func testTheBannerFiresTheSameDistanceBehindAsAhead() {
        // A slow clock destroys just as much as a fast one — it loses comparisons it should win, so
        // this device's real edits lose to the peer's older ones.
        let clock = SyncClock(defaults: scratchDefaults(), base: { fixed })
        clock.note(ClockSkew(seconds: -600))

        XCTAssertTrue(clock.needsAttention)
    }
}
