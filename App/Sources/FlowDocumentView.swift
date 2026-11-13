import NotableKit
import PencilKit
import SwiftUI
import UIKit

@MainActor
final class FlowInputController {
    weak var view: FlowNativeTextView?
    func finish() { view?.finish() }
    func format(_ command: FlowNativeTextView.Command) { view?.apply(command) }
}

/// Native editing keeps selection, dictation, IME composition and undo in UIKit. Markdown is
/// the source; syntax styling changes attributes only, so caret offsets never need remapping.
final class FlowNativeTextView: UITextView {
    enum Command { case bold, italic, heading, list, checklist, link }
    var changed: ((String) -> Void)?
    var tags: (() -> Void)?

    func installAccessory() {
        let bar = UIToolbar()
        let styles = UIMenu(children: [
            UIAction(title: "Heading", image: UIImage(systemName: "textformat.size")) { [weak self] _ in self?.apply(.heading) },
            UIAction(title: "Bulleted list", image: UIImage(systemName: "list.bullet")) { [weak self] _ in self?.apply(.list) },
            UIAction(title: "Checklist", image: UIImage(systemName: "checklist")) { [weak self] _ in self?.apply(.checklist) },
            UIAction(title: "Link", image: UIImage(systemName: "link")) { [weak self] _ in self?.apply(.link) },
        ])
        bar.items = [
            UIBarButtonItem(title: "Aa", menu: styles),
            UIBarButtonItem(title: "B", primaryAction: UIAction { [weak self] _ in self?.apply(.bold) }),
            UIBarButtonItem(title: "I", primaryAction: UIAction { [weak self] _ in self?.apply(.italic) }),
            UIBarButtonItem(title: "#", primaryAction: UIAction { [weak self] _ in self?.tags?() }),
            UIBarButtonItem(systemItem: .flexibleSpace),
            UIBarButtonItem(title: "Done", style: .done, target: self, action: #selector(finish))
        ]
        bar.sizeToFit(); inputAccessoryView = bar
    }

    @objc func finish() {
        unmarkText(); changed?(text ?? ""); resignFirstResponder()
    }

    func apply(_ command: Command) {
        guard markedTextRange == nil else { return }
        let selected = selectedRange
        let value = (text as NSString?) ?? ""
        guard NSMaxRange(selected) <= value.length else { return }
        let content = value.substring(with: selected)
        let before: String, after: String
        switch command {
        case .bold: before = "**"; after = "**"
        case .italic: before = "*"; after = "*"
        case .link: before = "["; after = "](https://)"
        case .heading: before = "## "; after = ""
        case .list: before = "- "; after = ""
        case .checklist: before = "- [ ] "; after = ""
        }
        becomeFirstResponder()
        insertText(before + content + after)
        selectedRange = NSRange(location: selected.location + before.utf16.count, length: content.utf16.count)
        changed?(text ?? "")
        styleSource()
    }

    func styleSource() {
        guard markedTextRange == nil else { return }
        let range = NSRange(location: 0, length: textStorage.length)
        let base = UIFont.preferredFont(forTextStyle: .body)
        textStorage.beginEditing()
        textStorage.addAttributes([.font: base, .foregroundColor: UIColor.label], range: range)
        let source = textStorage.string as NSString
        let headings = try? NSRegularExpression(pattern: "(?m)^#{1,3} .+$")
        headings?.enumerateMatches(in: source as String, range: range) { match, _, _ in
            guard let match else { return }
            self.textStorage.addAttribute(.font, value: UIFont.preferredFont(forTextStyle: .title2), range: match.range)
        }
        for (pattern, traits) in [("\\*\\*([^\\n]+?)\\*\\*", UIFontDescriptor.SymbolicTraits.traitBold),
                                  ("(?<!\\*)\\*([^\\n*]+?)\\*(?!\\*)", .traitItalic)] {
            let expression = try? NSRegularExpression(pattern: pattern)
            expression?.enumerateMatches(in: source as String, range: range) { match, _, _ in
                guard let match, let descriptor = base.fontDescriptor.withSymbolicTraits(traits) else { return }
                self.textStorage.addAttribute(.font, value: UIFont(descriptor: descriptor, size: base.pointSize), range: match.range)
            }
        }
        textStorage.endEditing()
        typingAttributes = [.font: base, .foregroundColor: UIColor.label]
    }

    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(input: "b", modifierFlags: .command, action: #selector(bold)),
         UIKeyCommand(input: "i", modifierFlags: .command, action: #selector(italic)),
         UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(finish))]
    }
    @objc private func bold() { apply(.bold) }
    @objc private func italic() { apply(.italic) }
}

private struct FlowTextInput: UIViewRepresentable {
    @Binding var source: String
    let controller: FlowInputController
    let tags: () -> Void
    let began: () -> Void
    let ended: () -> Void

    func makeUIView(context: Context) -> FlowNativeTextView {
        let view = FlowNativeTextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.isScrollEnabled = false
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.accessibilityLabel = "Entry text"
        view.accessibilityIdentifier = "editor.flowText"
        view.installAccessory()
        return view
    }

    func updateUIView(_ view: FlowNativeTextView, context: Context) {
        context.coordinator.parent = self
        view.changed = { source = $0 }
        view.tags = tags
        if !view.isFirstResponder, view.markedTextRange == nil, !TextVersions.sameSource(view.text, source) {
            view.text = source; view.styleSource()
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: FlowNativeTextView, context: Context) -> CGSize? {
        guard let width = proposal.width else { return nil }
        return CGSize(width: width, height: max(140, uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height))
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: FlowTextInput
        init(_ parent: FlowTextInput) { self.parent = parent }
        func textViewDidBeginEditing(_ textView: UITextView) {
            parent.controller.view = textView as? FlowNativeTextView; parent.began()
        }
        func textViewDidEndEditing(_ textView: UITextView) {
            parent.source = textView.text; parent.ended()
        }
        func textViewDidChange(_ textView: UITextView) {
            parent.source = textView.text
            (textView as? FlowNativeTextView)?.styleSource()
            revealCaret(textView)
        }
        func textViewDidChangeSelection(_ textView: UITextView) { revealCaret(textView) }
        private func revealCaret(_ textView: UITextView) {
            guard textView.isFirstResponder, let selection = textView.selectedTextRange else { return }
            var ancestor = textView.superview
            while let view = ancestor {
                if let scroll = view as? UIScrollView {
                    let caret = textView.caretRect(for: selection.end).insetBy(dx: -8, dy: -24)
                    scroll.scrollRectToVisible(textView.convert(caret, to: scroll), animated: false)
                    return
                }
                ancestor = view.superview
            }
        }
    }
}

struct FlowDocumentView: View {
    @ObservedObject var model: FlowPageModel
    let controller: FlowInputController
    let notebookID: String
    let tags: () -> Void
    let draw: () -> Void
    var newThought: (() -> Void)?
    @EnvironmentObject private var store: NotebookStore
    @State private var showingVersions = false

    var body: some View {
        VStack(spacing: 0) {
            if let error = model.error {
                VStack(alignment: .leading, spacing: 8) {
                    Text(error).font(.callout)
                    HStack {
                        Button("Retry") { model.flush() }
                        if model.parts.contains(where: \.conflict) {
                            Button("Use current") { controller.finish(); model.useCurrent() }
                            Button("Add draft") { controller.finish(); model.addDraftToNote() }
                        }
                    }
                }.padding().frame(maxWidth: .infinity, alignment: .leading).background(Modernist.rail)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let page = model.page, FlowCanvasPreview.hasCanvas(page) {
                        Button(action: draw) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Handwriting").font(.caption).foregroundStyle(.secondary)
                                FlowCanvasPreview(page: page, notebookID: notebookID)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain).accessibilityLabel("Edit original handwriting")
                        ModernistRule()
                    }
                    ForEach(model.parts) { part in
                        if part.isMarkdown {
                            FlowTextInput(source: Binding(get: { model.source(for: part.id) }, set: { model.update($0, id: part.id) }),
                                          controller: controller, tags: tags,
                                          began: model.beganEditing, ended: model.endedEditing)
                                .frame(maxWidth: .infinity)
                        } else if let block = part.blocks.first {
                            FlowBoundaryView(block: block, page: model.page, notebookID: notebookID)
                        }
                    }
                }.padding(.horizontal, 24).padding(.vertical, 20).frame(maxWidth: 760)
                    .frame(maxWidth: .infinity)
            }.scrollDismissesKeyboard(.interactively)
            if Platform.isMac {
                HStack(spacing: 6) {
                    Button("B") { controller.format(.bold) }.accessibilityLabel("Bold")
                    Button("I") { controller.format(.italic) }.accessibilityLabel("Italic")
                    Button { controller.format(.list) } label: { Image(systemName: "list.bullet") }.accessibilityLabel("Bulleted list")
                    Button { controller.format(.checklist) } label: { Image(systemName: "checklist") }.accessibilityLabel("Checklist")
                    Button { controller.format(.link) } label: { Image(systemName: "link") }.accessibilityLabel("Link")
                    Button(action: tags) { Image(systemName: "number") }.accessibilityLabel("Tags")
                    Spacer()
                    Text("Text").font(.caption).foregroundStyle(.secondary)
                }.buttonStyle(.borderless).padding(12).background(Modernist.rail)
            }
            HStack {
                Text(model.saved ? "Saved on device" : "Saving…").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { controller.finish(); newThought?() } label: { Label("New thought", systemImage: "plus") }
                    .disabled(newThought == nil).frame(minHeight: 44)
            }.padding(.horizontal, 16).background(Modernist.rail)
            if !model.versions.isEmpty {
                Button("Recovered versions (\(model.versions.count))") { controller.finish(); showingVersions = true }
                    .font(.caption).padding(8)
            }
        }.background(Modernist.canvas)
            .sheet(isPresented: $showingVersions) {
                NavigationStack {
                    List(model.versions, id: \.id) { version in
                        VStack(alignment: .leading, spacing: 12) {
                            Text(version.text ?? "").textSelection(.enabled)
                            Button("Add to note") { model.restoreVersion(version); showingVersions = false }
                        }.padding(.vertical, 8)
                    }.navigationTitle("Recovered versions")
                        .toolbar { Button("Done") { showingVersions = false } }
                }
            }
    }
}

struct FlowCanvasPreview: View {
    let page: PageFile
    let notebookID: String
    @EnvironmentObject private var store: NotebookStore

    static func hasCanvas(_ page: PageFile) -> Bool {
        let claimed = FlowText.inkIDs(in: page.blocks)
        return page.strokes.contains { !claimed.contains($0.id) } || !page.images.isEmpty || !TextBoxLayout.textBoxes(in: page.blocks).isEmpty
            || page.backgroundType != "native"
    }

    var body: some View {
        if let image = FlowPagePreview.canvas(page: page, notebookDir: store.notebookDirURL(notebookID), storeRoot: store.rootURL) {
            Image(uiImage: image).resizable().scaledToFit()
        }
    }
}

struct FlowBoundaryView: View {
    let block: CouchBlock
    let page: PageFile?
    let notebookID: String
    @EnvironmentObject private var store: NotebookStore
    var body: some View {
        if block.kind == "ink", let page {
            if let image = FlowPagePreview.ink(page: page, blockID: block.id) {
                Image(uiImage: image).resizable().scaledToFit()
            }
        } else if block.kind == "image", let asset = block.imageAssetId,
                  let sha = CouchAssetID.sha256Hex(ofAssetID: asset),
                  let image = UIImage(contentsOfFile: store.notebookDirURL(notebookID).appendingPathComponent("images/\(sha)").path) {
            Image(uiImage: image).resizable().scaledToFit()
        } else if block.kind == "link", let target = block.targetNotebookId {
            Label(store.manifest(id: target)?.title ?? "Linked note", systemImage: "link")
        } else {
            Label(block.kind.capitalized, systemImage: block.kind == "audio" ? "waveform" : "paperclip")
                .foregroundStyle(.secondary)
        }
    }
}
