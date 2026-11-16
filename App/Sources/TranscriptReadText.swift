import NotableKit
import SwiftUI

/// Server Markdown is a read-only projection, never an editor or a web document.
struct TranscriptReadText: View {
    let content: TranscriptContent

    var body: some View {
        Group {
            if content.isMarkdown {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(TranscriptMarkdown.parse(content.text).enumerated()), id: \.offset) { _, block in
                        switch block {
                        case .line(let line, let indent, let checked):
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                if let checked {
                                    Image(systemName: checked ? "checkmark.square" : "square")
                                        .accessibilityLabel(checked ? "Checked" : "Unchecked")
                                } else {
                                    switch line.kind {
                                    case .bullet: Text("•")
                                    case .numbered(let number): Text("\(number).")
                                    default: EmptyView()
                                    }
                                }
                                inline(line.spans).font(font(line.kind)).frame(maxWidth: .infinity, alignment: .leading)
                            }.padding(.leading, CGFloat(min(indent, 24)) * 6)
                        case .table(let headers, let rows, let alignments):
                            ScrollView(.horizontal) {
                                VStack(alignment: .leading, spacing: 0) {
                                    row(headers, alignments: alignments, header: true)
                                    ForEach(Array(rows.enumerated()), id: \.offset) { _, cells in
                                        row(cells, alignments: alignments, header: false)
                                    }
                                }.padding(.bottom, 4)
                            }
                            .accessibilityLabel("Recognized table")
                        case .code(let source):
                            Text(verbatim: source).font(.body.monospaced()).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            } else {
                Text(verbatim: content.text).frame(maxWidth: .infinity, alignment: .leading)
            }
        }.textSelection(.enabled)
    }

    private func row(_ cells: [String], alignments: [TranscriptMarkdown.Alignment], header: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { index, cell in
                inline(MarkdownText.parseInline(cell))
                    .fontWeight(header ? .semibold : .regular)
                    .multilineTextAlignment(textAlignment(alignments[index]))
                    .frame(width: 140, alignment: alignment(alignments[index]))
                    .padding(10)
            }
        }
        .overlay(alignment: .bottom) { Rectangle().fill(Color.secondary.opacity(0.3)).frame(height: header ? 1 : 0.5) }
    }
    private func inline(_ spans: [MarkdownText.Span]) -> Text {
        spans.reduce(Text("")) { result, span in
            var text = Text(verbatim: span.text)
            if span.traits.contains(.bold) { text = text.bold() }
            if span.traits.contains(.italic) { text = text.italic() }
            if span.traits.contains(.code) { text = text.monospaced() }
            if span.traits.contains(.link) { text = text.underline() }
            return result + text
        }
    }
    private func font(_ kind: MarkdownText.LineKind) -> Font {
        switch kind {
        case .heading(let level): level == 1 ? .title2 : level == 2 ? .title3 : .headline
        default: .body
        }
    }
    private func alignment(_ value: TranscriptMarkdown.Alignment) -> Alignment {
        switch value { case .leading: .leading; case .center: .center; case .trailing: .trailing }
    }
    private func textAlignment(_ value: TranscriptMarkdown.Alignment) -> TextAlignment {
        switch value { case .leading: .leading; case .center: .center; case .trailing: .trailing }
    }
}
