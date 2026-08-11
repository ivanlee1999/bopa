import Foundation
import NotableKit
import SwiftUI

/// SF Symbol for each of NotableKit's built-in native templates, for the paper picker.
extension NativeTemplate {
    var symbolName: String {
        switch self {
        case .blank: "rectangle"
        case .lined: "list.bullet.rectangle"
        case .dotted: "circle.grid.3x3"
        case .squared: "grid"
        case .hexed: "hexagon"
        case .custom: "questionmark.square.dashed"
        }
    }
}

/// What an Apple Pencil gesture (double-tap, or squeeze on Pencil Pro) does.
enum PencilAction: String, CaseIterable, Identifiable, Sendable {
    /// Leave the gesture to PencilKit / the system-wide Settings › Apple Pencil preference.
    case system
    case ignore
    case eraser
    case previousTool
    case undo

    var id: String { rawValue }

    /// Reads a stored action, translating the ones earlier builds could write. A retired
    /// action becomes "do nothing" rather than falling through to the default: the user
    /// picked it precisely to take the gesture away from the system, and quietly handing
    /// it back would make the pencil start doing something they never asked for.
    static func stored(_ raw: String) -> PencilAction? {
        if let action = PencilAction(rawValue: raw) { return action }
        switch raw {
        // "Show/hide tool palette", retired with PencilKit's floating picker.
        case "toggleToolPicker": return .ignore
        default: return nil
        }
    }

    var label: String {
        switch self {
        case .system: "System setting"
        case .ignore: "Do nothing"
        // Not "…and pen": toggling out of the eraser goes back to whatever was in hand
        // before it, and only reaches for a pen when nothing else has been used yet.
        case .eraser: "Switch between current tool and eraser"
        case .previousTool: "Switch to previous tool"
        case .undo: "Undo"
        }
    }
}

/// How wide the page is drawn relative to the screen.
enum PageFit: String, CaseIterable, Identifiable, Sendable {
    /// Scale the page so its width exactly fills the screen, and keep it there through
    /// scrolling and rotation until a pinch takes it off the fit.
    case fitWidth
    /// Draw the page at 1:1 and leave the zoom entirely to the user.
    case actualSize

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fitWidth: "Fit to screen"
        case .actualSize: "Actual size"
        }
    }
}

/// The handwriting preferences as a plain value, so the canvas can diff them and the
/// persistence can be unit-tested without a live app.
struct HandwritingConfig: Equatable, Sendable {
    /// When false the canvas is pencil-only: a finger pans and zooms instead of inking,
    /// which is also what makes a resting palm harmless.
    var fingerDrawing = true
    /// Freezes panning/zooming so a stray drag cannot shift the page mid-sentence.
    var scrollLocked = false
    var pageFit: PageFit = .fitWidth
    var doubleTapAction: PencilAction = .system
    var squeezeAction: PencilAction = .system
    /// Paper for newly created notebooks and pages. Existing pages keep the template
    /// stored in their page file (which is what the BOOX also reads).
    var defaultTemplate: NativeTemplate = .blank

    enum Key {
        static let fingerDrawing = "handwriting.fingerDrawing"
        static let scrollLocked = "handwriting.scrollLocked"
        /// Keeps its original name: the setting grew from "zoom applied on open" into the
        /// sticky page fit, and renaming the key would silently reset everyone's choice.
        static let pageFit = "handwriting.zoomOnOpen"
        static let doubleTapAction = "handwriting.pencilDoubleTap"
        static let squeezeAction = "handwriting.pencilSqueeze"
        static let defaultTemplate = "handwriting.defaultTemplate"
    }

    static func load(from defaults: UserDefaults) -> HandwritingConfig {
        var config = HandwritingConfig()
        // `object(forKey:)` first: a missing key must keep the default, not read back false.
        if let value = defaults.object(forKey: Key.fingerDrawing) as? Bool {
            config.fingerDrawing = value
        }
        if let value = defaults.object(forKey: Key.scrollLocked) as? Bool {
            config.scrollLocked = value
        }
        if let raw = defaults.string(forKey: Key.pageFit), let value = PageFit(rawValue: raw) {
            config.pageFit = value
        }
        if let raw = defaults.string(forKey: Key.doubleTapAction),
           let value = PencilAction.stored(raw) {
            config.doubleTapAction = value
        }
        if let raw = defaults.string(forKey: Key.squeezeAction),
           let value = PencilAction.stored(raw) {
            config.squeezeAction = value
        }
        if let raw = defaults.string(forKey: Key.defaultTemplate) {
            let template = NativeTemplate(name: raw)
            // A stored `.custom` (from an older/newer build, or corrupt defaults) isn't
            // drawable here; fall back rather than surface an unpickable option.
            config.defaultTemplate = template.isDrawable ? template : .blank
        }
        return config
    }

    func save(to defaults: UserDefaults) {
        defaults.set(fingerDrawing, forKey: Key.fingerDrawing)
        defaults.set(scrollLocked, forKey: Key.scrollLocked)
        defaults.set(pageFit.rawValue, forKey: Key.pageFit)
        defaults.set(doubleTapAction.rawValue, forKey: Key.doubleTapAction)
        defaults.set(squeezeAction.rawValue, forKey: Key.squeezeAction)
        defaults.set(defaultTemplate.name, forKey: Key.defaultTemplate)
    }
}

/// App-wide handwriting preferences, injected as an environment object and read by the
/// editor canvas on every update.
@MainActor
final class HandwritingSettings: ObservableObject {
    @Published var config: HandwritingConfig {
        didSet {
            guard config != oldValue else { return }
            config.save(to: defaults)
        }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.config = HandwritingConfig.load(from: defaults)
    }
}

// MARK: - UI

/// Settings root: handwriting preferences, with sync tucked behind a link.
struct SettingsView: View {
    /// Passed down so the sync form can trigger syncs on whichever backend is selected.
    var backendHost: SyncBackendHost?

    var body: some View {
        Form {
            HandwritingSettingsSections()
            Section {
                NavigationLink {
                    SyncSettingsView(backendHost: backendHost)
                } label: {
                    Label("Sync", systemImage: "arrow.triangle.2.circlepath")
                }
            }
        }
        .navigationTitle("Settings")
    }
}

struct HandwritingSettingsSections: View {
    @EnvironmentObject private var settings: HandwritingSettings

    private var config: Binding<HandwritingConfig> { $settings.config }

    var body: some View {
        Section {
            Picker("Finger", selection: config.fingerDrawing) {
                Text("Draws").tag(true)
                Text("Scrolls only").tag(false)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("settings.fingerDrawing")
        } header: {
            Text("Input")
        } footer: {
            Text(config.fingerDrawing.wrappedValue
                ? "A finger inks like the pencil. Resting your palm on the screen can leave marks."
                : "Only the Apple Pencil inks — a finger pans and zooms, and a resting palm is ignored.")
        }

        Section {
            Picker("Double-tap", selection: config.doubleTapAction) {
                ForEach(PencilAction.allCases) { action in
                    Text(action.label).tag(action)
                }
            }
            Picker("Squeeze", selection: config.squeezeAction) {
                ForEach(PencilAction.allCases) { action in
                    Text(action.label).tag(action)
                }
            }
        } header: {
            Text("Apple Pencil")
        } footer: {
            Text("Squeeze needs an Apple Pencil Pro. “System setting” keeps whatever "
                + "Settings › Apple Pencil is set to.")
        }

        Section {
            Toggle("Lock page scrolling", isOn: config.scrollLocked)
            Picker("Page width", selection: config.pageFit) {
                ForEach(PageFit.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .accessibilityIdentifier("settings.pageFit")
        } header: {
            Text("Canvas")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text(config.pageFit.wrappedValue == .fitWidth
                    ? "The page is scaled so its width fills the screen, and stays that way "
                        + "as you scroll or rotate. Pinching leaves the fit; the editor's ••• "
                        + "menu puts you back on it."
                    : "The page is drawn at its true size — 1404pt wide, the same as on the BOOX.")
                if config.scrollLocked.wrappedValue && !config.fingerDrawing.wrappedValue {
                    Text("With scrolling locked and finger drawing off, the page cannot be moved.")
                }
            }
        }

        Section {
            Picker("Default paper", selection: config.defaultTemplate) {
                ForEach(NativeTemplate.builtIn, id: \.name) { template in
                    Label(template.displayName, systemImage: template.symbolName).tag(template)
                }
            }
            .accessibilityIdentifier("settings.defaultTemplate")
        } header: {
            Text("Paper")
        } footer: {
            Text("Applies to new notebooks and pages. Change an open page's paper from the "
                + "editor's ••• menu. Templates match Notable's, so they render the same on the BOOX.")
        }
    }
}
