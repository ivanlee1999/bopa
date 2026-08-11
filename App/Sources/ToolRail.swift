import PencilKit
import SwiftUI

/// Which drawing tool and ink the rail has selected, and the PencilKit tool that means.
///
/// The rail is the source of truth. `revision` is bumped only by a rail tap, so the canvas
/// can tell "the user picked something" apart from "we mirrored what PencilKit already
/// did" and never applies a tool back onto the canvas that came from the canvas.
@MainActor
final class ToolSelection: ObservableObject {
    enum Kind: String, CaseIterable, Identifiable {
        case pen, fountain, pencil, eraser, lasso

        var id: String { rawValue }

        var label: String {
            switch self {
            case .pen: "Pen"
            case .fountain: "Fountain pen"
            case .pencil: "Pencil"
            case .eraser: "Eraser"
            case .lasso: "Select"
            }
        }

        /// SF Symbols stand in for the design's Lucide set — same silhouettes at
        /// interface size, and no font to bundle.
        var symbolName: String {
            switch self {
            case .pen: "pencil.tip"
            case .fountain: "paintbrush.pointed"
            case .pencil: "pencil"
            case .eraser: "eraser"
            case .lasso: "lasso"
            }
        }

        /// Whether the ink swatches apply. The eraser and the lasso have no colour.
        var takesInk: Bool {
            switch self {
            case .pen, .fountain, .pencil: true
            case .eraser, .lasso: false
            }
        }

        var width: CGFloat {
            switch self {
            case .pen: 5
            case .fountain: 6
            case .pencil: 4
            case .eraser, .lasso: 0
            }
        }
    }

    @Published private(set) var kind: Kind = .pen
    @Published private(set) var inkIndex = 0
    @Published private(set) var revision = 0

    var ink: Modernist.Ink { Modernist.inks[min(inkIndex, Modernist.inks.count - 1)] }

    func select(_ kind: Kind) {
        self.kind = kind
        revision += 1
    }

    func select(inkIndex: Int) {
        guard Modernist.inks.indices.contains(inkIndex) else { return }
        self.inkIndex = inkIndex
        // Picking an ink while erasing or selecting means "go back to writing with it".
        if !kind.takesInk { kind = .pen }
        revision += 1
    }

    /// Mirrors a tool chosen elsewhere (an Apple Pencil gesture) onto the rail without
    /// asking for it to be applied back.
    func adopt(_ tool: PKTool) {
        if let inking = tool as? PKInkingTool {
            switch inking.inkType {
            case .pen: kind = .pen
            case .fountainPen: kind = .fountain
            case .pencil: kind = .pencil
            default: break
            }
            if let index = Modernist.inkIndex(matching: inking.color) { inkIndex = index }
        } else if tool is PKEraserTool {
            kind = .eraser
        } else if tool is PKLassoTool {
            kind = .lasso
        }
    }

    var pkTool: PKTool {
        switch kind {
        case .pen: PKInkingTool(.pen, color: ink.uiColor, width: kind.width)
        case .fountain: PKInkingTool(.fountainPen, color: ink.uiColor, width: kind.width)
        case .pencil: PKInkingTool(.pencil, color: ink.uiColor, width: kind.width)
        case .eraser: PKEraserTool(.bitmap)
        case .lasso: PKLassoTool()
        }
    }
}

/// The docked tool rail: left edge on a regular-width screen, bottom bar when compact.
///
/// Docked, never floating and never dragged. The design's constraint is an e-ink one — a
/// moving overlay costs a full-screen refresh — but a rail that stays put is the better
/// bargain on glass too: it is always in the same place under your hand.
struct ToolRail: View {
    @ObservedObject var selection: ToolSelection
    @ObservedObject var undo: CanvasUndoController
    /// `false` lays the rail out along the bottom, the one-handed variant.
    var vertical = true

    private var hit: CGFloat { vertical ? Modernist.hit : Modernist.hitCompact }

    var body: some View {
        Group {
            if vertical {
                VStack(spacing: 0) {
                    tools
                    ModernistRule()
                        .frame(width: hit)
                    history
                    Spacer(minLength: 0)
                    swatches
                }
                .padding(.vertical, 6)
                .frame(width: 60)
                .frame(maxHeight: .infinity)
                .overlay(alignment: .trailing) {
                    Rectangle()
                        .fill(Modernist.ink)
                        .frame(width: Modernist.ruleHeavy)
                }
            } else {
                HStack(spacing: 0) {
                    tools
                    history
                    Spacer(minLength: 0)
                    inkMenu
                }
                .padding(.horizontal, 4)
                .frame(height: 60)
                .frame(maxWidth: .infinity)
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(Modernist.ink)
                        .frame(height: Modernist.ruleHeavy)
                }
            }
        }
        .background(Modernist.rail)
    }

    // MARK: Groups

    @ViewBuilder
    private var tools: some View {
        let layout = vertical
            ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
        layout {
            ForEach(ToolSelection.Kind.allCases) { kind in
                Button {
                    selection.select(kind)
                } label: {
                    Image(systemName: kind.symbolName)
                        .font(.system(size: 20, weight: .medium))
                }
                .buttonStyle(RailButtonStyle(selected: selection.kind == kind, size: hit))
                .accessibilityLabel(kind.label)
                .accessibilityIdentifier("editor.tool.\(kind.rawValue)")
            }
        }
    }

    @ViewBuilder
    private var history: some View {
        let layout = vertical
            ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
        layout {
            Button {
                undo.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 19, weight: .medium))
            }
            .buttonStyle(RailButtonStyle(selected: false, size: hit))
            .disabled(!undo.canUndo)
            .accessibilityLabel("Undo")
            .accessibilityIdentifier("editor.undo")

            Button {
                undo.redo()
            } label: {
                Image(systemName: "arrow.uturn.forward")
                    .font(.system(size: 19, weight: .medium))
            }
            .buttonStyle(RailButtonStyle(selected: false, size: hit))
            .disabled(!undo.canRedo)
            .accessibilityLabel("Redo")
            .accessibilityIdentifier("editor.redo")
        }
    }

    /// The four inks, always visible when there is room for them. A ring rather than a
    /// fill marks the current one — the swatch itself has to stay pure colour.
    private var swatches: some View {
        VStack(spacing: 4) {
            ForEach(Modernist.inks) { ink in
                Button {
                    selection.select(inkIndex: ink.id)
                } label: {
                    Rectangle()
                        .fill(ink.color)
                        .frame(width: 30, height: 30)
                        .overlay(Rectangle().stroke(Modernist.neutral600, lineWidth: 1))
                        .padding(3)
                        .overlay {
                            if selection.inkIndex == ink.id {
                                Rectangle().stroke(Modernist.ink, lineWidth: 2)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(ink.name)
                .accessibilityIdentifier("editor.ink.\(ink.id)")
            }
        }
        .padding(.bottom, 2)
    }

    /// Compact stand-in for the swatch column: the current ink, opening the rest.
    private var inkMenu: some View {
        Menu {
            ForEach(Modernist.inks) { ink in
                Button {
                    selection.select(inkIndex: ink.id)
                } label: {
                    Label(ink.name, systemImage: selection.inkIndex == ink.id ? "checkmark" : "square.fill")
                }
            }
        } label: {
            Rectangle()
                .fill(selection.ink.color)
                .frame(width: 26, height: 26)
                .overlay(Rectangle().stroke(Modernist.neutral600, lineWidth: 1))
                .frame(width: hit, height: hit)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Ink")
        .accessibilityIdentifier("editor.ink")
    }
}

/// A rail cell: square, edge-to-edge, ink fill when selected. No radius, no hover.
struct RailButtonStyle: ButtonStyle {
    var selected: Bool
    var size: CGFloat
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: size, height: size)
            .foregroundStyle(foreground)
            .background(selected ? Modernist.ink : (configuration.isPressed ? Modernist.neutral300 : .clear))
            .contentShape(Rectangle())
    }

    private var foreground: Color {
        if !isEnabled { return Modernist.neutral400 }
        return selected ? Modernist.paper : Modernist.ink
    }
}
