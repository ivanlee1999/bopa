import CryptoKit
import Foundation

/// Identifiers two devices agree on without having spoken — protocol §1.3.
///
/// Normally an id is minted at random by whichever device created the thing, and the merge keeps
/// both when two devices create "the same" thing offline: two notebooks called Journal, two pages
/// for the same Tuesday, neither wrong and neither reconcilable. The way out is to stop minting
/// the id and start *computing* it, from something both devices already know — the date, the
/// parent page and a sheet number — so that two devices which never met produce one id and the
/// ordinary merge unions them into one document.
///
/// `PageSplit` has done this since sheets existed. Journal pages need exactly the same property,
/// so the hashing lives here and both callers spell their seed in the seed table below.
///
/// The digest is rendered in the shape of a UUID because that is what every other id in the file
/// looks like — nothing reads it as one. It is not a UUIDv5: no namespace, no version nibble,
/// just the first 16 bytes. The only property required of it is that Kotlin and Swift compute the
/// same string, which `docs/couch-sync-vectors/vectors.json` pins for every seed in use.
public enum DerivedID {

    /// The first 16 bytes of SHA-256 over [seed], in UUID shape.
    public static func derive(_ seed: String) -> String {
        let digest = SHA256.hash(data: Data(seed.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        let bytes = String(hex.prefix(32))
        func part(_ range: Range<Int>) -> String {
            let start = bytes.index(bytes.startIndex, offsetBy: range.lowerBound)
            let end = bytes.index(bytes.startIndex, offsetBy: range.upperBound)
            return String(bytes[start..<end])
        }
        return "\(part(0..<8))-\(part(8..<12))-\(part(12..<16))-\(part(16..<20))-\(part(20..<32))"
    }

    // MARK: - Seeds

    /// Sheet [index] of the page [parentId] was divided into — `PageSplit.childId`.
    public static func pageSplitSeed(parentId: String, sheet index: Int) -> String {
        "notable-page-split:\(parentId):\(index)"
    }

    /// The notebook holding [year]'s journal.
    ///
    /// A year rather than the whole journal: a notebook's page list is one document, so a single
    /// lifelong journal would put every day ever written into one `pageIds` array and rewrite it
    /// on every new day. A year is the coarsest unit that keeps that array to a few hundred
    /// entries, and it is also how people file paper ones.
    public static func journalNotebookSeed(year: Int) -> String {
        "notable-journal:\(String(format: "%04d", year))"
    }

    /// The page holding the entry for one day, as `yyyy-MM-dd` in the writer's local civil date.
    ///
    /// The date is the whole identity: there is no device, no notebook and no counter in the
    /// seed, which is what makes two devices that both open Tuesday offline write to one page
    /// instead of two.
    public static func journalDaySeed(date: String) -> String {
        "notable-journal-day:\(date)"
    }

    /// The folder the year notebooks are filed in.
    public static let journalFolderSeed = "notable-journal-folder"

    // MARK: - The ids themselves

    public static func journalNotebookId(year: Int) -> String {
        derive(journalNotebookSeed(year: year))
    }

    public static func journalDayPageId(date: String) -> String {
        derive(journalDaySeed(date: date))
    }

    public static var journalFolderId: String { derive(journalFolderSeed) }
}
