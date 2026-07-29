import AppKit
import ApplicationServices
import Carbon.HIToolbox

func carbonToEventFlags(_ mods: UInt32) -> CGEventFlags {
    var flags = CGEventFlags()
    if mods & UInt32(cmdKey) != 0 { flags.insert(.maskCommand) }
    if mods & UInt32(shiftKey) != 0 { flags.insert(.maskShift) }
    if mods & UInt32(optionKey) != 0 { flags.insert(.maskAlternate) }
    if mods & UInt32(controlKey) != 0 { flags.insert(.maskControl) }
    return flags
}

/// Picks which display you're looking at, so a gesture can start on the window
/// there instead of whatever happened to be frontmost.
///
/// Nothing here steals focus on its own. The camera warms while a Shiftly
/// modifier is down and the estimate updates in the background, but focus only
/// moves when an arrow actually lands and a gesture begins. That distinction is
/// what makes it safe to key off ⌘: holding ⌘ for Cmd+C or Cmd+Tab while
/// glancing at another monitor does nothing at all.
final class GazeFocus {
    static let shared = GazeFocus()

    private var pollTimer: Timer?
    private var warm = false
    private var heldFrames = 0

    private var display: CGDirectDisplayID?
    /// Last frame a face was found at all. Separate from the classification,
    /// which only changes when you actually look somewhere else.
    private var lastFaceAt: TimeInterval = 0
    private var pending: CGDirectDisplayID?
    private var pendingFrames = 0

    private var lastTraceAt: TimeInterval = 0
    private var frameCount = 0

    private init() {}

    /// Display currently being looked at, for the menu to report.
    var currentDisplayName: String? {
        guard let display,
              ProcessInfo.processInfo.systemUptime - lastFaceAt < gazeStaleAfter,
              let screen = NSScreen.screens.first(where: { displayID(of: $0) == display })
        else { return nil }
        return screen.localizedName
    }

    // MARK: Lifecycle

    func refresh() {
        pollTimer?.invalidate()
        pollTimer = nil
        display = nil
        pending = nil
        pendingFrames = 0
        heldFrames = 0
        lastFaceAt = 0

        guard Settings.shared.gazeEnabled else {
            warm = false
            GazeTracker.shared.onSample = nil
            GazeTracker.shared.stop()
            log("gaze: disabled")
            return
        }

        GazeTracker.shared.onSample = { [weak self] sample in
            self?.handle(sample)
        }
        if let profile = Settings.shared.gazeProfile {
            debugLog("gaze axis weights: \(profile.weightSummary)")
        }

        if Settings.shared.gazeCameraAlwaysOn {
            warm = true
            GazeTracker.shared.start()
            log("gaze: enabled, camera always on")
        } else {
            pollTimer = Timer.scheduledTimer(withTimeInterval: gazePoll, repeats: true) { [weak self] _ in
                self?.poll()
            }
            log("gaze: enabled, camera on demand")
        }
    }

    /// Calibration drives the tracker itself.
    func suspend() {
        GazeTracker.shared.onSample = nil
    }

    func resume() {
        refresh()
    }

    private func heldFlags() -> CGEventFlags {
        let mask: CGEventFlags = [.maskCommand, .maskShift, .maskAlternate, .maskControl]
        return CGEventSource.flagsState(.combinedSessionState).intersection(mask)
    }

    /// Warm the camera once the modifiers have been held long enough to be a
    /// gesture rather than a copy-paste, so an estimate is ready by the time an
    /// arrow arrives.
    private func poll() {
        let held = heldFlags()
        let arming = !held.isEmpty && Layer.allCases.contains { layer in
            held.isSubset(of: carbonToEventFlags(Settings.shared.modifiers(for: layer)))
        }

        guard arming else {
            heldFrames = 0
            if warm {
                warm = false
                GazeTracker.shared.stopSoon()
            }
            return
        }

        heldFrames += 1
        if heldFrames >= gazeWarmDwell && !warm {
            warm = true
            GazeTracker.shared.start()
        }
    }

    // MARK: Estimate

    private func handle(_ sample: GazeSample) {
        traceSample(sample)
        // Freshness is about the camera still seeing a face, not about the
        // answer changing. Tying it to the answer meant that looking steadily at
        // one display, or hovering somewhere ambiguous, aged the estimate out
        // and quietly stopped retargeting until something happened to shift.
        lastFaceAt = ProcessInfo.processInfo.systemUptime

        guard let profile = Settings.shared.gazeProfile else { return }
        let candidate = profile.display(for: sample)

        // Evidence leaks away instead of resetting. A glance across the desk
        // passes through the middle, where neither display wins by the required
        // margin, and wiping the count on those frames meant a real look could
        // take seconds to register, or never did if the crossing was jittery.
        if let candidate, candidate != display {
            if candidate == pending {
                pendingFrames += 1
            } else {
                pending = candidate
                pendingFrames = 1
            }
        } else {
            pendingFrames -= 1
            if pendingFrames <= 0 {
                pending = nil
                pendingFrames = 0
            }
        }
        guard let winner = pending, pendingFrames >= gazeDisplayHold else { return }

        display = winner
        pending = nil
        pendingFrames = 0
        log("gaze: looking at display \(winner)")
    }

    /// Once-a-second trace of what the camera sees and how each display scores,
    /// which is the readout for "why did it pick that one".
    private func traceSample(_ sample: GazeSample) {
        guard Settings.shared.debugLogging else { return }
        let now = ProcessInfo.processInfo.systemUptime
        frameCount += 1
        guard now - lastTraceAt >= 1 else { return }
        let rate = Double(frameCount) / max(now - lastTraceAt, 0.001)
        lastTraceAt = now
        frameCount = 0

        var scores = "no profile"
        if let profile = Settings.shared.gazeProfile {
            scores = profile.ranking(for: sample)
                .map { String(format: "%u:%.2f", $0.display, $0.distance) }
                .joined(separator: " ")
        }
        debugLog(String(format: "gaze %.0ffps head %.3f/%.3f eye %.3f/%.3f | %@ | current %@",
                        rate, sample.headX, sample.headY, sample.eyeX, sample.eyeY,
                        scores, display.map(String.init) ?? "none"))
    }

    // MARK: Focus

    /// Display being looked at right now, or nil when the estimate is off,
    /// stale, or too close to call.
    func gazedDisplay() -> CGDirectDisplayID? {
        guard Settings.shared.gazeEnabled, NSScreen.screens.count > 1 else { return nil }
        guard ProcessInfo.processInfo.systemUptime - lastFaceAt < gazeStaleAfter else { return nil }
        return display
    }

    /// The window a gesture should start on, or nil to use the normal frontmost
    /// window. Focuses it as a side effect, which is the point.
    ///
    /// `alreadyOn` is the display the gesture is currently working on. Passing
    /// it lets a gesture already in flight ask the same question mid-run: when
    /// you hold the modifier down and glance at another screen, the gesture
    /// hands off to a window there instead of being stuck on the one it opened
    /// with.
    func gazedWindow(alreadyOn current: CGDirectDisplayID? = nil) -> AXUIElement? {
        guard let target = gazedDisplay() else { return nil }
        guard let screen = NSScreen.screens.first(where: { displayID(of: $0) == target }) else { return nil }

        // Already looking at the display that owns the window in play: leave it
        // alone. Otherwise every gesture would raise whatever is frontmost there,
        // which is not what "focus the screen I'm looking at" means.
        let owner = current ?? focusedWindow().flatMap(frame(of:)).map { displayID(of: screenContaining($0)) }
        if owner == target { return nil }

        guard let found = frontmostWindow(on: screen) else {
            log("gaze: no window on the display being looked at")
            return nil
        }
        focus(found.element, pid: found.pid)
        log("gaze: focused a window on display \(target)")
        return found.element
    }

    /// Frontmost normal window whose centre sits on `screen`.
    ///
    /// `CGWindowListCopyWindowInfo` returns front to back, and the keys used
    /// here (owner, bounds, layer) come back without Screen Recording
    /// permission. Only window *names* are gated, and those aren't needed.
    private func frontmostWindow(on screen: NSScreen) -> (element: AXUIElement, pid: pid_t)? {
        let area = flipRect(screen.frame)
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        let ownPid = ProcessInfo.processInfo.processIdentifier
        for info in list {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != ownPid,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict)
            else { continue }
            // Skip palettes and stray chrome that would be a strange thing to snap.
            guard bounds.width > 120, bounds.height > 120 else { continue }
            guard area.contains(CGPoint(x: bounds.midX, y: bounds.midY)) else { continue }
            if let element = axWindow(pid: pid, matching: bounds) {
                return (element, pid)
            }
        }
        return nil
    }

    private func axWindow(pid: pid_t, matching bounds: CGRect) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == CFArrayGetTypeID()
        else { return nil }

        for window in value as! [AXUIElement] {
            guard let rect = frame(of: window) else { continue }
            if abs(rect.minX - bounds.minX) <= 4, abs(rect.minY - bounds.minY) <= 4,
               abs(rect.width - bounds.width) <= 4, abs(rect.height - bounds.height) <= 4 {
                return window
            }
        }
        return nil
    }

    /// Raise through AX rather than NSRunningApplication, which avoids the
    /// activate() availability split and works the same on every version.
    private func focus(_ window: AXUIElement, pid: pid_t) {
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid),
                                     kAXFrontmostAttribute as CFString,
                                     kCFBooleanTrue)
    }
}
