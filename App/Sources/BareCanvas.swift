import PencilKit
import SwiftUI

/// Diagnostic-only screen (launch argument `--bare-canvas`): a naked PKCanvasView with no
/// navigation, tool picker, or scroll configuration. Used to bisect "canvas doesn't ink"
/// problems between app structure and the input-injection path.
struct BareCanvasScreen: UIViewRepresentable {
    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.delegate = context.coordinator
        canvas.drawingPolicy = .anyInput
        canvas.tool = PKInkingTool(.pen, color: .black, width: 5)
        canvas.isAccessibilityElement = true
        canvas.accessibilityIdentifier = "bare.canvas"
        canvas.accessibilityValue = "strokes:0"
        if CommandLine.arguments.contains("--bare-scroll") {
            canvas.contentSize = CGSize(width: 1404, height: 3744)
            canvas.minimumZoomScale = 0.25
            canvas.maximumZoomScale = 3
        }
        if CommandLine.arguments.contains("--bare-picker") {
            let picker = context.coordinator.toolPicker
            if CommandLine.arguments.contains("--uitest-reset-tool") {
                picker.selectedTool = PKInkingTool(.pen, color: .black, width: 5)
            }
            picker.setVisible(true, forFirstResponder: canvas)
            picker.addObserver(canvas)
            canvas.becomeFirstResponder()
        }
        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        let toolPicker = PKToolPicker()
        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            canvasView.accessibilityValue = "strokes:\(canvasView.drawing.strokes.count)"
        }
    }
}


/// Bisecting host: `--bare-editorcanvas` swaps in the real editor canvas;
/// `--bare-nav` wraps whichever canvas in a NavigationStack like the real editor.
struct DiagnosticHost: View {
    @State private var drawing = PKDrawing()

    var body: some View {
        if CommandLine.arguments.contains("--bare-nav") {
            NavigationStack {
                core
                    .navigationTitle("Diag")
                    .navigationBarTitleDisplayMode(.inline)
            }
        } else {
            core
        }
    }

    @ViewBuilder
    private var core: some View {
        if CommandLine.arguments.contains("--bare-editorcanvas") {
            EditorCanvasView(pageId: "diag", background: nil, drawing: $drawing, onChanged: {})
        } else {
            BareCanvasScreen()
        }
    }
}
