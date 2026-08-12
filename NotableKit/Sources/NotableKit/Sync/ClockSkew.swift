import Foundation

/// How far this device's clock is from the server's, as measured on a response — protocol §7,
/// "Clock skew".
///
/// The merge is wall-clock ordered: §4's `pick` decides every scalar field by `updatedAt`, and
/// §6.4 decides delete-versus-edit by comparing a deletion's instant with an edit's. Both read
/// timestamps *clients* wrote, so a device whose clock is wrong does not lose an argument — it
/// wins one it should have lost, silently, on the other device as well. A clock an hour ahead can
/// make an edit made this morning beat one made this afternoon, and a deletion made an hour ago
/// destroy work done since.
///
/// Detecting that is not fixing it. The fix is hybrid logical clocks, which is a protocol change
/// both apps and the shared vectors have to make together. This is the floor: notice, and say so.
public struct ClockSkew: Equatable, Sendable {
    /// Signed, in seconds: local time at the moment the response was received, minus the time the
    /// server stamped it. Positive means this device is **ahead** of the server.
    public var seconds: TimeInterval

    public init(seconds: TimeInterval) {
        self.seconds = seconds
    }

    /// Whether this device is running ahead of the server.
    public var isAhead: Bool { seconds > 0 }

    /// A sentence for the sync status and the log. Names the direction and a rough magnitude,
    /// because "your clock is wrong" is not something anyone can act on and "about 40 minutes
    /// ahead" is: it points straight at the device's date and time settings.
    public var summary: String {
        let magnitude = abs(seconds)
        // Never less than two minutes — anything smaller is below the threshold that records a
        // skew at all — so neither branch can produce a bare "1".
        let amount = magnitude < 7_200
            ? "\(Int((magnitude / 60).rounded())) minutes"
            : "\(Int((magnitude / 3_600).rounded())) hours"
        return "This device's clock is about \(amount) \(isAhead ? "ahead of" : "behind") the sync "
            + "server's. Edits are merged by timestamp, so while the clocks disagree the wrong "
            + "version can win. Check this device's date and time."
    }
}

/// Watches the `Date` header on responses and remembers the last significant disagreement.
///
/// One monitor is shared by every request a client makes, which is why this is an actor rather
/// than state on the client: `CouchDBClient` is a value type, copied freely, and the observation
/// has to accumulate somewhere both the transport calls and the engine's reports can see.
public actor ClockSkewMonitor {
    /// At or above this many seconds, in either direction, the skew is reported.
    ///
    /// 120s, deliberately loose. The header has one-second granularity, it is stamped when the
    /// server begins the response rather than when this device receives it, and a slow link or a
    /// long-parked longpoll adds real seconds on top. A tighter threshold would fire on healthy
    /// setups, and a warning that appears when nothing is wrong is one nobody reads when something
    /// is. Anything this large is a misconfigured clock, not latency.
    public static let significantSeconds: TimeInterval = 120

    private var latest: ClockSkew?

    public init() {}

    /// The most recent significant skew, or nil when the last response that could be read showed
    /// none. It answers "are the clocks disagreeing *now*", so a response that says they agree
    /// clears it — while a response that says nothing (no header, unparseable) leaves the last
    /// answer standing rather than pretending the problem went away.
    public var significantSkew: ClockSkew? { latest }

    /// Records the skew implied by one response.
    ///
    /// A response with no `Date` header, or one this cannot parse, is **not** an error and not a
    /// warning: it is simply no information, and the previous observation stands. Only a header
    /// that parses can say anything about a clock, and no sync ever fails over this.
    public func observe(_ response: HTTPResponse, receivedAt: Date = Date()) {
        guard let header = response.header("Date"), let serverDate = Self.parse(header) else {
            return
        }
        let skew = receivedAt.timeIntervalSince(serverDate)
        // Cleared as well as set, so fixing the clock clears the warning on the next request
        // rather than leaving it on screen until the app restarts.
        latest = abs(skew) >= Self.significantSeconds ? ClockSkew(seconds: skew) : nil
    }

    /// RFC 9110's IMF-fixdate — `Sun, 06 Nov 1994 08:49:37 GMT` — which is what every CouchDB
    /// sends. The two obsolete formats HTTP also permits are not parsed: no server in this
    /// protocol's world emits them, and guessing wrong here would invent a skew rather than
    /// report none.
    ///
    /// Fixed to POSIX and GMT explicitly. A formatter that inherited the device's locale would
    /// fail to parse English month names on a device set to another language — turning "the clock
    /// is fine" into "no information" for exactly the users least likely to notice.
    static func parse(_ header: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: header)
    }
}
