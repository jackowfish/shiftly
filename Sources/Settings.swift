import AppKit
import Carbon.HIToolbox

final class Settings {
    static let shared = Settings()
    private let defaults = UserDefaults.standard

    init() {
        defaults.register(defaults: [
            Layer.halves.settingsKey: cmdKey,
            Layer.thirds.settingsKey: cmdKey | optionKey,
            Layer.displays.settingsKey: cmdKey | shiftKey,
            "overlayEnabled": true,
            "overlayColor": "accent",
            "animationDuration": 0.08,
            "gazeEnabled": false,
            "gazeCameraAlwaysOn": true,
            "debugLogging": false,
        ])
    }

    func modifiers(for layer: Layer) -> UInt32 {
        UInt32(defaults.integer(forKey: layer.settingsKey))
    }

    func setModifiers(_ mods: UInt32, for layer: Layer) {
        defaults.set(Int(mods), forKey: layer.settingsKey)
    }

    var overlayEnabled: Bool {
        get { defaults.bool(forKey: "overlayEnabled") }
        set { defaults.set(newValue, forKey: "overlayEnabled") }
    }

    var overlayColorName: String {
        get { defaults.string(forKey: "overlayColor") ?? "accent" }
        set { defaults.set(newValue, forKey: "overlayColor") }
    }

    var overlayColor: NSColor {
        overlayColors.first { $0.name == overlayColorName }?.color ?? .controlAccentColor
    }

    var animationDuration: Double {
        get { defaults.double(forKey: "animationDuration") }
        set { defaults.set(newValue, forKey: "animationDuration") }
    }

    var debugLogging: Bool {
        get { defaults.bool(forKey: "debugLogging") }
        set { defaults.set(newValue, forKey: "debugLogging") }
    }

    // MARK: Gaze

    var gazeEnabled: Bool {
        get { defaults.bool(forKey: "gazeEnabled") }
        set { defaults.set(newValue, forKey: "gazeEnabled") }
    }

    var gazeCameraAlwaysOn: Bool {
        get { defaults.bool(forKey: "gazeCameraAlwaysOn") }
        set { defaults.set(newValue, forKey: "gazeCameraAlwaysOn") }
    }

    var gazeDebugOverlay: Bool {
        get { defaults.bool(forKey: "gazeDebugOverlay") }
        set { defaults.set(newValue, forKey: "gazeDebugOverlay") }
    }

    /// Nil until calibrated. There's no fallback: without labelled readings
    /// there's nothing to compare against, and guessing was what made the old
    /// version need a Flip Horizontal control.
    var gazeProfile: GazeProfile? {
        get { GazeProfile(storage: defaults.array(forKey: "gazeProfile") as? [[Double]] ?? []) }
        set { defaults.set(newValue?.storage, forKey: "gazeProfile") }
    }

    /// Display arrangement the calibration was fitted against. A mismatch
    /// doesn't invalidate it, but the menu says so, because a map fitted on one
    /// monitor will send windows to strange places on three.
    var gazeCalibrationArrangement: String? {
        get { defaults.string(forKey: "gazeCalibrationArrangement") }
        set { defaults.set(newValue, forKey: "gazeCalibrationArrangement") }
    }

    var isGazeCalibrated: Bool { gazeProfile != nil }

    func clearGazeCalibration() {
        defaults.removeObject(forKey: "gazeProfile")
        defaults.removeObject(forKey: "gazeCalibrationArrangement")
    }
}
