import Foundation

/// Whether a page ends at its sheet — protocol §3.3.3.
///
/// A page used to be an endless vertical canvas, and that was the mistake `PageSplit` exists to
/// undo: everything below the first sheet was invisible to the overview, to bookmarks and to
/// reordering, because as far as the file was concerned it was all one page. A page ends at its
/// sheet now, and the way to keep writing is the next page.
///
/// A journal entry is the one thing that argument does not cover. A day is not a sheet of paper
/// that runs out; it is a day, and dividing it into "19 September, page 3" puts a boundary
/// through the middle of a thought for no reason the writer would recognize. So a page may
/// *declare* that it scrolls, and a page that declares it is exempt from the split and from the
/// viewport's bottom clamp.
///
/// The exemption is a declaration rather than a heuristic on purpose: a tall page and a scrolling
/// page are indistinguishable by their content, and guessing would make the split — which is
/// destructive and derives new page ids — depend on a guess.
public enum PageLayout {

    /// The page ends at its sheet. The default, and what every page written before this said by
    /// saying nothing.
    public static let sheet = "sheet"

    /// Sheet width, unbounded height.
    public static let scroll = "scroll"

    /// How much blank paper a scroll page keeps below its lowest ink, in page units.
    ///
    /// Normative, because it is an input to `materializedHeight` and therefore to bytes on the
    /// wire: two devices that padded differently would rewrite each other's `pageHeight` on every
    /// save. 1000 units is about 150 mm — a screenful on a 10.3" panel at fit-to-width, so there
    /// is always somewhere to write next.
    public static let scrollSlack = 1000

    /// Whether [layout] means "does not end at its sheet".
    ///
    /// Absent and `sheet` are bounded; **anything else is treated as scrolling**, including a
    /// value this build has never heard of. That asymmetry is deliberate. The two outcomes are
    /// not equally bad: declining to divide a page can be undone by a later build that
    /// understands the value, while dividing one that should not have been divided mints derived
    /// child ids, moves ink between documents and writes tombstones — and no later build can put
    /// that back together.
    public static func isScroll(_ layout: String?) -> Bool {
        guard let layout, !layout.isEmpty else { return false }
        return layout != sheet
    }

    /// The `pageHeight` a scroll page writes: enough sheets to hold every piece of content plus
    /// [scrollSlack], never fewer than one.
    ///
    /// A scroll page has no height of its own — that is the point of it — but it writes one
    /// anyway, and this is the reason the feature is safe to roll out. A reader that predates
    /// `layout` drops the field and sees an ordinary page; if that page also declared a short
    /// height, every stroke below it would start past the sheet and the reader's split would
    /// carve the day into pieces. Declaring a height that already covers the content means the
    /// split finds nothing below sheet 0 and leaves the page alone.
    ///
    /// Rounded up to whole sheets so that the value only changes when the writing crosses a sheet
    /// boundary, rather than drifting by a few units on every stroke and pushing the document
    /// each time.
    public static func materializedHeight(contentBottom: Float, sheetHeight: Int) -> Int {
        guard sheetHeight > 0 else { return 0 }
        let needed = max(0, contentBottom) + Float(scrollSlack)
        let sheets = max(1, Int((needed / Float(sheetHeight)).rounded(.up)))
        return sheets * sheetHeight
    }
}
