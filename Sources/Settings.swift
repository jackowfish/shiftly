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
            gazeSettingsKey: controlKey | cmdKey,
            "gazeEnabled": false,
            "gazeColumns": 3,
            "gazeRows": 2,
            "gazeInvertX": false,
            "gazeInvertY": false,
            "gazeKeepCameraWarm": false,
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

    // MARK: Gaze

    var gazeEnabled: Bool {
        get { defaults.bool(forKey: "gazeEnabled") }
        set { defaults.set(newValue, forKey: "gazeEnabled") }
    }

    var gazeModifiers: UInt32 {
        get { UInt32(defaults.integer(forKey: gazeSettingsKey)) }
        set { defaults.set(Int(newValue), forKey: gazeSettingsKey) }
    }

    var gazeColumns: Int {
        get { max(1, defaults.integer(forKey: "gazeColumns")) }
        set { defaults.set(newValue, forKey: "gazeColumns") }
    }

    var gazeRows: Int {
        get { max(1, defaults.integer(forKey: "gazeRows")) }
        set { defaults.set(newValue, forKey: "gazeRows") }
    }

    var gazeInvertX: Bool {
        get { defaults.bool(forKey: "gazeInvertX") }
        set { defaults.set(newValue, forKey: "gazeInvertX") }
    }

    var gazeInvertY: Bool {
        get { defaults.bool(forKey: "gazeInvertY") }
        set { defaults.set(newValue, forKey: "gazeInvertY") }
    }

    var gazeKeepCameraWarm: Bool {
        get { defaults.bool(forKey: "gazeKeepCameraWarm") }
        set { defaults.set(newValue, forKey: "gazeKeepCameraWarm") }
    }

    /// Nil until the user calibrates, which is what the fallback maps are for.
    var gazeHeadMap: GazeMap? {
        get { GazeMap(storage: defaults.array(forKey: "gazeHeadMap") as? [Double] ?? []) }
        set { defaults.set(newValue?.storage, forKey: "gazeHeadMap") }
    }

    var gazeFineMap: GazeMap? {
        get { GazeMap(storage: defaults.array(forKey: "gazeFineMap") as? [Double] ?? []) }
        set { defaults.set(newValue?.storage, forKey: "gazeFineMap") }
    }

    /// Display arrangement the calibration was fitted against. A mismatch
    /// doesn't invalidate it, but the menu says so, because a map fitted on one
    /// monitor will send windows to strange places on three.
    var gazeCalibrationArrangement: String? {
        get { defaults.string(forKey: "gazeCalibrationArrangement") }
        set { defaults.set(newValue, forKey: "gazeCalibrationArrangement") }
    }

    var isGazeCalibrated: Bool { gazeHeadMap != nil && gazeFineMap != nil }

    func clearGazeCalibration() {
        defaults.removeObject(forKey: "gazeHeadMap")
        defaults.removeObject(forKey: "gazeFineMap")
        defaults.removeObject(forKey: "gazeCalibrationArrangement")
    }
}
