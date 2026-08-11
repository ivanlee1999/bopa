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

    var label: String {
        switch self {
        case .system: "System setting"
        case .ignore: "Do nothing"
        case .eraser: "Switch between eraser and pen"
        case .previousTool: "Switch to previous tool"
        case .undo: "Undo"
        }
    }
}

/// How much of the page is shown when a page opens.
enum ZoomOnOpen: String, CaseIterable, Identifiable, Sendable {
    case fitWidth
    case actualSize

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fitWidth: "Fit width"
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
    var zoomOnOpen: ZoomOnOpen = .fitWidth
    var doubleTapAction: PencilAction = .system
    var squeezeAction: PencilAction = .system
    /// Paper for newly created notebooks and pages. Existing pages keep the template
    /// stored in their page file (which is what the BOOX also reads).
    var defaultTemplate: NativeTemplate = .blank

    enum Key {
        static let fingerDrawing = "handwriting.fingerDrawing"
        static let scrollLocked = "handwriting.scrollLocked"
        static let zoomOnOpen = "handwriting.zoomOnOpen"
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
        if let raw = defaults.string(forKey: Key.zoomOnOpen), let value = ZoomOnOpen(rawValue: raw) {
            config.zoomOnOpen = value
        }
        if let raw = defaults.string(forKey: Key.doubleTapAction),
           let value = PencilAction(rawValue: raw) {
            config.doubleTapAction = value
        }
        if let raw = defaults.string(forKey: Key.squeezeAction),
           let value = PencilAction(rawValue: raw) {
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
        defaults.set(zoomOnOpen.rawValue, forKey: Key.zoomOnOpen)
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
            Picker("Open pages at", selection: config.zoomOnOpen) {
                ForEach(ZoomOnOpen.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
        } header: {
            Text("Canvas")
        } footer: {
            if config.scrollLocked.wrappedValue && !config.fingerDrawing.wrappedValue {
                Text("With scrolling locked and finger drawing off, the page cannot be moved.")
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
