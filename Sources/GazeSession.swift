import AppKit
import Carbon.HIToolbox

/// A zone is a cell of the grid on one display. Identity includes the display,
/// so moving between screens is the same kind of event as moving between cells.
struct GazeZone: Equatable {
    let display: CGDirectDisplayID
    let column: Int
    let row: Int
}

func carbonToEventFlags(_ mods: UInt32) -> CGEventFlags {
    var flags = CGEventFlags()
    if mods & UInt32(cmdKey) != 0 { flags.insert(.maskCommand) }
    if mods & UInt32(shiftKey) != 0 { flags.insert(.maskShift) }
    if mods & UInt32(optionKey) != 0 { flags.insert(.maskAlternate) }
    if mods & UInt32(controlKey) != 0 { flags.insert(.maskControl) }
    return flags
}

/// The gaze layer.
///
/// Carbon can't register a modifier-only hot key, so the chord is watched by
/// polling `CGEventSource.flagsState`, the same state query the keyboard
/// gestures already use to notice a release. It's a query rather than an event
/// stream, so Secure Input can't blind it and no event tap is involved.
final class GazeSession {
    static let shared = GazeSession()

    private let overlay = Overlay()
    private var pollTimer: Timer?

    private var chordFrames = 0
    private var active = false
    private var suspended = false
    private var blockedUntilRelease = false

    private var window: AXUIElement?
    private var original = CGRect.zero
    private var preview = CGRect.zero
    private var zone: GazeZone?
    private var startedAt: TimeInterval = 0

    private var pendingZone: GazeZone?
    private var pendingFrames = 0

    private init() {}

    // MARK: Chord watching

    /// (Re)installs the poll to match current settings.
    func refresh() {
        pollTimer?.invalidate()
        pollTimer = nil
        chordFrames = 0

        guard Settings.shared.gazeEnabled else {
            cancel()
            GazeTracker.shared.stop()
            log("gaze: disabled")
            return
        }

        pollTimer = Timer.scheduledTimer(withTimeInterval: gazeChordPoll, repeats: true) { [weak self] _ in
            self?.poll()
        }
        if Settings.shared.gazeKeepCameraWarm {
            GazeTracker.shared.start()
        }
        log("gaze: enabled, watching \(describeChord())")
    }

    /// Calibration drives the tracker itself, so the chord is ignored while it runs.
    func suspend() {
        suspended = true
        cancel()
    }

    func resume() {
        suspended = false
        chordFrames = 0
        blockedUntilRelease = false
    }

    private func describeChord() -> String {
        let mods = Settings.shared.gazeModifiers
        return gazeModifierChoices.first { $0.mods == mods }?.title ?? "?"
    }

    private func heldFlags() -> CGEventFlags {
        let mask: CGEventFlags = [.maskCommand, .maskShift, .maskAlternate, .maskControl]
        return CGEventSource.flagsState(.combinedSessionState).intersection(mask)
    }

    private func poll() {
        guard !suspended else { return }
        let chord = carbonToEventFlags(Settings.shared.gazeModifiers)
        // Exact match, not a subset: ⌃⌘ must not fire while ⌃⌥⌘ drives another layer.
        let matched = heldFlags() == chord

        if !matched {
            // Release a camera that was warmed for a hold that never landed.
            if chordFrames >= gazeChordPrewarm && !active { GazeTracker.shared.stopSoon() }
            chordFrames = 0
            blockedUntilRelease = false
            if active { commit() }
            return
        }

        if active {
            if ProcessInfo.processInfo.systemUptime - startedAt > gazeTimeout { commit() }
            return
        }

        guard !blockedUntilRelease else { return }
        chordFrames += 1
        if chordFrames == gazeChordPrewarm { GazeTracker.shared.start() }
        if chordFrames >= gazeChordDebounce { begin() }
    }

    // MARK: Session

    private func begin() {
        guard !gestureEngine.isActive else { return }
        guard let focused = focusedWindow(), let current = frame(of: focused) else {
            log("gaze: no focused window (accessibility permission missing?)")
            NSSound.beep()
            blockedUntilRelease = true
            return
        }

        window = focused
        original = current
        preview = current
        zone = nil
        pendingZone = nil
        pendingFrames = 0
        startedAt = ProcessInfo.processInfo.systemUptime
        active = true

        // Show the placement rectangle where the window already is, before any
        // frames arrive. Starting the camera costs a few hundred milliseconds,
        // and without this the gesture reads as broken for that whole window.
        overlay.show(axRect: preview, from: preview)

        GazeTracker.shared.onSample = { [weak self] sample in
            self?.handle(sample)
        }
        GazeTracker.shared.start()
        log("gaze: session started")
    }

    private func handle(_ sample: GazeSample) {
        guard active else { return }

        // The flips only apply to the fallback maps. A fitted map derives its
        // own signs from the calibration data, which the calibrator collects
        // raw, so flipping on top of one would just break it.
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

        let headMap = Settings.shared.gazeHeadMap ?? GazeMap.fallback(includeEyes: false)
        let fineMap = Settings.shared.gazeFineMap ?? GazeMap.fallback(includeEyes: true)

        // Display first, from head rotation alone. Then the zone within it,
        // from head and eyes together, clamped so the fine estimate can only
        // pick a rectangle on the display the head already chose.
        let screen = nearestScreen(to: headMap.point(for: adjusted))
        let area = usableFrame(of: screen)
        let fine = fineMap.point(for: adjusted)
        let point = CGPoint(x: min(max(fine.x, area.minX), area.maxX - 1),
                            y: min(max(fine.y, area.minY), area.maxY - 1))

        let columns = Settings.shared.gazeColumns
        let rows = Settings.shared.gazeRows
        let column = min(columns - 1, max(0, Int((point.x - area.minX) / (area.width / CGFloat(columns)))))
        let row = min(rows - 1, max(0, Int((point.y - area.minY) / (area.height / CGFloat(rows)))))
        let candidate = GazeZone(display: displayID(of: screen), column: column, row: row)

        guard candidate != zone else {
            pendingZone = nil
            pendingFrames = 0
            return
        }

        let crossesDisplay = zone.map { $0.display != candidate.display } ?? false
        let rect = zoneRect(column: column, row: row, in: area, columns: columns, rows: rows)

        // The point has to sit well inside the new cell, not just barely over
        // the seam, or the overlay chatters between neighbours.
        let inset = rect.insetBy(dx: rect.width * gazeZoneDeadband, dy: rect.height * gazeZoneDeadband)
        guard inset.contains(point) else { return }
        if crossesDisplay {
            let screenRect = flipRect(screen.frame)
            let screenInset = screenRect.insetBy(dx: screenRect.width * gazeScreenDeadband,
                                                 dy: screenRect.height * gazeScreenDeadband)
            guard screenInset.contains(headMap.point(for: adjusted)) else { return }
        }

        if candidate == pendingZone {
            pendingFrames += 1
        } else {
            pendingZone = candidate
            pendingFrames = 1
        }
        guard pendingFrames >= (crossesDisplay ? gazeScreenHold : gazeZoneHold) else { return }

        zone = candidate
        pendingZone = nil
        pendingFrames = 0
        preview = rect
        // Gaze always previews. Driving the real window at frame rate would
        // fight every app that reflows on resize.
        overlay.show(axRect: preview)
    }

    private func zoneRect(column: Int, row: Int, in area: CGRect, columns: Int, rows: Int) -> CGRect {
        let width = area.width / CGFloat(columns)
        let height = area.height / CGFloat(rows)
        return CGRect(x: area.minX + CGFloat(column) * width,
                      y: area.minY + CGFloat(row) * height,
                      width: width,
                      height: height)
    }

    private func commit() {
        guard active else { return }
        active = false
        overlay.hide()
        GazeTracker.shared.onSample = nil
        GazeTracker.shared.stopSoon()

        if let window, preview.integral != original.integral {
            setFrame(preview.integral, on: window)
            log("gaze: committed")
        } else {
            log("gaze: session ended without a change")
        }
        window = nil
        zone = nil
    }

    /// Drops the session without moving anything.
    func cancel() {
        guard active else { return }
        active = false
        overlay.hide()
        GazeTracker.shared.onSample = nil
        GazeTracker.shared.stopSoon()
        window = nil
        zone = nil
        log("gaze: session cancelled")
    }
}
