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

    private var display: CGDirectDisplayID?
    private var updatedAt: TimeInterval = 0
    private var pending: CGDirectDisplayID?
    private var pendingFrames = 0

    private init() {}

    // MARK: Lifecycle

    func refresh() {
        pollTimer?.invalidate()
        pollTimer = nil
        display = nil
        pending = nil
        pendingFrames = 0

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

        if Settings.shared.gazeKeepCameraWarm {
            warm = true
            GazeTracker.shared.start()
        } else {
            pollTimer = Timer.scheduledTimer(withTimeInterval: gazePoll, repeats: true) { [weak self] _ in
                self?.poll()
            }
        }
        log("gaze: enabled")
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

    /// Warm the camera while the modifiers could still turn into a gesture, so
    /// an estimate is ready by the time an arrow arrives. Anything that is a
    /// prefix of some layer's chord counts, which for the defaults means ⌘ alone.
    private func poll() {
        let held = heldFlags()
        let arming = !held.isEmpty && Layer.allCases.contains { layer in
            held.isSubset(of: carbonToEventFlags(Settings.shared.modifiers(for: layer)))
        }

        if arming && !warm {
            warm = true
            GazeTracker.shared.start()
        } else if !arming && warm {
            warm = false
            GazeTracker.shared.stopSoon()
        }
    }

    // MARK: Estimate

    private func handle(_ sample: GazeSample) {
        // The flips only apply to the fallback map. A fitted map derives its own
        // signs from calibration data, which is collected raw.
        var adjusted = sample
        if !Settings.shared.isGazeCalibrated {
            if Settings.shared.gazeInvertX {
                adjusted.headX = -adjusted.headX
                adjusted.eyeX = -adjusted.eyeX
            }
            if Settings.shared.gazeInvertY {
                adjusted.headY = 2 * gazeHeadYBias - adjusted.headY
                adjusted.eyeY = -adjusted.eyeY
            }
        }

        let map = Settings.shared.gazeMap ?? GazeMap.fallback()
        let point = map.point(for: adjusted)
        let screen = nearestScreen(to: point)
        let candidate = displayID(of: screen)

        if candidate == display {
            updatedAt = ProcessInfo.processInfo.systemUptime
            pending = nil
            pendingFrames = 0
            return
        }

        // Has to land well inside the new display, not just over its edge.
        let rect = flipRect(screen.frame)
        let inset = rect.insetBy(dx: rect.width * gazeDisplayDeadband,
                                 dy: rect.height * gazeDisplayDeadband)
        guard inset.contains(point) else { return }

        if candidate == pending {
            pendingFrames += 1
        } else {
            pending = candidate
            pendingFrames = 1
        }
        guard pendingFrames >= gazeDisplayHold else { return }

        display = candidate
        updatedAt = ProcessInfo.processInfo.systemUptime
        pending = nil
        pendingFrames = 0
    }

    // MARK: Focus

    /// The window a gesture should start on, or nil to use the normal frontmost
    /// window. Focuses it as a side effect, which is the point.
    func gazedWindow() -> AXUIElement? {
        guard Settings.shared.gazeEnabled, NSScreen.screens.count > 1 else { return nil }
        guard let target = display,
              ProcessInfo.processInfo.systemUptime - updatedAt < gazeStaleAfter
        else { return nil }
        guard let screen = NSScreen.screens.first(where: { displayID(of: $0) == target }) else { return nil }

        // Already looking at the display that owns the focused window: leave it
        // alone. Otherwise every gesture would raise whatever is frontmost there,
        // which is not what "focus the screen I'm looking at" means.
        if let current = focusedWindow(), let rect = frame(of: current),
           displayID(of: screenContaining(rect)) == target {
            return nil
        }

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
