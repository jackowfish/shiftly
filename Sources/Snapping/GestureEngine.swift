import AppKit
import ApplicationServices

/// Accumulates arrow presses into a pending placement while the modifier is
/// held, then commits the move when Cmd is released. With the placement
/// window off, the real window moves live on each press instead.
final class GestureEngine {
    private let overlay = Overlay()

    private var placement: Placement?
    private var window: AXUIElement?
    private var started: TimeInterval = 0
    private var timer: Timer?

    func handle(layer newLayer: Layer, direction: Direction, label: String) {
        var isFirstPress = false

        if placement == nil {
            // With eye tracking on, the first press starts on whatever window
            // sits on the display being looked at, falling back to the normal
            // frontmost window when it is off, stale, or already the right one.
            let gazed = GazeFocus.shared.gazedWindow()
            // Fall through to the normal window if the gaze pick turns out to
            // have no readable frame instead of failing the whole gesture.
            var target = gazed
            if target == nil || frame(of: target!) == nil {
                if gazed != nil { debugLog("gaze pick had no readable frame, using frontmost") }
                target = focusedWindow()
            }
            guard let focused = target, let current = frame(of: focused) else {
                log("no window to act on (frontmost app exposes none, or accessibility is off)")
                NSSound.beep()
                return
            }
            let screens = snapScreens()
            guard !screens.isEmpty else {
                log("no displays")
                return
            }
            placement = Placement(window: current, layer: newLayer, screens: screens)
            window = focused
            isFirstPress = true
            startPolling()
        }
        guard var placement else { return }

        if !placement.press(direction, layer: newLayer) {
            log("no display \(direction)")
            NSSound.beep()
        }
        self.placement = placement

        if Settings.shared.overlayEnabled {
            overlay.show(axRect: placement.preview, from: isFirstPress ? placement.start : nil)
        } else if let window {
            setFrame(placement.preview.integral, on: window)
        }
        log("preview: \(label)")
    }

    // MARK: Commit

    private func startPolling() {
        started = ProcessInfo.processInfo.systemUptime
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self else { return }
            let cmdHeld = CGEventSource.flagsState(.combinedSessionState).contains(.maskCommand)
            let elapsed = ProcessInfo.processInfo.systemUptime - self.started
            if !cmdHeld || elapsed > gestureTimeout {
                self.commit()
            }
        }
    }

    private func commit() {
        timer?.invalidate()
        timer = nil
        overlay.hide()
        guard let placement else { return }
        self.placement = nil

        // Compare against the frame at gesture start. A layer change moves
        // `original`, and a press after it can leave the preview equal to it.
        if let window, placement.preview.integral != placement.start.integral {
            setFrame(placement.preview.integral, on: window)
            log("committed")
        } else {
            log("gesture ended without a change")
        }
        window = nil
    }
}

let gestureEngine = GestureEngine()
