import Compression
import Foundation

public enum SBCodecError: Error, Equatable {
    case emptyPointList
    case pageTooLarge(y: Float)
    case nonUniformChannel(String)
    case bufferTooSmall
    case badMagic
    case unsupportedVersion(UInt8)
    case negativePointCount
    case unknownCompressionFlag(UInt8)
    case truncated(String)
    case pointCountMismatch
    case trailingBytes
    case lz4Failed
}

/// Codec for Notable's "SB" stroke-points binary (`StrokePointConverter.kt`), version 2.
///
/// Layout (little-endian):
/// ```
/// 'S' 'B' version(1) mask(1) count(int32) compression(1)
/// [if LZ4] rawBodySize(int32)
/// body: int32 xLen, x polyline (precision 2, UTF-8)
///       int32 yLen, y polyline
///       [mask&1] uint16[count] pressure = round(p * 65535)
///       [mask&2] int8[count]   tiltX
///       [mask&4] int8[count]   tiltY
///       [mask&8] uint16[count] dt (clamped to 0...65534 on write)
/// ```
/// LZ4 is the raw block format (`COMPRESSION_LZ4_RAW`), applied to the whole body when it
/// is >= 512 bytes and compression saves >= 25%.
public enum SBStrokeCodec {

    // Mask bits
    public static let pressureMask = 1 << 0
    public static let tiltXMask = 1 << 1
    public static let tiltYMask = 1 << 2
    public static let dtMask = 1 << 3

    static let magic0: UInt8 = 0x53 // 'S'
    static let magic1: UInt8 = 0x42 // 'B'
    static let formatVersion: UInt8 = 2
    static let headerSize = 9
    static let pressureQuant: Float = 65535
    static let dtMaxValue: UInt16 = 0xFFFE
    static let coordinatePrecision = 2
    static let minBytesForCompression = 512
    static let minSavingRatio = 0.75
    static let maxPageHeight: Float = 10_000_000

    // MARK: - Mask helpers

    public static func computeMask(_ points: [NotableStrokePoint]) throws -> Int {
        guard let first = points.first else { throw SBCodecError.emptyPointList }
        var mask = 0
        if first.pressure != nil { mask |= pressureMask }
        if first.tiltX != nil { mask |= tiltXMask }
        if first.tiltY != nil { mask |= tiltYMask }
        if first.dt != nil { mask |= dtMask }
        return mask
    }

    static func validateUniform(mask: Int, points: [NotableStrokePoint]) throws {
        func check(_ bit: Int, _ name: String, _ has: (NotableStrokePoint) -> Bool) throws {
            let expected = mask & bit != 0
            if points.contains(where: { has($0) != expected }) {
                throw SBCodecError.nonUniformChannel(name)
            }
        }
        try check(pressureMask, "pressure") { $0.pressure != nil }
        try check(tiltXMask, "tiltX") { $0.tiltX != nil }
        try check(tiltYMask, "tiltY") { $0.tiltY != nil }
        try check(dtMask, "dt") { $0.dt != nil }
    }

    // MARK: - Encoding

    public static func encode(_ points: [NotableStrokePoint]) throws -> Data {
        guard let first = points.first else { throw SBCodecError.emptyPointList }
        guard first.y <= maxPageHeight else { throw SBCodecError.pageTooLarge(y: first.y) }
        let mask = try computeMask(points)
        try validateUniform(mask: mask, points: points)
        let count = points.count

        let encodedX = Array(Polyline.encode(points.map(\.x), precision: coordinatePrecision).utf8)
        let encodedY = Array(Polyline.encode(points.map(\.y), precision: coordinatePrecision).utf8)

        var body = Data(capacity: 8 + encodedX.count + encodedY.count + count * 6)
        body.appendInt32LE(Int32(encodedX.count))
        body.append(contentsOf: encodedX)
        body.appendInt32LE(Int32(encodedY.count))
        body.append(contentsOf: encodedY)

        if mask & pressureMask != 0 {
            for p in points {
                let clamped = min(max(p.pressure!, 0), 1)
                let q = UInt16((clamped * pressureQuant).rounded())
                body.appendUInt16LE(q)
            }
        }
        if mask & tiltXMask != 0 {
            for p in points { body.append(UInt8(bitPattern: Int8(truncatingIfNeeded: p.tiltX!))) }
        }
        if mask & tiltYMask != 0 {
            for p in points { body.append(UInt8(bitPattern: Int8(truncatingIfNeeded: p.tiltY!))) }
        }
        if mask & dtMask != 0 {
            for p in points { body.appendUInt16LE(min(p.dt!, dtMaxValue)) }
        }

        var compressionFlag: UInt8 = 0
        var finalBody = body
        if body.count >= minBytesForCompression,
           let compressed = lz4CompressBlock(body),
           Double(compressed.count) <= Double(body.count) * minSavingRatio
        {
            compressionFlag = 1
            finalBody = compressed
        }

        var out = Data(capacity: headerSize + 4 + finalBody.count)
        out.append(magic0)
        out.append(magic1)
        out.append(formatVersion)
        out.append(UInt8(mask))
        out.appendInt32LE(Int32(count))
        out.append(compressionFlag)
        if compressionFlag == 1 { out.appendInt32LE(Int32(body.count)) }
        out.append(finalBody)
        return out
    }

    // MARK: - Decoding

    public static func decode(_ data: Data) throws -> [NotableStrokePoint] {
        guard data.count >= headerSize + 8 else { throw SBCodecError.bufferTooSmall }
        var reader = ByteReader(data)
        guard reader.readByte() == magic0, reader.readByte() == magic1 else {
            throw SBCodecError.badMagic
        }
        let version = reader.readByte()
        guard version <= formatVersion else { throw SBCodecError.unsupportedVersion(version) }
        let mask = Int(reader.readByte())
        let count = Int(try reader.readInt32LE())
        guard count >= 0 else { throw SBCodecError.negativePointCount }
        let compressionFlag = reader.readByte()

        var body: ByteReader
        switch compressionFlag {
        case 0:
            body = reader
        case 1:
            guard data.count > headerSize + 4 else { throw SBCodecError.truncated("missing raw size") }
            let rawSize = Int(try reader.readInt32LE())
            guard rawSize > 0 else { throw SBCodecError.truncated("invalid raw size \(rawSize)") }
            let decompressed = try lz4DecompressBlock(reader.remainingData(), rawSize: rawSize)
            body = ByteReader(decompressed)
        default:
            throw SBCodecError.unknownCompressionFlag(compressionFlag)
        }

        let xs = try decodeCoordinateList(&body)
        let ys = try decodeCoordinateList(&body)
        guard xs.count == count, ys.count == count else { throw SBCodecError.pointCountMismatch }

        var pressures: [Float]?
        if mask & pressureMask != 0 {
            guard body.remaining >= count * 2 else { throw SBCodecError.truncated("pressure") }
            pressures = try (0..<count).map { _ in
                let raw = try body.readUInt16LE()
                if version >= 2 {
                    return Float(raw) / pressureQuant
                } else {
                    // v1: raw digitizer value stored as signed int16
                    return Float(Int16(bitPattern: raw))
                }
            }
        }
        var tiltXs: [Int]?
        if mask & tiltXMask != 0 {
            guard body.remaining >= count else { throw SBCodecError.truncated("tiltX") }
            tiltXs = (0..<count).map { _ in Int(Int8(bitPattern: body.readByte())) }
        }
        var tiltYs: [Int]?
        if mask & tiltYMask != 0 {
            guard body.remaining >= count else { throw SBCodecError.truncated("tiltY") }
            tiltYs = (0..<count).map { _ in Int(Int8(bitPattern: body.readByte())) }
        }
        var dts: [UInt16]?
        if mask & dtMask != 0 {
            guard body.remaining >= count * 2 else { throw SBCodecError.truncated("dt") }
            dts = try (0..<count).map { _ in try body.readUInt16LE() }
        }

        if compressionFlag == 0, body.remaining > 0 { throw SBCodecError.trailingBytes }

        return (0..<count).map { i in
            NotableStrokePoint(
                x: xs[i],
                y: ys[i],
                pressure: pressures?[i],
                tiltX: tiltXs?[i],
                tiltY: tiltYs?[i],
                dt: dts?[i]
            )
        }
    }

    private static func decodeCoordinateList(_ reader: inout ByteReader) throws -> [Float] {
        let size = Int(try reader.readInt32LE())
        guard size >= 0, reader.remaining >= size else { throw SBCodecError.truncated("coordinates") }
        let bytes = reader.readData(count: size)
        guard let string = String(data: bytes, encoding: .utf8) else {
            throw SBCodecError.truncated("coordinates not UTF-8")
        }
        return Polyline.decode(string, precision: coordinatePrecision)
    }

    // MARK: - LZ4 raw block

    static func lz4CompressBlock(_ input: Data) -> Data? {
        let destinationCapacity = input.count // only useful when strictly smaller anyway
        var destination = Data(count: destinationCapacity)
        let written = destination.withUnsafeMutableBytes { dst in
            input.withUnsafeBytes { src in
                compression_encode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!, destinationCapacity,
                    src.bindMemory(to: UInt8.self).baseAddress!, input.count,
                    nil, COMPRESSION_LZ4_RAW
                )
            }
        }
        guard written > 0 else { return nil }
        return destination.prefix(written)
    }

    static func lz4DecompressBlock(_ input: Data, rawSize: Int) throws -> Data {
        guard !input.isEmpty else { throw SBCodecError.truncated("no compressed data") }
        var destination = Data(count: rawSize)
        let written = destination.withUnsafeMutableBytes { dst in
            input.withUnsafeBytes { src in
                compression_decode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!, rawSize,
                    src.bindMemory(to: UInt8.self).baseAddress!, input.count,
                    nil, COMPRESSION_LZ4_RAW
                )
            }
        }
        guard written == rawSize else { throw SBCodecError.lz4Failed }
        return destination
    }
}

// MARK: - Byte plumbing

struct ByteReader {
    private let data: Data
    private(set) var offset: Int

    init(_ data: Data) {
        self.data = data
        self.offset = data.startIndex
    }

    var remaining: Int { data.endIndex - offset }

    mutating func readByte() -> UInt8 {
        defer { offset += 1 }
        return data[offset]
    }

    mutating func readData(count: Int) -> Data {
        defer { offset += count }
        return data.subdata(in: offset..<(offset + count))
    }

    mutating func readInt32LE() throws -> Int32 {
        guard remaining >= 4 else { throw SBCodecError.truncated("int32") }
        let bytes = readData(count: 4)
        return bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }.littleEndian
    }

    mutating func readUInt16LE() throws -> UInt16 {
        guard remaining >= 2 else { throw SBCodecError.truncated("uint16") }
        let bytes = readData(count: 2)
        return bytes.withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }.littleEndian
    }

    func remainingData() -> Data {
        data.subdata(in: offset..<data.endIndex)
    }
}

extension Data {
    mutating func appendInt32LE(_ value: Int32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendUInt16LE(_ value: UInt16) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
