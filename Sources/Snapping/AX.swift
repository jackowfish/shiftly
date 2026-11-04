import AppKit
import ApplicationServices

/// Focused window of the frontmost app. Sets AXManualAccessibility first:
/// Electron apps keep their AX tree dormant until someone does.
func focusedWindow() -> AXUIElement? {
    guard let app = NSWorkspace.shared.frontmostApplication else {
        log("no frontmost application")
        return nil
    }
    // Our own overlay and calibration windows are frontmost while they are up,
    // and they have no AX window to snap. Returning nil here lets the caller
    // fall back instead of reporting a missing permission.
    guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
        debugLog("frontmost app is Shiftly itself, no window to act on")
        return nil
    }
    debugLog("frontmost app: \(app.localizedName ?? "?") (pid \(app.processIdentifier))")
    let appElement = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)

    var value: CFTypeRef?
    for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
        value = nil
        if AXUIElementCopyAttributeValue(appElement, attribute as CFString, &value) == .success,
           let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
            return (value as! AXUIElement)
        }
    }

    value = nil
    if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value) == .success,
       let value, CFGetTypeID(value) == CFArrayGetTypeID() {
        let windows = value as! [AXUIElement]
        return windows.first
    }
    return nil
}

func frame(of window: AXUIElement) -> CGRect? {
    var positionValue: CFTypeRef?
    var sizeValue: CFTypeRef?
    guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue) == .success,
          AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success,
          let positionValue, let sizeValue
    else { return nil }

    var origin = CGPoint.zero
    var size = CGSize.zero
    AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin)
    AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
    return CGRect(origin: origin, size: size)
}

/// Bumped on every write, so a newer write cancels the retries of an older one.
private var frameWriteGeneration = 0

/// Moves and resizes the window, then reads the frame back and writes again until it matches.
///
/// A size write takes the limits of the display the window is on at that moment.
/// On a move to another display, the first size write can get the old display's limits.
func setFrame(_ rect: CGRect, on window: AXUIElement) {
    frameWriteGeneration += 1
    writeFrame(rect, on: window)
    verifyFrame(rect, on: window, generation: frameWriteGeneration, attemptsLeft: frameWriteRetries, previous: nil)
}

private let frameWriteRetries = 4
private let frameWriteSettle: TimeInterval = 0.03

private func verifyFrame(_ rect: CGRect, on window: AXUIElement, generation: Int,
                         attemptsLeft: Int, previous: CGRect?) {
    DispatchQueue.main.asyncAfter(deadline: .now() + frameWriteSettle) {
        guard generation == frameWriteGeneration, let actual = frame(of: window) else { return }
        if actual.matches(rect, tolerance: 2) { return }
        // The frame did not change since the last write, so the app sets its own limit.
        // Terminals that snap to a character grid do this.
        if attemptsLeft == 0 || previous.map({ actual.matches($0, tolerance: 1) }) == true {
            debugLog("window kept \(actual) instead of \(rect)")
            return
        }
        writeFrame(rect, on: window)
        verifyFrame(rect, on: window, generation: generation, attemptsLeft: attemptsLeft - 1, previous: actual)
    }
}

private func writeFrame(_ rect: CGRect, on window: AXUIElement) {
    // Chromium mangles AX moves while AXEnhancedUserInterface is set;
    // clear it for the write and restore after.
    var pid: pid_t = 0
    var appElement: AXUIElement?
    var hadEnhancedUI = false
    if AXUIElementGetPid(window, &pid) == .success {
        let element = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, "AXEnhancedUserInterface" as CFString, &value) == .success,
           let flag = value as? Bool, flag {
            hadEnhancedUI = true
            AXUIElementSetAttributeValue(element, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse)
        }
        appElement = element
    }
    defer {
        if hadEnhancedUI, let appElement {
            AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
    }

    var origin = rect.origin
    var size = rect.size

    func writePosition() {
        if let value = AXValueCreate(.cgPoint, &origin) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
        }
    }

    func writeSize() {
        if let value = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
        }
    }

    // Size first, so a large window fits the destination before it moves there.
    // The second pair repeats the writes after the move. Terminals shift when they clamp their own size.
    writeSize()
    writePosition()
    writeSize()
    writePosition()
}
