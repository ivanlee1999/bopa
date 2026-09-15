import NotableKit
import UIKit

/// The read-only layer: every text box on the page, drawn as rendered markdown.
///
/// One view for all of them rather than a view each. A box is a picture of some text, not a
/// control — nothing in it is tapped, scrolled or selected on its own — and a page with thirty
/// of them would otherwise be thirty views to keep in step with every scroll and zoom.
final class TextBoxLayerView: UIView {
    /// The boxes to draw, in the order they were made.
    var blocks: [CouchBlock] = [] {
        didSet {
            guard blocks != oldValue else { return }
            setNeedsDisplay()
        }
    }

    /// The box currently open in the editor, which this must not draw: two copies of the same
    /// words, one of them stale, half a pixel apart.
    var editingBlockID: String? {
        didSet {
            guard editingBlockID != oldValue else { return }
            setNeedsDisplay()
        }
    }

    /// The canvas's zoom and scroll, in the form the rest of the container speaks.
    var zoomScale: CGFloat = 1 {
        didSet { if zoomScale != oldValue { setNeedsDisplay() } }
    }
    var contentOffset: CGPoint = .zero {
        didSet { if contentOffset != oldValue { setNeedsDisplay() } }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        // Ink is drawn over text, and the canvas above is transparent. A layer that swallowed
        // touches would take the pen with it.
        isUserInteractionEnabled = false
        contentMode = .redraw
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        // This view covers the viewport, so the page has to be brought to it: scroll first,
        // then the shared renderer applies the zoom in page units. Same transform the image
        // views get in `updateContentGeometry`, expressed as a matrix instead of a frame.
        context.saveGState()
        defer { context.restoreGState() }
        context.translateBy(x: -contentOffset.x, y: -contentOffset.y)
        let skipped: Set<String> = editingBlockID.map { Set([$0]) } ?? []
        TextBoxLayout.draw(blocks: blocks, in: context, scale: zoomScale, skipping: skipped)
    }
}

/// The text view a box is typed into.
///
/// A subclass for one reason: it owns the undo stack for the typing session. `PKCanvasView` finds
/// its undo manager through the responder chain, and `CanvasContainerView` supplies one so that
/// PencilKit registers strokes with it — which means a text view put on that chain would register
/// every keystroke in the *page's* stack, and the rail's undo button would start rubbing out
/// letters one at a time between strokes. Keeping a private manager here leaves the page's stack
/// holding whole edits (registered on commit) and the text view's holding keystrokes, each where
/// it belongs.
final class TextBoxEditorView: UITextView {
    private let sessionUndoManager = UndoManager()

    override var undoManager: UndoManager? { sessionUndoManager }

    /// Typing is finished and what is in the box should be kept.
    var onDone: (() -> Void)?
    /// The box should go. Wired to the same path an emptied box takes, so there is one rule for
    /// what makes a box stop existing rather than two.
    var onDelete: (() -> Void)?

    /// Clears the typing stack. Called when a session starts, so the previous box's keystrokes
    /// are not on the stack of the next one.
    func resetUndo() {
        sessionUndoManager.removeAllActions()
    }

    /// The bar above the keyboard: the way out, and the way to be rid of the box.
    ///
    /// Tapping the paper also ends a session, but only where there is paper to tap — a box near
    /// the foot of the page can be entirely behind the keyboard, and then there is nowhere else
    /// to put a finger.
    func installAccessoryBar() {
        let bar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 0, height: 44))
        let delete = UIBarButtonItem(
            title: "Delete", style: .plain, target: self, action: #selector(deleteBox))
        delete.tintColor = UIColor(hex: 0x7D7979)
        delete.accessibilityIdentifier = "editor.textbox.delete"
        let done = UIBarButtonItem(
            title: "Done", style: .done, target: self, action: #selector(finish))
        done.accessibilityIdentifier = "editor.textbox.done"
        bar.items = [
            delete,
            UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil),
            done,
        ]
        bar.sizeToFit()
        inputAccessoryView = bar
    }

    /// Escape ends the session on the Mac, where there is no keyboard to hang a bar above.
    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(finish))]
    }

    @objc private func finish() { onDone?() }

    @objc private func deleteBox() { onDelete?() }
}
