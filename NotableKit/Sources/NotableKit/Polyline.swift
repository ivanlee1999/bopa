import Foundation

/// Google polyline codec, ported to match Notable's `EncodePolyline.kt` exactly
/// (delta + zigzag + 5-bit chunks offset by 63). Notable applies it to each coordinate
/// axis independently with precision 2.
public enum Polyline {

    /// Mirrors Kotlin `(value.toDouble() * 10^precision).toInt()`: truncation toward zero.
    public static func encode(_ values: [Float], precision: Int = 5) -> String {
        let factor = pow(10.0, Double(precision))
        var prev = 0
        var out = ""
        out.reserveCapacity(values.count * 3)
        for v in values {
            let iValue = Int(Double(v) * factor)
            appendEncodedValue(iValue - prev, to: &out)
            prev = iValue
        }
        return out
    }

    private static func appendEncodedValue(_ value: Int, to out: inout String) {
        var actual = value < 0 ? ~(value << 1) : value << 1
        while actual >= 0x20 {
            out.unicodeScalars.append(UnicodeScalar(UInt8((actual & 0x1F) | 0x20) + 63))
            actual >>= 5
        }
        out.unicodeScalars.append(UnicodeScalar(UInt8(actual) + 63))
    }

    public static func decode(_ polyline: String, precision: Int = 5) -> [Float] {
        // Collect complete 5-bit chunk groups. Like the Kotlin original, a trailing
        // incomplete group (malformed input) is dropped by the final removeLast.
        var groups: [[Int]] = [[]]
        for scalar in polyline.unicodeScalars {
            var value = Int(scalar.value) - 63
            let isLastOfChunk = (value & 0x20) == 0
            value &= 0x1F
            groups[groups.count - 1].append(value)
            if isLastOfChunk { groups.append([]) }
        }
        groups.removeLast()

        let factor = pow(10.0, Double(precision))
        var prev = 0.0
        var points: [Float] = []
        points.reserveCapacity(groups.count)
        for group in groups {
            var coordinate = 0
            for (i, chunk) in group.enumerated() {
                coordinate |= chunk << (i * 5)
            }
            if coordinate & 0x1 != 0 { coordinate = ~coordinate }
            coordinate >>= 1
            prev += Double(coordinate) / factor
            points.append(Float((prev * factor).rounded() / factor))
        }
        return points
    }
}
