import AppKit
import ApplicationServices

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = menuBarIcon()
        item.button?.toolTip = "Shiftly"
        item.menu = buildMenu()
        statusItem = item

        let trusted = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        log("launched, accessibility trusted: \(trusted)")

        installHotKeys()
    }

    /// Squircle shift keycap, template-tinted for the menu bar.
    private func menuBarIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let keycap = NSBezierPath(roundedRect: rect.insetBy(dx: 1.25, dy: 1.25),
                                      xRadius: 5, yRadius: 5)
            keycap.lineWidth = 1.5
            NSColor.black.setStroke()
            keycap.stroke()

            let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .heavy)
            if let shift = NSImage(systemSymbolName: "shift", accessibilityDescription: "Shiftly")?
                .withSymbolConfiguration(config) {
                let glyph = shift.size
                shift.draw(in: NSRect(x: (rect.width - glyph.width) / 2,
                                      y: (rect.height - glyph.height) / 2,
                                      width: glyph.width,
                                      height: glyph.height))
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    // MARK: Menu

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Hold the modifier, tap arrows, release to place", action: nil, keyEquivalent: "")
        menu.addItem(.separator())

        let modifiersItem = menu.addItem(withTitle: "Modifiers", action: nil, keyEquivalent: "")
        let modifiersMenu = NSMenu()
        for layer in Layer.allCases {
            let layerItem = modifiersMenu.addItem(withTitle: layer.menuTitle, action: nil, keyEquivalent: "")
            let layerMenu = NSMenu()
            let current = Settings.shared.modifiers(for: layer)
            for choice in modifierChoices {
                let choiceItem = layerMenu.addItem(withTitle: "\(choice.title) + arrows",
                                                   action: #selector(pickModifier(_:)),
                                                   keyEquivalent: "")
                choiceItem.target = self
                choiceItem.state = choice.mods == current ? .on : .off
                choiceItem.representedObject = ["layer": layer.settingsKey, "mods": Int(choice.mods)]
            }
            layerItem.submenu = layerMenu
        }
        modifiersItem.submenu = modifiersMenu

        let placementItem = menu.addItem(withTitle: "Placement Window", action: nil, keyEquivalent: "")
        let placementMenu = NSMenu()
        let offItem = placementMenu.addItem(withTitle: "Off (move windows live)",
                                            action: #selector(toggleOverlay(_:)),
                                            keyEquivalent: "")
        offItem.target = self
        offItem.state = Settings.shared.overlayEnabled ? .off : .on
        placementMenu.addItem(.separator())
        for choice in overlayColors {
            let colorItem = placementMenu.addItem(withTitle: choice.title,
                                                  action: #selector(pickColor(_:)),
                                                  keyEquivalent: "")
            colorItem.target = self
            colorItem.state = Settings.shared.overlayEnabled
                && Settings.shared.overlayColorName == choice.name ? .on : .off
            colorItem.representedObject = choice.name

            let swatch = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
                choice.color.setFill()
                NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
                return true
            }
            colorItem.image = swatch
        }
        placementItem.submenu = placementMenu

        let animationItem = menu.addItem(withTitle: "Animation", action: nil, keyEquivalent: "")
        let animationMenu = NSMenu()
        for choice in animationChoices {
            let speedItem = animationMenu.addItem(withTitle: choice.title,
                                                  action: #selector(pickAnimation(_:)),
                                                  keyEquivalent: "")
            speedItem.target = self
            speedItem.state = abs(Settings.shared.animationDuration - choice.duration) < 0.001 ? .on : .off
            speedItem.representedObject = choice.duration
        }
        animationItem.submenu = animationMenu

        menu.addItem(.separator())
        let logItem = menu.addItem(withTitle: "Open Log", action: #selector(openLog), keyEquivalent: "")
        logItem.target = self
        let settingsItem = menu.addItem(withTitle: "Accessibility Settings",
                                        action: #selector(openAccessibilitySettings),
                                        keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Shiftly", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    private func refreshMenu() {
        statusItem?.menu = buildMenu()
    }

    @objc private func pickModifier(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: Any],
              let key = info["layer"] as? String,
              let mods = info["mods"] as? Int,
              let layer = Layer.allCases.first(where: { $0.settingsKey == key })
        else { return }

        // Swap with any layer that already owns the chosen combo.
        let chosen = UInt32(mods)
        let previous = Settings.shared.modifiers(for: layer)
        for other in Layer.allCases where other != layer && Settings.shared.modifiers(for: other) == chosen {
            Settings.shared.setModifiers(previous, for: other)
        }
        Settings.shared.setModifiers(chosen, for: layer)

        installHotKeys()
        refreshMenu()
    }

    @objc private func pickAnimation(_ sender: NSMenuItem) {
        guard let duration = sender.representedObject as? Double else { return }
        Settings.shared.animationDuration = duration
        refreshMenu()
    }

    @objc private func toggleOverlay(_ sender: NSMenuItem) {
        Settings.shared.overlayEnabled.toggle()
        refreshMenu()
    }

    @objc private func pickColor(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        Settings.shared.overlayColorName = name
        Settings.shared.overlayEnabled = true
        refreshMenu()
    }

    @objc private func openLog() {
        NSWorkspace.shared.open(logURL)
    }

    @objc private func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        else { return }
        NSWorkspace.shared.open(url)
    }
}
