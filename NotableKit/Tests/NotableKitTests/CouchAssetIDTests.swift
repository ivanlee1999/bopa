import XCTest
@testable import NotableKit

/// An asset id is a promise about bytes that two different languages have to keep *identically*, or
/// a picture uploaded by one device is unfindable by the other — the id is the only name it has.
///
/// The literals here are duplicated verbatim in notable's `AssetInteropTest.kt`. That duplication
/// is the point: two implementations agreeing with each other's output is what a shared constant
/// cannot show, and a round-trip test inside one app cannot either, since it would agree with
/// itself whatever it computed.
final class CouchAssetIDTests: XCTestCase {

    func testTheIDOfKnownBytesMatchesWhatTheOtherAppDerives() {
        let cases = [
            "": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
            "PNG-ish bytes, hashed exactly as they are":
                "4b00f0d0b58005f889ced346765e465dce1630b8afee199a96480ffb6bc8755c",
        ]
        for (text, expected) in cases {
            let bytes = Data(text.utf8)
            XCTAssertEqual(CouchAssetID.sha256Hex(bytes), expected)
            XCTAssertEqual(CouchAssetID.forBytes(bytes), "asset:\(expected)")
        }
    }

    func testContentTypesAreSniffedFromTheSameMagicBytes() {
        func bytes(_ values: [UInt8]) -> Data { Data(values) }
        XCTAssertEqual(CouchAssetID.contentType(of: bytes([0x89, 0x50, 0x4E, 0x47, 0, 0])), "image/png")
        XCTAssertEqual(CouchAssetID.contentType(of: bytes([0xFF, 0xD8, 0xFF, 0])), "image/jpeg")
        XCTAssertEqual(CouchAssetID.contentType(of: Data("GIF89a".utf8)), "image/gif")
        XCTAssertEqual(CouchAssetID.contentType(of: Data("%PDF-1.7".utf8)), "application/pdf")
        XCTAssertEqual(CouchAssetID.contentType(of: Data("RIFF____WEBPVP8 ".utf8)), "image/webp")
        XCTAssertEqual(
            CouchAssetID.contentType(of: Data("nothing".utf8)), "application/octet-stream")
    }

    /// A hash is a name, and only a 64-character lowercase-hex one.
    func testOnlyARealHashIsTreatedAsOne() {
        let sha = "4b00f0d0b58005f889ced346765e465dce1630b8afee199a96480ffb6bc8755c"
        XCTAssertEqual(CouchAssetID.sha256Hex(ofAssetID: "asset:\(sha)"), sha)
        XCTAssertNil(CouchAssetID.sha256Hex(ofAssetID: "asset:not-a-hash"))
        XCTAssertNil(CouchAssetID.sha256Hex(ofAssetID: "page:\(sha)"))
        XCTAssertNil(CouchAssetID.sha256Hex(ofAssetID: sha))
        // Uppercase hex is a different string, and the protocol pins lowercase.
        XCTAssertFalse(CouchAssetID.isSHA256Hex(sha.uppercased()))
    }
}
