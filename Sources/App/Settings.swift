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

    /// Nil until calibrated. There is no fallback: without labelled readings
    /// there is nothing to compare against, and guessing was what made the old
    /// version need a Flip Horizontal control.
    ///
    /// Cached after the first load. Construction parses the stored rows and
    /// refits every placement, including the cross-session model comparison,
    /// and this getter runs at overlay redraw rate.
    var gazeProfile: GazeProfile? {
        get {
            if !profileLoaded {
                cachedProfile = GazeProfile(
                    storage: defaults.array(forKey: "gazeProfile") as? [[Double]] ?? [],
                    noise: gazeNoise)
                profileLoaded = true
            }
            return cachedProfile
        }
        set {
            defaults.set(newValue?.storage, forKey: "gazeProfile")
            cachedProfile = newValue
            profileLoaded = true
        }
    }

    private var cachedProfile: GazeProfile?
    private var profileLoaded = false

    /// Per-axis measurement jitter from the last calibration. Nil for profiles
    /// saved before it was measured, which fall back to the older scaling.
    var gazeNoise: GazeSample? {
        get {
            guard let row = defaults.array(forKey: "gazeNoise") as? [Double],
                  row.count == GazeSample.axes.count
            else { return nil }
            var sample = GazeSample()
            for (index, axis) in GazeSample.axes.enumerated() { sample[keyPath: axis] = row[index] }
            return sample
        }
        set {
            defaults.set(newValue.map { sample in GazeSample.axes.map { sample[keyPath: $0] } },
                         forKey: "gazeNoise")
            // This scales the profile's weights, so a cached profile is
            // stale the moment it changes.
            profileLoaded = false
        }
    }

    /// Display arrangement the calibration was fitted against. A mismatch
    /// does not invalidate it, but the menu says so, because a map fitted on one
    /// monitor will send windows to strange places on three.
    var gazeCalibrationArrangement: String? {
        get { defaults.string(forKey: "gazeCalibrationArrangement") }
        set { defaults.set(newValue, forKey: "gazeCalibrationArrangement") }
    }

    var isGazeCalibrated: Bool { gazeProfile != nil }

    /// A calibration is saved but cannot be read, because it was recorded by a
    /// version whose readings meant something else. Worth telling apart from
    /// never having calibrated: the feature going quiet after an update is
    /// otherwise indistinguishable from it being broken.
    var hasStaleGazeCalibration: Bool {
        defaults.array(forKey: "gazeProfile") != nil && gazeProfile == nil
    }

    func clearGazeCalibration() {
        defaults.removeObject(forKey: "gazeProfile")
        defaults.removeObject(forKey: "gazeNoise")
        defaults.removeObject(forKey: "gazeCalibrationArrangement")
        cachedProfile = nil
        profileLoaded = false
    }
}
