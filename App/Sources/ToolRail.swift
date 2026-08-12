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
        case pen, fountain, pencil, marker, eraser, lasso

        var id: String { rawValue }

        var label: String {
            switch self {
            case .pen: "Pen"
            case .fountain: "Fountain pen"
            case .pencil: "Pencil"
            case .marker: "Highlighter"
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
            case .marker: "highlighter"
            case .eraser: "eraser"
            case .lasso: "lasso"
            }
        }

        /// Whether the ink swatches apply. The eraser and the lasso have no colour.
        var takesInk: Bool {
            switch self {
            case .pen, .fountain, .pencil, .marker: true
            case .eraser, .lasso: false
            }
        }

        /// The nib this tool writes with at [Width.medium]; the other two scale from it.
        ///
        /// Per tool because they are different implements: a highlighter that came out the width
        /// of a pen would not highlight anything.
        var baseWidth: CGFloat {
            switch self {
            case .pen: 5
            case .fountain: 6
            case .pencil: 4
            case .marker: 24
            case .eraser, .lasso: 0
            }
        }
    }

    /// How broad the nib is.
    ///
    /// Three steps rather than a slider: on e-ink a slider is a drag that redraws the screen, and
    /// on glass three named widths are what people actually reach for. The rail offered one fixed
    /// width per tool and nothing else, so writing small was impossible.
    enum Width: String, CaseIterable, Identifiable {
        case fine, medium, broad

        var id: String { rawValue }

        var label: String {
            switch self {
            case .fine: "Fine"
            case .medium: "Medium"
            case .broad: "Broad"
            }
        }

        /// Applied to the tool's own [Kind.baseWidth], so each implement keeps its character.
        var scale: CGFloat {
            switch self {
            case .fine: 0.5
            case .medium: 1
            case .broad: 2
            }
        }

        /// The dot the rail draws for it, in points.
        var dotSize: CGFloat {
            switch self {
            case .fine: 6
            case .medium: 11
            case .broad: 17
            }
        }
    }

    /// How the eraser works.
    ///
    /// Notable has had both since it had an eraser: rubbing out part of a stroke and taking the
    /// whole stroke away are different intentions, and a single mode makes one of them impossible.
    enum EraserMode: String, CaseIterable, Identifiable {
        case pixel, stroke

        var id: String { rawValue }

        var label: String {
            switch self {
            case .pixel: "Rub out"
            case .stroke: "Whole strokes"
            }
        }

        var pkEraser: PKEraserTool {
            switch self {
            case .pixel: PKEraserTool(.bitmap)
            case .stroke: PKEraserTool(.vector)
            }
        }
    }

    @Published private(set) var kind: Kind = .pen
    @Published private(set) var inkIndex = 0
    @Published private(set) var revision = 0

    /// The chosen width per tool, so switching from a broad marker back to the pen returns to the
    /// pen you were writing with rather than to a pen as broad as the marker.
    @Published private(set) var widths: [Kind: Width] = [:]
    @Published private(set) var eraserMode: EraserMode = .pixel

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        for kind in Kind.allCases {
            if let raw = defaults.string(forKey: Self.widthKey(kind)),
               let width = Width(rawValue: raw) {
                widths[kind] = width
            }
        }
        if let raw = defaults.string(forKey: Self.eraserKey),
           let mode = EraserMode(rawValue: raw) {
            eraserMode = mode
        }
    }

    private static func widthKey(_ kind: Kind) -> String { "editor.width.\(kind.rawValue)" }
    private static let eraserKey = "editor.eraserMode"

    var ink: Modernist.Ink { Modernist.inks[min(inkIndex, Modernist.inks.count - 1)] }

    /// The width the current tool writes at.
    var width: Width { widths[kind] ?? .medium }

    func select(_ kind: Kind) {
        self.kind = kind
        revision += 1
    }

    /// Sets the width of whichever tool is selected. A no-op for the eraser and the lasso, which
    /// have no nib — reaching for a width while erasing means nothing rather than something odd.
    func select(width: Width) {
        guard kind.takesInk else { return }
        widths[kind] = width
        defaults.set(width.rawValue, forKey: Self.widthKey(kind))
        revision += 1
    }

    func select(eraserMode mode: EraserMode) {
        eraserMode = mode
        defaults.set(mode.rawValue, forKey: Self.eraserKey)
        // Choosing how to erase means "erase", the same way choosing an ink means "write".
        kind = .eraser
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
            case .marker: kind = .marker
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
        let nib = kind.baseWidth * width.scale
        switch kind {
        case .pen: return PKInkingTool(.pen, color: ink.uiColor, width: nib)
        case .fountain: return PKInkingTool(.fountainPen, color: ink.uiColor, width: nib)
        case .pencil: return PKInkingTool(.pencil, color: ink.uiColor, width: nib)
        // The marker's own translucency is what makes it a highlighter rather than a fat pen;
        // PencilKit applies it from the ink type, so the colour is passed at full strength.
        case .marker: return PKInkingTool(.marker, color: ink.uiColor, width: nib)
        case .eraser: return eraserMode.pkEraser
        case .lasso: return PKLassoTool()
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
                    widthPicker
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
                    widthPicker
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

    /// Three widths, as the dots they draw.
    ///
    /// Shown as sizes rather than named, because the thing being chosen is a size — and while the
    /// eraser is selected it becomes the eraser's two modes instead, which is the choice that
    /// actually applies then. The rail used to offer one fixed width per tool and no way to erase
    /// a whole stroke.
    @ViewBuilder
    private var widthPicker: some View {
        let layout = vertical
            ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
        layout {
            if selection.kind == .eraser {
                ForEach(ToolSelection.EraserMode.allCases) { mode in
                    Button {
                        selection.select(eraserMode: mode)
                    } label: {
                        Image(systemName: mode == .pixel ? "eraser.line.dashed" : "scribble")
                            .font(.system(size: 17, weight: .medium))
                    }
                    .buttonStyle(
                        RailButtonStyle(selected: selection.eraserMode == mode, size: hit))
                    .accessibilityLabel(mode.label)
                    .accessibilityIdentifier("editor.eraserMode.\(mode.rawValue)")
                }
            } else {
                ForEach(ToolSelection.Width.allCases) { width in
                    Button {
                        selection.select(width: width)
                    } label: {
                        Circle()
                            .fill(Modernist.ink)
                            .frame(width: width.dotSize, height: width.dotSize)
                    }
                    .buttonStyle(RailButtonStyle(selected: selection.width == width, size: hit))
                    .disabled(!selection.kind.takesInk)
                    .accessibilityLabel(width.label)
                    .accessibilityIdentifier("editor.width.\(width.rawValue)")
                }
            }
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
