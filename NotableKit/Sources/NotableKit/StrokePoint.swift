import Foundation

/// One sampled pen point, matching Notable's `StrokePoint`.
///
/// SB channel-uniformity invariant: within a single stroke, each optional field is either
/// present on every point or absent on every point.
public struct NotableStrokePoint: Equatable, Sendable {
    /// Page-local coordinates; `y` includes the page's scroll offset.
    public var x: Float
    public var y: Float
    /// Normalized to [0, 1] in memory. Legacy (v1 / maxPressure != 1) data carries raw
    /// digitizer values; normalize via `Stroke.withNormalizedPressure` semantics.
    public var pressure: Float?
    /// Tilt in degrees, -90...90.
    public var tiltX: Int?
    public var tiltY: Int?
    /// Milliseconds since the first point of the stroke (0...65534).
    public var dt: UInt16?

    public init(
        x: Float,
        y: Float,
        pressure: Float? = nil,
        tiltX: Int? = nil,
        tiltY: Int? = nil,
        dt: UInt16? = nil
    ) {
        self.x = x
        self.y = y
        self.pressure = pressure
        self.tiltX = tiltX
        self.tiltY = tiltY
        self.dt = dt
    }
}

/// Notable's pen types (`editor/utils/pen.kt`). Unknown names fall back to `.ballpen`,
/// mirroring Notable's `Pen.fromString`.
public enum NotablePen: String, CaseIterable, Sendable {
    case ballpen = "BALLPEN"
    case redBallpen = "REDBALLPEN"      // legacy, parse-only
    case greenBallpen = "GREENBALLPEN"  // legacy, parse-only
    case blueBallpen = "BLUEBALLPEN"    // legacy, parse-only
    case pencil = "PENCIL"              // charcoal v1
    case brush = "BRUSH"
    case marker = "MARKER"
    case fountain = "FOUNTAIN"
    case dashed = "DASHED"
    case charcoal = "CHARCOAL"          // charcoal v2
    case calligraphy = "CALLIGRAPHY"

    public static func from(_ name: String?) -> NotablePen {
        guard let name else { return .ballpen }
        return NotablePen(rawValue: name) ?? .ballpen
    }
}
