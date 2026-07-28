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
            "animationDuration": 0.16,
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
}
