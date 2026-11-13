import NotableKit
import PencilKit
import SwiftUI

struct TitleRenameRequest: Identifiable {
    let notebookID: String
    var pageID: String?
    var title: String
    var id: String { notebookID + "/" + (pageID ?? "title") }
}

struct TitleRenameSheet: View {
    @EnvironmentObject private var store: NotebookStore
    @EnvironmentObject private var transcripts: HandwritingTranscriptIndex
    @Environment(\.dismiss) private var dismiss
    let request: TitleRenameRequest
    var saved: (() -> Void)?
    @State private var title: String
    @State private var writing = false
    @State private var drawing = PKDrawing()
    @State private var recognizing = false
    @State private var recognitionOwner = UUID()
    @State private var error: String?
    @FocusState private var focused: Bool

    init(request: TitleRenameRequest, saved: (() -> Void)? = nil) {
        self.request = request; self.saved = saved; _title = State(initialValue: request.title)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                if !Platform.isMac && UIDevice.current.userInterfaceIdiom == .pad {
                    Picker("Title input", selection: $writing) {
                        Text("Type").tag(false); Text("Write").tag(true)
                    }.pickerStyle(.segmented)
                        .disabled(recognizing)
                        .onChange(of: writing) { _, value in focused = !value }
                }
                TextField(request.pageID == nil ? "Note title" : "Page title", text: $title)
                    .font(.title3).textFieldStyle(.roundedBorder).focused($focused)
                    .accessibilityIdentifier("rename.title")
                    .disabled(recognizing)
                    .onSubmit(save)
                if writing {
                    TitleInkPad(drawing: $drawing, contact: {
                        transcripts.setDrawing($0, owner: recognitionOwner, notebookID: request.notebookID, pageID: request.pageID ?? "title-pad", store: store)
                    }).frame(height: 190)
                        .allowsHitTesting(!recognizing)
                        .background(.white).overlay { Rectangle().stroke(Modernist.neutral400) }
                        .accessibilityLabel("Write a title")
                    HStack {
                        Button("Clear") { drawing = PKDrawing() }.frame(minHeight: 44).disabled(recognizing)
                        Spacer()
                        Button {
                            guard let data = HandwritingImage.png(drawing) else { return }
                            recognizing = true
                            Task {
                                do {
                                    let value = try await HandwritingTextReader.shared.recognize(data)
                                        .split(whereSeparator: \.isNewline).joined(separator: " ")
                                    if !value.isEmpty { title = value }
                                } catch { self.error = error.localizedDescription }
                                recognizing = false
                            }
                        } label: { Label(recognizing ? "Reading…" : "Use handwriting", systemImage: "text.viewfinder") }
                        .disabled(drawing.strokes.isEmpty || recognizing).frame(minHeight: 44)
                    }
                }
                if let error { Text(error).foregroundStyle(.red).font(.callout) }
                Spacer(minLength: 0)
            }.padding(20).background(Modernist.paper)
                .navigationTitle(request.pageID == nil ? "Rename note" : "Rename page")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save", action: save).disabled(recognizing || request.pageID == nil && title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityIdentifier("rename.save")
                    }
                }
                .onAppear { focused = true }
                .onDisappear { transcripts.setDrawing(false, owner: recognitionOwner, notebookID: request.notebookID, pageID: nil, store: store) }
        }.presentationDetents([.medium, .large])
    }

    private func save() {
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if let pageID = request.pageID { try store.renamePage(in: request.notebookID, pageId: pageID, title: value.isEmpty ? nil : value) }
            else { try store.renameNotebook(id: request.notebookID, title: value) }
            saved?(); dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

private struct TitleInkPad: UIViewRepresentable {
    @Binding var drawing: PKDrawing
    let contact: (Bool) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> PKCanvasView {
        let view = PKCanvasView()
        view.delegate = context.coordinator; view.drawingPolicy = .anyInput
        view.tool = PKInkingTool(.pen, color: .black, width: 4)
        view.isScrollEnabled = false; view.backgroundColor = .white
        return view
    }
    func updateUIView(_ view: PKCanvasView, context: Context) {
        context.coordinator.parent = self
        if view.drawing != drawing { view.drawing = drawing }
    }
    final class Coordinator: NSObject, PKCanvasViewDelegate {
        var parent: TitleInkPad
        init(_ parent: TitleInkPad) { self.parent = parent }
        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) { parent.drawing = canvasView.drawing }
        func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) { parent.contact(true) }
        func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) { parent.contact(false) }
    }
}
