import AppKit
import ApplicationServices

/// Accumulates arrow presses into a pending placement while the modifier is
/// held, then commits the move when Cmd is released. With the placement
/// window off, the real window moves live on each press instead.
final class GestureEngine {
    private let overlay = Overlay()

    private var active = false
    private var layer = Layer.halves
    private var window: AXUIElement?
    private var original = CGRect.zero
    private var preview = CGRect.zero
    private var previewScreen: NSScreen?
    private var started: TimeInterval = 0
    private var timer: Timer?

    // Halves layer: a ladder per axis. horiz -1/0/1 = left/none/right;
    // vert 1 = maximize, 2 = top half, -1 = center, -2 = bottom half
    // (quarters when both axes are set).
    private var horiz = 0
    private var vert = 0

    /// Gesture started from a window already in a snap position, so the
    /// ladder skips the "unsnap to itself" rung.
    private var seeded = false

    // Thirds layer: index into thirdSlots (or the fullscreen endcaps) plus a
    // top/bottom-half ladder.
    private var slot: Int?
    private var sixth = 0

    func handle(layer newLayer: Layer, direction: Direction, label: String) {
        var isFirstPress = false

        // Gaze picks the target once, when the gesture opens, and the rest of
        // the gesture stays on it. An earlier version also re-asked on every
        // press and handed off to whatever you'd since glanced at, committing
        // the pending placement on the way out. It read as the window being
        // yanked away mid-adjustment: you look up to check the result, and the
        // next arrow is acting on something else.
        if !active {
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
            begin(on: focused, frame: current, layer: newLayer)
            isFirstPress = true
        } else if newLayer != layer {
            // Carry the pending placement across so layers compose.
            original = preview
            previewScreen = screenContaining(preview)
            layer = newLayer
            resetLayerState()
        }

        step(direction)

        if Settings.shared.overlayEnabled {
            overlay.show(axRect: preview, from: isFirstPress ? original : nil)
        } else if let window {
            setFrame(preview.integral, on: window)
        }
        log("preview: \(label)")
    }

    private func begin(on target: AXUIElement, frame rect: CGRect, layer newLayer: Layer) {
        window = target
        original = rect
        preview = rect
        previewScreen = screenContaining(rect)
        layer = newLayer
        resetLayerState()
        active = true
        startPolling()
    }

    private func resetLayerState() {
        horiz = 0
        vert = 0
        seeded = false
        slot = nil
        sixth = 0
        if layer == .halves { seedHalves() }
    }

    /// Start the ladder from the window's current snap position, if it is in one.
    private func seedHalves() {
        guard let previewScreen else { return }
        let area = usableFrame(of: previewScreen)

        func matches(_ rect: CGRect) -> Bool {
            abs(rect.minX - original.minX) <= slotTolerance
                && abs(rect.minY - original.minY) <= slotTolerance
                && abs(rect.width - original.width) <= slotTolerance
                && abs(rect.height - original.height) <= slotTolerance
        }

        let centerWidth = area.width * centerScale
        let centerHeight = area.height * centerScale
        let positions: [(h: Int, v: Int, rect: CGRect)] = [
            (0, 1, area),
            (-1, 0, CGRect(x: area.minX, y: area.minY, width: area.width / 2, height: area.height)),
            (1, 0, CGRect(x: area.midX, y: area.minY, width: area.width / 2, height: area.height)),
            (0, 2, CGRect(x: area.minX, y: area.minY, width: area.width, height: area.height / 2)),
            (0, -2, CGRect(x: area.minX, y: area.midY, width: area.width, height: area.height / 2)),
            (0, -1, CGRect(x: area.minX + (area.width - centerWidth) / 2,
                           y: area.minY + (area.height - centerHeight) / 2,
                           width: centerWidth, height: centerHeight)),
            (-1, 1, CGRect(x: area.minX, y: area.minY, width: area.width / 2, height: area.height / 2)),
            (1, 1, CGRect(x: area.midX, y: area.minY, width: area.width / 2, height: area.height / 2)),
            (-1, -1, CGRect(x: area.minX, y: area.midY, width: area.width / 2, height: area.height / 2)),
            (1, -1, CGRect(x: area.midX, y: area.midY, width: area.width / 2, height: area.height / 2)),
        ]
        for position in positions where matches(position.rect) {
            horiz = position.h
            vert = position.v
            seeded = true
            return
        }
    }

    private func step(_ direction: Direction) {
        guard let previewScreen else { return }
        let area = usableFrame(of: previewScreen)

        switch layer {
        case .halves:
            stepHalves(direction, area: area)
        case .thirds:
            stepThirds(direction, area: area)
        case .displays:
            stepDisplays(direction)
        }
    }

    // Every press changes something: pushing into a fully covered edge goes
    // fullscreen, a quarter pushed into its own edge flattens to that half,
    // quarters walk across to their sibling, and maximize/center plus a
    // horizontal gives a half.
    private func stepHalves(_ direction: Direction, area: CGRect) {
        switch direction {
        case .left:
            if horiz == -1 {
                if vert == 0 { horiz = 0; vert = 1 } else { vert = 0 }
            } else {
                let fromCenterColumn = horiz == 0
                horiz -= 1
                if horiz == 0 && (vert != 0 || seeded) { horiz -= 1 }
                horiz = max(-1, horiz)
                if fromCenterColumn {
                    switch vert {
                    case 2: vert = 1
                    case -2: vert = -1
                    case 1, -1: vert = 0
                    default: break
                    }
                }
            }
        case .right:
            if horiz == 1 {
                if vert == 0 { horiz = 0; vert = 1 } else { vert = 0 }
            } else {
                let fromCenterColumn = horiz == 0
                horiz += 1
                if horiz == 0 && (vert != 0 || seeded) { horiz += 1 }
                horiz = min(1, horiz)
                if fromCenterColumn {
                    switch vert {
                    case 2: vert = 1
                    case -2: vert = -1
                    case 1, -1: vert = 0
                    default: break
                    }
                }
            }
        case .up:
            if horiz == 0 {
                if vert == 2 { vert = 1 }
                else {
                    vert += 1
                    if vert == 0 && seeded { vert += 1 }
                    vert = min(2, vert)
                }
            } else {
                if vert == 1 { horiz = 0; vert = 2 }
                else { vert = min(1, vert + 1) }
            }
        case .down:
            if horiz == 0 {
                if vert == -2 { vert = 1 }
                else {
                    vert -= 1
                    if vert == 0 && seeded { vert -= 1 }
                    vert = max(-2, vert)
                }
            } else {
                if vert == -1 { horiz = 0; vert = -2 }
                else { vert = max(-1, vert - 1) }
            }
        }

        if horiz == 0 {
            switch vert {
            case 0:
                preview = original  // walked back to the start: unsnap
            case 1:
                preview = area
            case 2:
                preview = CGRect(x: area.minX, y: area.minY, width: area.width, height: area.height / 2)
            case -1:
                let width = area.width * centerScale
                let height = area.height * centerScale
                preview = CGRect(x: area.minX + (area.width - width) / 2,
                                 y: area.minY + (area.height - height) / 2,
                                 width: width,
                                 height: height)
            default:
                preview = CGRect(x: area.minX, y: area.midY, width: area.width, height: area.height / 2)
            }
        } else {
            let x = horiz < 0 ? area.minX : area.midX
            let y = vert >= 0 ? area.minY : area.midY
            let height = vert == 0 ? area.height : area.height / 2
            preview = CGRect(x: x, y: y, width: area.width / 2, height: height)
        }
    }

    private func stepThirds(_ direction: Direction, area: CGRect) {
        switch direction {
        case .left, .right:
            let delta = direction == .left ? -1 : 1
            if let current = slot {
                var next = current + delta
                // Endcaps need the edge fully covered; a sixth does not qualify.
                if (next == fullLeft || next == fullRight) && sixth != 0 { next = current }
                slot = min(fullRight, max(fullLeft, next))
            } else if let match = matchingSlot(original, in: area) {
                slot = min(fullRight, max(fullLeft, match + delta))
            } else {
                slot = direction == .left ? 0 : thirdSlots.count - 1
            }
        case .up:
            if slot == nil { slot = nearestSlot(original, in: area) }
            if slot != fullLeft && slot != fullRight { sixth = min(1, sixth + 1) }
        case .down:
            if slot == nil { slot = nearestSlot(original, in: area) }
            if slot != fullLeft && slot != fullRight { sixth = max(-1, sixth - 1) }
        }

        let current = slot ?? 0
        if current == fullLeft || current == fullRight {
            preview = area
            return
        }
        var rect = thirdSlots[current].rect(in: area)
        if sixth != 0 {
            rect = CGRect(x: rect.minX,
                          y: sixth > 0 ? rect.minY : rect.midY,
                          width: rect.width,
                          height: rect.height / 2)
        }
        preview = rect
    }

    private func stepDisplays(_ direction: Direction) {
        guard let previewScreen else { return }
        guard let destination = adjacentScreen(from: previewScreen, direction: direction) else {
            log("no display \(direction)")
            NSSound.beep()
            return
        }
        preview = proportionalRect(preview,
                                   from: usableFrame(of: previewScreen),
                                   to: usableFrame(of: destination))
        self.previewScreen = destination
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
        guard active else { return }
        active = false

        if let window, preview.integral != original.integral {
            setFrame(preview.integral, on: window)
            log("committed")
        } else {
            log("gesture ended without a change")
        }
        window = nil
    }
}

let gestureEngine = GestureEngine()
