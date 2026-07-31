import AppKit
import ApplicationServices
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?

    /// The gaze readout is the one menu row whose text changes on its own, so
    /// it is held onto and retitled while the menu is up. Everything else in the
    /// menu only changes in response to a click, which rebuilds it anyway.
    private var gazeStatusItem: NSMenuItem?
    private var gazeStatusTimer: Timer?

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
        GazeFocus.shared.refresh()

        // The debug windows are sized to the screens they were built for, so a
        // rearrangement has to rebuild them or the dot lands in the wrong place.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main) { _ in GazeDebugOverlay.shared.refresh() }
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

        let gazeItem = menu.addItem(withTitle: "Eye Tracking (Beta)", action: nil, keyEquivalent: "")
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
        let logsItem = menu.addItem(withTitle: "Logs", action: nil, keyEquivalent: "")
        let logsMenu = NSMenu()
        logsMenu.autoenablesItems = false
        let openLogItem = logsMenu.addItem(withTitle: "Open Log", action: #selector(openLog), keyEquivalent: "")
        openLogItem.target = self
        let revealLogItem = logsMenu.addItem(withTitle: "Reveal in Finder",
                                             action: #selector(revealLog),
                                             keyEquivalent: "")
        revealLogItem.target = self
        logsMenu.addItem(.separator())
        let debugItem = logsMenu.addItem(withTitle: "Debug Logging",
                                         action: #selector(toggleDebugLogging),
                                         keyEquivalent: "")
        debugItem.target = self
        debugItem.state = Settings.shared.debugLogging ? .on : .off
        logsMenu.addItem(withTitle: "Traces eye tracking in detail. Noisy, leave off",
                         action: nil, keyEquivalent: "").isEnabled = false
        logsMenu.addItem(withTitle: "unless something needs diagnosing.",
                         action: nil, keyEquivalent: "").isEnabled = false
        logsMenu.addItem(.separator())
        let clearLogItem = logsMenu.addItem(withTitle: "Clear Log", action: #selector(clearLog), keyEquivalent: "")
        clearLogItem.target = self
        logsItem.submenu = logsMenu

        let settingsItem = menu.addItem(withTitle: "Accessibility Settings",
                                        action: #selector(openAccessibilitySettings),
                                        keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Shiftly", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    private func gazeStatusText() -> String {
        let settings = Settings.shared
        if !settings.gazeEnabled { return "Off" }
        if !settings.isGazeCalibrated {
            return settings.hasStaleGazeCalibration
                ? "Calibration is from an older version, recalibrate"
                : "Needs calibration before it can do anything"
        }
        if settings.gazeCalibrationArrangement != screenArrangementFingerprint() {
            return "Calibrated for a different display layout, recalibrate"
        }
        if let name = GazeFocus.shared.currentDisplayName { return "Looking at: \(name)" }
        // Distinct from the camera merely being warm on demand: with nothing
        // in the allowed list connected, no gesture can bring it up either.
        if !GazeTracker.allCameras().contains(where: GazeTracker.isAllowed) {
            return "Paused: no selected camera is connected"
        }
        if !GazeTracker.shared.isRunning {
            return "Ready (camera starts when you hold a modifier)"
        }
        // A black feed would otherwise read as "no face visible", which points
        // you at your chair instead of at the camera cable.
        if GazeTracker.shared.blackedOut {
            return "Camera is on but the picture is black, check its connection"
        }
        // Camera is up, so the two ways of having no answer are worth telling
        // apart: nobody in frame at all, versus a face sitting somewhere the
        // calibration cannot call between two displays.
        return GazeFocus.shared.isSeeingFace
            ? "Looking at: too close to call"
            : "Looking at: no face visible"
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
        menu.addItem(withTitle: "Gestures start on the display you're looking at",
                     action: nil,
                     keyEquivalent: "").isEnabled = false

        // A live readout instead of settings nobody could be expected to
        // interpret. If this says the wrong display while the menu is open,
        // recalibrating is the answer, and that is the only knob left.
        let statusItem = menu.addItem(withTitle: gazeStatusText(), action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        gazeStatusItem = statusItem
        menu.delegate = self

        let calibrateItem = menu.addItem(withTitle: settings.isGazeCalibrated ? "Recalibrate…" : "Calibrate…",
                                         action: #selector(calibrateGaze),
                                         keyEquivalent: "")
        calibrateItem.target = self

        menu.addItem(.separator())
        let cameraItem = menu.addItem(withTitle: "Camera", action: nil, keyEquivalent: "")
        let cameraMenu = NSMenu()
        cameraMenu.autoenablesItems = false
        let alwaysItem = cameraMenu.addItem(withTitle: "Always on, while eye tracking is enabled",
                                            action: #selector(pickGazeCamera(_:)),
                                            keyEquivalent: "")
        alwaysItem.target = self
        alwaysItem.state = settings.gazeCameraAlwaysOn ? .on : .off
        alwaysItem.representedObject = true

        let onDemandItem = cameraMenu.addItem(withTitle: "Only while holding a modifier",
                                              action: #selector(pickGazeCamera(_:)),
                                              keyEquivalent: "")
        onDemandItem.target = self
        onDemandItem.state = settings.gazeCameraAlwaysOn ? .off : .on
        onDemandItem.representedObject = false

        cameraMenu.addItem(.separator())
        cameraMenu.addItem(withTitle: "On demand keeps the light off between gestures,",
                           action: nil, keyEquivalent: "").isEnabled = false
        cameraMenu.addItem(withTitle: "but a fast gesture can beat the camera starting.",
                           action: nil, keyEquivalent: "").isEnabled = false

        cameraMenu.addItem(.separator())
        cameraMenu.addItem(withTitle: "Cameras eye tracking can use:",
                           action: nil, keyEquivalent: "").isEnabled = false
        let connected = GazeTracker.allCameras()
        var known = Settings.shared.gazeKnownCameras
        for device in connected { known[device.uniqueID] = device.localizedName }
        Settings.shared.gazeKnownCameras = known

        for device in connected {
            let deviceItem = cameraMenu.addItem(withTitle: device.localizedName,
                                                action: #selector(toggleCamera(_:)),
                                                keyEquivalent: "")
            deviceItem.target = self
            deviceItem.state = GazeTracker.isAllowed(device) ? .on : .off
            deviceItem.representedObject = device.uniqueID
        }
        // Cameras seen before but absent right now stay in the list, so one
        // that exists only while its app runs can be selected in advance.
        let connectedIDs = Set(connected.map(\.uniqueID))
        for (id, name) in known.sorted(by: { $0.value < $1.value }) where !connectedIDs.contains(id) {
            let deviceItem = cameraMenu.addItem(withTitle: "\(name) (not connected)",
                                                action: #selector(toggleCamera(_:)),
                                                keyEquivalent: "")
            deviceItem.target = self
            deviceItem.state = GazeTracker.isAllowed(id: id, name: name) ? .on : .off
            deviceItem.representedObject = id
        }
        cameraMenu.addItem(withTitle: "If no checked camera is connected, tracking",
                           action: nil, keyEquivalent: "").isEnabled = false
        cameraMenu.addItem(withTitle: "pauses until one of them comes back.",
                           action: nil, keyEquivalent: "").isEnabled = false
        cameraItem.submenu = cameraMenu

        menu.addItem(.separator())
        let dotItem = menu.addItem(withTitle: "Show Gaze Dot",
                                   action: #selector(toggleGazeDebugOverlay),
                                   keyEquivalent: "")
        dotItem.target = self
        dotItem.state = settings.gazeDebugOverlay ? .on : .off
        menu.addItem(withTitle: "Draws where it thinks you're looking, and outlines",
                     action: nil, keyEquivalent: "").isEnabled = false
        menu.addItem(withTitle: "the display a gesture would act on right now.",
                     action: nil, keyEquivalent: "").isEnabled = false

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

    // MARK: Gaze

    @objc private func toggleGazeDebugOverlay() {
        Settings.shared.gazeDebugOverlay.toggle()
        GazeDebugOverlay.shared.refresh()
        refreshMenu()
    }

    @objc private func toggleGaze() {
        if Settings.shared.gazeEnabled {
            Settings.shared.gazeEnabled = false
            GazeFocus.shared.refresh()
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
            GazeFocus.shared.refresh()
            self.refreshMenu()
            if !Settings.shared.isGazeCalibrated { self.offerCalibration() }
        }
    }

    @objc private func pickGazeCamera(_ sender: NSMenuItem) {
        guard let alwaysOn = sender.representedObject as? Bool else { return }
        Settings.shared.gazeCameraAlwaysOn = alwaysOn
        GazeFocus.shared.refresh()
        refreshMenu()
    }

    @objc private func toggleCamera(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        let name = Settings.shared.gazeKnownCameras[id] ?? id
        // The device carries the better default guess when it is connected;
        // the remembered name has to stand in when it is not.
        let allowed: Bool
        if let device = GazeTracker.allCameras().first(where: { $0.uniqueID == id }) {
            allowed = GazeTracker.isAllowed(device)
        } else {
            allowed = GazeTracker.isAllowed(id: id, name: name)
        }
        var choices = Settings.shared.gazeCameraChoices
        choices[id] = !allowed
        Settings.shared.gazeCameraChoices = choices
        log("gaze: camera \(name) \(choices[id]! ? "selected" : "deselected")")
        GazeTracker.shared.cameraChoicesChanged()
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
        let groups = NSScreen.screens.count * GazeCalibrationStyle.allCases.count
        let seconds = Int(Double(groups * gazeCalibrationTargets.count)
            * (gazeCalibrationSettle + gazeCalibrationCollect)
            + Double(groups * gazeCalibrationCountdown) * gazeCalibrationTick)
        alert.messageText = "Calibrate eye tracking?"
        alert.informativeText = """
            Eye tracking needs to learn what each of your displays looks like to \
            the camera, so it does nothing until you calibrate. A dot walks \
            around each screen and you look at it, which takes about \
            \(seconds) seconds.

            It goes round twice. The first pass wants your head facing straight \
            ahead the whole way through, moving only your eyes, even when the \
            dot crosses to another screen. The second wants you looking \
            naturally, turning your head as much as you like. Both are needed, \
            or it only recognises whichever way you calibrated.
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

    @objc private func revealLog() {
        NSWorkspace.shared.activateFileViewerSelecting([logURL])
    }

    @objc private func clearLog() {
        try? Data().write(to: logURL)
        log("log cleared")
    }

    @objc private func toggleDebugLogging() {
        Settings.shared.debugLogging.toggle()
        log("debug logging \(Settings.shared.debugLogging ? "on" : "off")")
        refreshMenu()
    }

    @objc private func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        else { return }
        NSWorkspace.shared.open(url)
    }
}

/// Keeps the gaze readout live while the menu is up. Without this the row is
/// whatever it said when the menu was last rebuilt, which is app launch, so it
/// permanently reported no face regardless of what the camera was seeing.
extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        gazeStatusItem?.title = gazeStatusText()
        // Menu tracking runs a nested event loop, so this has to be scheduled
        // in .common mode or it would never fire while the menu is open.
        gazeStatusTimer?.invalidate()
        gazeStatusTimer = scheduleTimer(after: gazeStatusRefresh, repeats: true) { [weak self] in
            guard let self else { return }
            self.gazeStatusItem?.title = self.gazeStatusText()
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        gazeStatusTimer?.invalidate()
        gazeStatusTimer = nil
    }
}
