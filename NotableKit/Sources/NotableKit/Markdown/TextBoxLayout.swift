import CoreGraphics
import CoreText
import Foundation

/// How a text box is sized and set, in **page units** (1 unit = 0.15 mm, see ``PageUnits``).
///
/// One value rather than constants scattered through the editor, because the same numbers are
/// needed in four places that must agree — the on-canvas layer, the height written to the block,
/// the thumbnail, and the seam preview — and because the BOOX has to be given the same ones.
/// `TextBoxMetrics.kt` in the Android app is this table in Kotlin.
public struct TextBoxMetrics: Equatable, Sendable {
    /// The em size of ordinary text. 32 units is 4.8 mm, near enough to 13.6 pt on paper: the
    /// size a printed note is set at, and legible on a 10.3" BOOX and an 11" iPad at the zoom
    /// each opens a page at.
    public var body: CGFloat
    public var headingScales: [CGFloat]
    /// Multiplied into the font's natural leading.
    public var lineHeightMultiple: CGFloat
    /// Inset on every side, included in the block's stored `width`.
    public var padding: CGFloat
    /// How far a list item's wrapped lines are indented, so they align under the first word
    /// rather than under the bullet.
    public var listIndent: CGFloat
    /// The width a new box is given, before the right-margin clamp.
    public var preferredWidth: CGFloat
    /// The narrowest a box may be. Below this a word cannot break sensibly and the box becomes
    /// a column of single letters.
    public var minimumWidth: CGFloat
    /// Space kept between a box and the right edge of the sheet.
    public var rightMargin: CGFloat

    public init(
        body: CGFloat = 32,
        headingScales: [CGFloat] = [2, 1.5, 1.25],
        lineHeightMultiple: CGFloat = 1.3,
        padding: CGFloat = 12,
        listIndent: CGFloat = 40,
        preferredWidth: CGFloat = 560,
        minimumWidth: CGFloat = 160,
        rightMargin: CGFloat = 40
    ) {
        self.body = body
        self.headingScales = headingScales
        self.lineHeightMultiple = lineHeightMultiple
        self.padding = padding
        self.listIndent = listIndent
        self.preferredWidth = preferredWidth
        self.minimumWidth = minimumWidth
        self.rightMargin = rightMargin
    }

    public static let standard = TextBoxMetrics()

    /// The em size for a line, in page units.
    public func size(for kind: MarkdownText.LineKind) -> CGFloat {
        guard case .heading(let level) = kind else { return body }
        let index = min(max(level, 1), headingScales.count) - 1
        return body * headingScales[index]
    }
}

/// Setting a text box's markdown: building the attributed string, measuring it, and drawing it.
///
/// Everything is in page units. A caller drawing at some zoom scales the context, exactly as the
/// stroke and template renderers do — so one implementation serves the canvas, the thumbnail and
/// the seam preview, and a box cannot come out a different shape in any of them.
public enum TextBoxLayout {

    /// The text of `source`, set at `metrics`, ready to lay out at a width in page units.
    ///
    /// Built with CoreText attributes throughout — `CTFont`, `CTParagraphStyle`, `CGColor` — and
    /// not the AppKit/UIKit spellings. They look interchangeable and are not: `CTFrameDraw`
    /// ignores an `NSParagraphStyle`, so a string built the familiar way lays out with no line
    /// height and no list indent at all, and only on a device (the measurement agrees with it,
    /// so nothing catches it).
    public static func attributedString(
        _ source: String, metrics: TextBoxMetrics = .standard
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let lines = MarkdownText.parse(source)

        for (index, line) in lines.enumerated() {
            let size = metrics.size(for: line.kind)
            let isList: Bool
            let prefix: String
            switch line.kind {
            case .bullet:
                prefix = "\u{2022} "
                isList = true
            case .numbered(let number):
                prefix = "\(number). "
                isList = true
            case .body, .heading:
                prefix = ""
                isList = false
            }
            // A heading is a line, not a paragraph with air around it: a text box is small, and a
            // blank line above every heading would be most of the box.
            let spacingBefore = isHeading(line.kind) && index > 0 ? size * 0.3 : 0
            let paragraph = paragraphStyle(
                lineHeightMultiple: metrics.lineHeightMultiple,
                headIndent: isList ? metrics.listIndent : 0,
                spacingBefore: spacingBefore)

            func attributes(_ traits: MarkdownText.SpanTraits) -> [NSAttributedString.Key: Any] {
                Self.attributes(
                    traits: traits, kind: line.kind, metrics: metrics, paragraph: paragraph)
            }

            if !prefix.isEmpty {
                result.append(NSAttributedString(string: prefix, attributes: attributes([])))
            }
            for span in line.spans {
                result.append(NSAttributedString(string: span.text, attributes: attributes(span.traits)))
            }
            if index < lines.count - 1 {
                // The newline carries this line's font and paragraph style, which is what gives an
                // empty line its height: a run of zero characters has no size, so a blank line
                // built without it collapses and the gap the user typed disappears.
                result.append(NSAttributedString(string: "\n", attributes: attributes([])))
            }
        }
        return result
    }

    private static func attributes(
        traits: MarkdownText.SpanTraits,
        kind: MarkdownText.LineKind,
        metrics: TextBoxMetrics,
        paragraph: CTParagraphStyle
    ) -> [NSAttributedString.Key: Any] {
        var size = metrics.size(for: kind)
        // A code run is set a touch smaller: a monospaced face at the same em reads noticeably
        // larger than the text around it and breaks the line.
        if traits.contains(.code) { size *= 0.92 }

        var symbolic: CTFontSymbolicTraits = []
        // A heading is bold by being a heading, so nothing has to be typed to make it one.
        if traits.contains(.bold) || isHeading(kind) { symbolic.insert(.traitBold) }
        if traits.contains(.italic) { symbolic.insert(.traitItalic) }

        var attributes: [NSAttributedString.Key: Any] = [
            key(kCTFontAttributeName): font(
                size: size, monospaced: traits.contains(.code), symbolic: symbolic),
            key(kCTParagraphStyleAttributeName): paragraph,
            key(kCTForegroundColorAttributeName): CGColor(gray: 0, alpha: 1),
        ]
        if traits.contains(.link) {
            attributes[key(kCTUnderlineStyleAttributeName)] = CTUnderlineStyle.single.rawValue
        }
        return attributes
    }

    private static func key(_ name: CFString) -> NSAttributedString.Key {
        NSAttributedString.Key(name as String)
    }

    private static func paragraphStyle(
        lineHeightMultiple: CGFloat, headIndent: CGFloat, spacingBefore: CGFloat
    ) -> CTParagraphStyle {
        var multiple = lineHeightMultiple
        var indent = headIndent
        var before = spacingBefore
        return withUnsafeBytes(of: &multiple) { multiplePtr in
            withUnsafeBytes(of: &indent) { indentPtr in
                withUnsafeBytes(of: &before) { beforePtr in
                    let settings = [
                        CTParagraphStyleSetting(
                            spec: .lineHeightMultiple,
                            valueSize: MemoryLayout<CGFloat>.size,
                            value: multiplePtr.baseAddress!),
                        CTParagraphStyleSetting(
                            spec: .headIndent,
                            valueSize: MemoryLayout<CGFloat>.size,
                            value: indentPtr.baseAddress!),
                        CTParagraphStyleSetting(
                            spec: .paragraphSpacingBefore,
                            valueSize: MemoryLayout<CGFloat>.size,
                            value: beforePtr.baseAddress!),
                    ]
                    return CTParagraphStyleCreate(settings, settings.count)
                }
            }
        }
    }

    private static func isHeading(_ kind: MarkdownText.LineKind) -> Bool {
        if case .heading = kind { return true }
        return false
    }

    private static func font(
        size: CGFloat, monospaced: Bool, symbolic: CTFontSymbolicTraits
    ) -> CTFont {
        let base: CTFont = monospaced
            ? CTFontCreateWithName("Menlo" as CFString, size, nil)
            : CTFontCreateUIFontForLanguage(.system, size, nil)
                ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        guard !symbolic.isEmpty else { return base }
        // Nil when the family has no such face — italic monospace on some systems — where the
        // upright face is the right answer rather than a failure.
        return CTFontCreateCopyWithSymbolicTraits(base, size, nil, symbolic, symbolic) ?? base
    }

    // MARK: Geometry

    /// The width a new box gets at `x` on a sheet `pageWidth` wide: the preferred width, pulled
    /// in so the box stops short of the right edge, and never below the minimum.
    ///
    /// A box narrower than the minimum is possible only on a sheet too narrow to hold one, where
    /// running past the edge is better than a column one letter wide.
    public static func defaultWidth(
        x: CGFloat, pageWidth: CGFloat, metrics: TextBoxMetrics = .standard
    ) -> CGFloat {
        let available = pageWidth - x - metrics.rightMargin
        return max(min(metrics.preferredWidth, available), metrics.minimumWidth)
    }

    /// How tall `source` is when set into a box `width` page units wide, padding included.
    ///
    /// Never less than one line: an empty box still has to be big enough to put a caret in.
    public static func measuredHeight(
        source: String, width: CGFloat, metrics: TextBoxMetrics = .standard
    ) -> CGFloat {
        let text = attributedString(source, metrics: metrics)
        let inner = max(width - metrics.padding * 2, 1)
        let framesetter = CTFramesetterCreateWithAttributedString(text)
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(location: 0, length: 0), nil,
            CGSize(width: inner, height: .greatestFiniteMagnitude), nil)
        let oneLine = metrics.body * metrics.lineHeightMultiple
        return (max(suggested.height, oneLine) + metrics.padding * 2).rounded(.up)
    }

    /// The rectangle a block occupies, in page units. Nil for a block that is not a positioned
    /// text box — a flowing one, or a picture.
    public static func frame(of block: CouchBlock) -> CGRect? {
        guard block.kind == "md", let x = block.x, let y = block.y else { return nil }
        let width = CGFloat(block.width ?? Int(TextBoxMetrics.standard.preferredWidth))
        let height = CGFloat(block.height ?? 0)
        return CGRect(x: CGFloat(x), y: CGFloat(y), width: width, height: max(height, 1))
    }

    /// The text boxes of a page, in a stable order: the topmost-drawn last, so a hit test can
    /// walk it backwards and find what the eye would pick.
    public static func textBoxes(in blocks: [CouchBlock]) -> [CouchBlock] {
        blocks.filter { $0.kind == "md" && $0.x != nil && $0.y != nil }
            .sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
    }

    // MARK: Drawing

    /// Draws every positioned markdown block into a context whose coordinate space is page
    /// units **with y increasing downwards**, scaled by `scale`.
    ///
    /// Blocks of another kind, and flowing ones, are skipped rather than drawn as placeholders:
    /// this app has no UI for either, and a box of question marks over somebody's ink is worse
    /// than nothing until it does.
    public static func draw(
        blocks: [CouchBlock],
        in context: CGContext,
        scale: CGFloat,
        metrics: TextBoxMetrics = .standard,
        skipping skipped: Set<String> = []
    ) {
        for block in textBoxes(in: blocks) where !skipped.contains(block.id) {
            guard let frame = frame(of: block), let text = block.text, !text.isEmpty else {
                continue
            }
            draw(source: text, in: frame, context: context, scale: scale, metrics: metrics)
        }
    }

    /// Draws one box's markdown into `frame` (page units, y down).
    public static func draw(
        source: String,
        in frame: CGRect,
        context: CGContext,
        scale: CGFloat,
        metrics: TextBoxMetrics = .standard
    ) {
        let inner = frame.insetBy(dx: metrics.padding, dy: metrics.padding)
        guard inner.width > 0, inner.height > 0 else { return }

        let text = attributedString(source, metrics: metrics)
        let framesetter = CTFramesetterCreateWithAttributedString(text)
        // Laid out at its natural height rather than the box's, then clipped: a box whose stored
        // height is stale (the other device measured it with its own fonts) should show as much
        // as it has room for, not reflow to a height nobody chose.
        let height = max(
            CTFramesetterSuggestFrameSizeWithConstraints(
                framesetter, CFRange(location: 0, length: 0), nil,
                CGSize(width: inner.width, height: .greatestFiniteMagnitude), nil).height,
            inner.height)
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: inner.width, height: height), transform: nil)
        let ctFrame = CTFramesetterCreateFrame(
            framesetter, CFRange(location: 0, length: 0), path, nil)

        context.saveGState()
        defer { context.restoreGState() }
        context.scaleBy(x: scale, y: scale)
        context.clip(to: frame)
        // CoreText lays out upwards from the origin of its path, and the page is drawn downwards.
        // Flipping here — rather than asking every caller to hand over a y-up context — keeps the
        // convention of this file the same as the template and stroke renderers'.
        context.translateBy(x: inner.minX, y: inner.minY + height)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        CTFrameDraw(ctFrame, context)
    }
}
