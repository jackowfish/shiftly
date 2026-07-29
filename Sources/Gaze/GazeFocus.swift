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

    /// Where you last clicked, which outranks gaze for a moment afterwards.
    private var clickedDisplay: CGDirectDisplayID?
    private var clickedAt: TimeInterval = 0
    private var clickMonitor: Any?

    private var lastTraceAt: TimeInterval = 0
    private var frameCount = 0

    private init() {}

    /// Whether the camera has a face in frame right now, which the menu uses to
    /// tell "nobody there" apart from "there, but not clearly on one display".
    var isSeeingFace: Bool {
        ProcessInfo.processInfo.systemUptime - GazeTracker.shared.lastFaceAt < gazeStaleAfter
    }

    /// Display currently being looked at, for the menu to report.
    var currentDisplayName: String? {
        guard let display = gazedDisplay(),
              let screen = NSScreen.screens.first(where: { displayID(of: $0) == display })
        else { return nil }
        return screen.localizedName
    }

    // MARK: Lifecycle

    func refresh() {
        pollTimer?.invalidate()
        pollTimer = nil
        heldFrames = 0
        clickedDisplay = nil
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        GazeDebugOverlay.shared.refresh()

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
        // Clicking a display is you saying which screen you mean, out loud, so
        // it wins over what the camera thinks for a moment. A monitor rather
        // than an event tap, so it observes without intercepting anything.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.noteClick()
        }
        if let profile = Settings.shared.gazeProfile {
            debugLog("gaze axis weights: \(profile.weightSummary)")
            debugLog("gaze placement fits: \(profile.placementSummary)")
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
        GazeDebugOverlay.shared.hide()
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
        GazeDebugOverlay.shared.update()
    }

    private func noteClick() {
        let point = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) else { return }
        clickedDisplay = displayID(of: screen)
        clickedAt = ProcessInfo.processInfo.systemUptime
    }

    /// The reading a decision is made from: the median of the newest few
    /// frames, per axis, or nil when the camera has nothing recent.
    ///
    /// Taking the median across axes independently can in principle name a
    /// point no single frame reported. That's fine here, and is the point: each
    /// axis is measured separately anyway, and it keeps one bad landmark fit on
    /// one axis from dragging the others with it.
    func reading() -> GazeSample? {
        let samples = GazeTracker.shared.recent(within: gazeDecisionWindow).suffix(gazeDecisionFrames)
        guard !samples.isEmpty else { return nil }
        return GazeSample.perAxis { axis in
            let sorted = samples.map { $0[keyPath: axis] }.sorted()
            return sorted[sorted.count / 2]
        }
    }

    /// Where on the desktop the estimate points, or nil when the calibration
    /// predates placement and can only name a display.
    func gazedPoint() -> CGPoint? {
        guard Settings.shared.gazeEnabled,
              let profile = Settings.shared.gazeProfile,
              let reading = reading()
        else { return nil }
        return profile.point(for: reading)
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

        // Traced from the same reading a press would decide on, not the raw
        // frame, so the log shows what a gesture right now would actually do.
        let decided = reading() ?? sample
        var scores = "no profile"
        if let profile = Settings.shared.gazeProfile {
            scores = profile.ranking(for: decided)
                .map { String(format: "%u:%.2f", $0.display, $0.distance) }
                .joined(separator: " ")
        }
        debugLog(String(format: "gaze %.0ffps head %.3f/%.3f eye %.3f/%.3f | %@ | current %@",
                        rate, decided.headX, decided.headY, decided.eyeX, decided.eyeY,
                        scores, gazedDisplay().map(String.init) ?? "none"))
    }

    // MARK: Focus

    /// Display being looked at right now, or nil when the estimate is off,
    /// stale, or too close to call.
    ///
    /// Computed on demand from the newest frames rather than read off a running
    /// estimate. Nothing to settle, and nothing to get stuck on: the previous
    /// answer has no say in this one.
    func gazedDisplay() -> CGDirectDisplayID? {
        guard Settings.shared.gazeEnabled, NSScreen.screens.count > 1 else { return nil }
        if let clickedDisplay,
           ProcessInfo.processInfo.systemUptime - clickedAt < gazeClickOverride {
            return clickedDisplay
        }
        guard let profile = Settings.shared.gazeProfile, let reading = reading() else { return nil }
        return profile.display(for: reading)
    }

    /// The window a gesture should start on, or nil to use the normal frontmost
    /// window. Focuses it as a side effect, which is the point.
    ///
    /// Asked once per gesture, on the opening press. Only the display you aren't
    /// already on can be claimed by the frontmost-window fallback, so glancing
    /// around your current screen can't retarget you off a bad reading.
    func gazedWindow() -> AXUIElement? {
        let owner = focusedWindow().flatMap(frame(of:)).map { displayID(of: screenContaining($0)) }
        guard let target = gazedTarget(alreadyOn: owner).pick else { return nil }
        // Already on it, so there's nothing to move focus to. Checked here
        // rather than inside gazedTarget, which answers where you're looking
        // and shouldn't have an opinion about what's focused.
        if let focused = focusedWindow().flatMap(frame(of:)),
           nearlyEqual(focused, target.bounds) { return nil }

        let started = ProcessInfo.processInfo.systemUptime
        // AX is resolved for the winner only. Asking every window on the screen
        // would mean a synchronous round trip per app, on the keypress.
        guard let element = axWindow(pid: target.pid, matching: target.bounds) else {
            log("gaze: could not reach the window being looked at")
            return nil
        }
        focus(element, pid: target.pid)
        // Timed because this is the one part of the press that isn't ours: it
        // waits on other apps to answer, and that's where a slow gesture would
        // now be coming from.
        let camera = ProcessInfo.processInfo.systemUptime - GazeTracker.shared.lastFaceAt
        debugLog(String(format: "gaze retarget to display %u %@: newest frame %.0fms old, window lookup %.0fms",
                        target.display, target.reason, camera * 1000,
                        (ProcessInfo.processInfo.systemUptime - started) * 1000))
        return element
    }

    /// The window the estimate points at, or why it doesn't point at one.
    ///
    /// Two ways to land on one. If the calibration can place the dot and the dot
    /// is inside a window, that window wins, which is what makes this work
    /// between two windows on one screen. Failing that, changing displays takes
    /// whatever is frontmost over there, which needs no placement fit.
    ///
    /// Returns a reason even when it declines, because the debug overlay reads
    /// this and going blank is useless exactly when you're working out why.
    /// Deliberately says nothing about whether the window is already focused:
    /// that's "would a press change anything", and it lives in `gazedWindow`.
    /// It used to live here, which darkened the overlay whenever you looked at
    /// the window you were already in.
    enum Target {
        case window(display: CGDirectDisplayID, pid: pid_t, bounds: CGRect, reason: String)
        /// Nothing to act on, and the reason, which is the overlay's caption.
        case none(String)

        var pick: (display: CGDirectDisplayID, pid: pid_t, bounds: CGRect, reason: String)? {
            guard case let .window(display, pid, bounds, reason) = self else { return nil }
            return (display: display, pid: pid, bounds: bounds, reason: reason)
        }

        var reason: String {
            switch self {
            case let .window(_, _, _, reason): return reason
            case let .none(why): return why
            }
        }
    }

    func gazedTarget(alreadyOn owner: CGDirectDisplayID? = nil) -> Target {
        guard Settings.shared.gazeEnabled else { return .none("off") }
        guard Settings.shared.gazeProfile != nil else { return .none("not calibrated") }
        guard reading() != nil else { return .none("no recent frame") }
        guard let display = gazedDisplay() else { return .none("displays too close to call") }
        guard let screen = NSScreen.screens.first(where: { displayID(of: $0) == display })
        else { return .none("display went away") }

        let candidates = windows(on: screen)
        guard !candidates.isEmpty else { return .none("no windows on display \(display)") }

        var picked: (pid: pid_t, bounds: CGRect)?
        var reason = "frontmost"
        var declined = "no dot to place"
        if let point = gazedPoint() {
            // Whatever is on top at that point, and only that. The list is
            // front to back, so the first window containing the point is the one
            // you can actually see there. Testing the inset while searching
            // instead of after would walk past a front window whose margin the
            // dot landed in and focus one behind it, which is a window something
            // else is drawn over and you are provably not looking at.
            if let top = candidates.first(where: { $0.bounds.contains(point) }) {
                // Inset because a dot near an edge is as likely to belong to
                // whatever is on the other side of it, and a gesture that flips
                // between two windows as you read along a shared border is worse
                // than one that does nothing. Capped at a fifth of the window so
                // small ones stay reachable.
                let margin = top.bounds.insetBy(
                    dx: min(gazeWindowInset, top.bounds.width * 0.2),
                    dy: min(gazeWindowInset, top.bounds.height * 0.2))
                if margin.contains(point) {
                    picked = top
                    reason = "by dot"
                } else {
                    declined = "dot is in the edge of \(name(of: top.pid))"
                }
            } else {
                declined = "dot is not over a window"
            }
        }
        if picked == nil {
            // Nothing clearly under the estimate. A different display still
            // means the frontmost window there; the same display means leave
            // whatever you're working on alone.
            guard owner != display else { return .none(declined) }
            picked = candidates.first
        }

        guard let chosen = picked else { return .none(declined) }
        return .window(display: display, pid: chosen.pid, bounds: chosen.bounds, reason: reason)
    }

    /// App name for a pid, for the overlay caption only.
    private func name(of pid: pid_t) -> String {
        NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)"
    }

    /// Normal windows whose centre sits on `screen`, front to back.
    ///
    /// `CGWindowListCopyWindowInfo` returns front to back, and the keys used
    /// here (owner, bounds, layer) come back without Screen Recording
    /// permission. Only window *names* are gated, and those aren't needed.
    private func windows(on screen: NSScreen) -> [(pid: pid_t, bounds: CGRect)] {
        let area = flipRect(screen.frame)
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        let ownPid = ProcessInfo.processInfo.processIdentifier
        var out: [(pid: pid_t, bounds: CGRect)] = []
        for info in list {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != ownPid,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict)
            else { continue }
            // Skip palettes and stray chrome that would be a strange thing to snap.
            guard bounds.width > 120, bounds.height > 120 else { continue }
            guard area.contains(CGPoint(x: bounds.midX, y: bounds.midY)) else { continue }
            out.append((pid: pid, bounds: bounds))
        }
        return out
    }

    private func nearlyEqual(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= 4 && abs(a.minY - b.minY) <= 4
            && abs(a.width - b.width) <= 4 && abs(a.height - b.height) <= 4
    }

    private func axWindow(pid: pid_t, matching bounds: CGRect) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        // This runs on the keypress and talks to another process, which might
        // be busy. Bounded so a stalled app costs a fallback, not the gesture.
        AXUIElementSetMessagingTimeout(app, gazeAXTimeout)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == CFArrayGetTypeID()
        else { return nil }

        for window in value as! [AXUIElement] {
            guard let rect = frame(of: window) else { continue }
            if nearlyEqual(rect, bounds) { return window }
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
