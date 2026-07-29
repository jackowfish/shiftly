import AppKit
import ApplicationServices
import ServiceManagement

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
        GazeSession.shared.refresh()
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

        let gazeItem = menu.addItem(withTitle: "Eye Tracking", action: nil, keyEquivalent: "")
        gazeItem.submenu = buildGazeMenu()

        menu.addItem(.separator())
        let loginItem = menu.addItem(withTitle: "Start at Login",
                                     action: #selector(toggleLoginItem),
                                     keyEquivalent: "")
        loginItem.target = self
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        let updateItem = menu.addItem(withTitle: "Check for Updates…",
                                      action: #selector(checkForUpdates),
                                      keyEquivalent: "")
        updateItem.target = self
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

    private func buildGazeMenu() -> NSMenu {
        let settings = Settings.shared
        let menu = NSMenu()
        // Hand-managed so the flip items can stay greyed out once a calibration
        // supersedes them.
        menu.autoenablesItems = false

        let enableItem = menu.addItem(withTitle: "Enable Eye Tracking",
                                      action: #selector(toggleGaze),
                                      keyEquivalent: "")
        enableItem.target = self
        enableItem.state = settings.gazeEnabled ? .on : .off

        menu.addItem(.separator())
        let explainer = settings.gazeEnabled
            ? "Hold \(gazeChordTitle()), look at a zone, release to place"
            : "Off"
        menu.addItem(withTitle: explainer, action: nil, keyEquivalent: "").isEnabled = false

        let status: String
        if !settings.isGazeCalibrated {
            status = "Not calibrated (using rough defaults)"
        } else if settings.gazeCalibrationArrangement != screenArrangementFingerprint() {
            status = "Calibrated for a different display layout"
        } else {
            status = "Calibrated"
        }
        menu.addItem(withTitle: status, action: nil, keyEquivalent: "").isEnabled = false

        let calibrateItem = menu.addItem(withTitle: "Calibrate…",
                                         action: #selector(calibrateGaze),
                                         keyEquivalent: "")
        calibrateItem.target = self
        if settings.isGazeCalibrated {
            let resetItem = menu.addItem(withTitle: "Reset Calibration",
                                         action: #selector(resetGazeCalibration),
                                         keyEquivalent: "")
            resetItem.target = self
        }

        menu.addItem(.separator())
        let chordItem = menu.addItem(withTitle: "Chord", action: nil, keyEquivalent: "")
        let chordMenu = NSMenu()
        for choice in gazeModifierChoices {
            let item = chordMenu.addItem(withTitle: choice.title,
                                         action: #selector(pickGazeModifier(_:)),
                                         keyEquivalent: "")
            item.target = self
            item.state = choice.mods == settings.gazeModifiers ? .on : .off
            item.representedObject = Int(choice.mods)
        }
        chordItem.submenu = chordMenu

        let gridItem = menu.addItem(withTitle: "Zones", action: nil, keyEquivalent: "")
        let gridMenu = NSMenu()
        for choice in gazeGridChoices {
            let item = gridMenu.addItem(withTitle: choice.title,
                                        action: #selector(pickGazeGrid(_:)),
                                        keyEquivalent: "")
            item.target = self
            item.state = choice.columns == settings.gazeColumns && choice.rows == settings.gazeRows ? .on : .off
            item.representedObject = [choice.columns, choice.rows]
        }
        gridItem.submenu = gridMenu

        menu.addItem(.separator())
        // Calibration works out the signs by itself, so these are only live
        // while running on the guessed defaults.
        let calibrated = settings.isGazeCalibrated
        let flipXItem = menu.addItem(withTitle: calibrated ? "Flip Horizontal (set by calibration)" : "Flip Horizontal",
                                     action: #selector(toggleGazeFlipX),
                                     keyEquivalent: "")
        flipXItem.target = self
        flipXItem.state = !calibrated && settings.gazeInvertX ? .on : .off
        flipXItem.isEnabled = !calibrated

        let flipYItem = menu.addItem(withTitle: calibrated ? "Flip Vertical (set by calibration)" : "Flip Vertical",
                                     action: #selector(toggleGazeFlipY),
                                     keyEquivalent: "")
        flipYItem.target = self
        flipYItem.state = !calibrated && settings.gazeInvertY ? .on : .off
        flipYItem.isEnabled = !calibrated

        let warmItem = menu.addItem(withTitle: "Keep Camera Warm (faster, light stays on)",
                                    action: #selector(toggleGazeWarmCamera),
                                    keyEquivalent: "")
        warmItem.target = self
        warmItem.state = settings.gazeKeepCameraWarm ? .on : .off

        return menu
    }

    private func gazeChordTitle() -> String {
        let mods = Settings.shared.gazeModifiers
        return gazeModifierChoices.first { $0.mods == mods }?.title ?? "the chord"
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
        moveGazeChordOff(chosen)

        installHotKeys()
        GazeSession.shared.refresh()
        refreshMenu()
    }

    // MARK: Gaze

    /// The gaze chord arms on the modifiers alone, so sharing a combo with a
    /// layer would arm it every time that layer is used. Push it somewhere free.
    private func moveGazeChordOff(_ chord: UInt32) {
        guard Settings.shared.gazeModifiers == chord else { return }
        let taken = Layer.allCases.map { Settings.shared.modifiers(for: $0) }
        if let free = gazeModifierChoices.first(where: { !taken.contains($0.mods) }) {
            Settings.shared.gazeModifiers = free.mods
        }
    }

    private func moveLayersOff(_ chord: UInt32) {
        for layer in Layer.allCases where Settings.shared.modifiers(for: layer) == chord {
            let taken = Layer.allCases.filter { $0 != layer }.map { Settings.shared.modifiers(for: $0) }
            if let free = modifierChoices.first(where: { $0.mods != chord && !taken.contains($0.mods) }) {
                Settings.shared.setModifiers(free.mods, for: layer)
            }
        }
    }

    @objc private func toggleGaze() {
        if Settings.shared.gazeEnabled {
            Settings.shared.gazeEnabled = false
            GazeSession.shared.refresh()
            refreshMenu()
            return
        }

        GazeTracker.requestAccess { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.showCameraDeniedAlert()
                return
            }
            Settings.shared.gazeEnabled = true
            self.moveGazeChordOff(Settings.shared.gazeModifiers)
            GazeSession.shared.refresh()
            self.refreshMenu()
            if !Settings.shared.isGazeCalibrated { self.offerCalibration() }
        }
    }

    @objc private func pickGazeModifier(_ sender: NSMenuItem) {
        guard let mods = sender.representedObject as? Int else { return }
        let chosen = UInt32(mods)
        Settings.shared.gazeModifiers = chosen
        moveLayersOff(chosen)
        installHotKeys()
        GazeSession.shared.refresh()
        refreshMenu()
    }

    @objc private func pickGazeGrid(_ sender: NSMenuItem) {
        guard let grid = sender.representedObject as? [Int], grid.count == 2 else { return }
        Settings.shared.gazeColumns = grid[0]
        Settings.shared.gazeRows = grid[1]
        refreshMenu()
    }

    @objc private func toggleGazeFlipX() {
        Settings.shared.gazeInvertX.toggle()
        refreshMenu()
    }

    @objc private func toggleGazeFlipY() {
        Settings.shared.gazeInvertY.toggle()
        refreshMenu()
    }

    @objc private func toggleGazeWarmCamera() {
        Settings.shared.gazeKeepCameraWarm.toggle()
        GazeSession.shared.refresh()
        refreshMenu()
    }

    @objc private func resetGazeCalibration() {
        Settings.shared.clearGazeCalibration()
        refreshMenu()
    }

    @objc private func calibrateGaze() {
        GazeTracker.requestAccess { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.showCameraDeniedAlert()
                return
            }
            GazeCalibrator.shared.start { _ in self.refreshMenu() }
        }
    }

    private func offerCalibration() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Calibrate eye tracking?"
        alert.informativeText = """
            Uncalibrated, Shiftly guesses at how far you turn your head, so it \
            will pick the right display but often the wrong zone on it. \
            Calibration walks a dot around each screen and takes about \
            \(Int(Double(NSScreen.screens.count * gazeCalibrationTargets.count) * (gazeCalibrationSettle + gazeCalibrationCollect))) seconds.
            """
        alert.addButton(withTitle: "Calibrate")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            GazeCalibrator.shared.start { _ in self.refreshMenu() }
        }
    }

    private func showCameraDeniedAlert() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Shiftly needs camera access"
        alert.informativeText = "Eye tracking reads head and eye position on device. "
            + "Grant camera access in Privacy & Security, then enable it again."
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
            NSWorkspace.shared.open(url)
        }
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

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            log("login item toggle failed: \(error.localizedDescription)")
            NSSound.beep()
        }
        refreshMenu()
    }

    @objc private func checkForUpdates() {
        Updater.check()
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
