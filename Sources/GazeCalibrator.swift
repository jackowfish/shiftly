import AppKit

/// Walks a dot around every display and fits the gaze maps to what the camera
/// saw at each stop.
///
/// The fit is what resolves the awkward parts of the geometry: the per-face
/// vertical baseline, how far this person actually turns their head versus
/// moving their eyes, and the sign of everything if the camera turned out not
/// to mirror. One pass replaces all the guessed constants.
final class GazeCalibrator {
    static let shared = GazeCalibrator()

    private var windows: [NSWindow] = []
    private var views: [CGDirectDisplayID: CalibrationView] = [:]
    private var targets: [(point: CGPoint, display: CGDirectDisplayID)] = []
    private var references: [GazeReference] = []
    private var collected: [GazeSample] = []
    private var index = 0
    private var collecting = false
    private var stepTimer: Timer?
    private var watchdog: Timer?
    private var keyMonitor: Any?
    private var running = false
    private var onFinish: ((Bool) -> Void)?

    private init() {}

    func start(completion: ((Bool) -> Void)? = nil) {
        guard !NSScreen.screens.isEmpty else {
            log("gaze: calibration needs at least one display")
            return
        }
        if running {
            // A previous run that never reached finish() would otherwise make
            // every future Calibrate click do nothing, silently.
            log("gaze: calibration was already running, restarting it")
            finish(save: false)
        }
        running = true
        onFinish = completion

        GazeFocus.shared.suspend()
        references = []
        collected = []
        index = 0

        targets = NSScreen.screens.flatMap { screen -> [(CGPoint, CGDirectDisplayID)] in
            let area = usableFrame(of: screen)
            let identifier = displayID(of: screen)
            return gazeCalibrationTargets.map { fraction in
                (CGPoint(x: area.minX + area.width * fraction.x,
                         y: area.minY + area.height * fraction.y), identifier)
            }
        }

        buildWindows()
        installCancelMonitor()

        GazeTracker.shared.onRawSample = { [weak self] sample in
            guard let self, self.collecting else { return }
            self.collected.append(sample)
        }
        GazeTracker.shared.start()

        // Nothing here should ever be able to hang without saying so. If the
        // step chain stalls, this ends it and leaves a line in the log.
        let budget = Double(targets.count) * (gazeCalibrationSettle + gazeCalibrationCollect) + 15
        watchdog = scheduleTimer(after: budget) { [weak self] in
            guard let self, self.running else { return }
            log("gaze: calibration stalled at target \(self.index + 1)/\(self.targets.count)")
            // Save rather than discard: finish() checks coverage anyway, so a
            // stall on the last target still keeps a usable calibration.
            self.finish(save: true)
        }

        log("gaze: calibration started, \(targets.count) targets across \(NSScreen.screens.count) displays")
        advance()
    }

    // MARK: Steps

    private func advance() {
        stepTimer?.invalidate()
        guard index < targets.count else {
            finish(save: true)
            return
        }

        let target = targets[index]
        collecting = false
        collected = []
        show(target: target.point, progress: Double(index) / Double(targets.count))
        debugLog("calibration target \(index + 1)/\(targets.count) on display \(target.display) at \(target.point)")

        // Settle first, then average a burst. Averaging across the settle would
        // bake in the travel from the previous dot.
        stepTimer = scheduleTimer(after: gazeCalibrationSettle) { [weak self] in
            guard let self, self.running else { return }
            self.collecting = true
            self.stepTimer = scheduleTimer(after: gazeCalibrationCollect) { [weak self] in
                guard let self, self.running else { return }
                self.record(display: target.display)
            }
        }
    }

    private func record(display: CGDirectDisplayID) {
        collecting = false
        if collected.isEmpty {
            log("gaze: no face seen while looking at display \(display)")
        } else {
            let count = Double(collected.count)
            let mean = GazeSample(
                headX: collected.reduce(0) { $0 + $1.headX } / count,
                headY: collected.reduce(0) { $0 + $1.headY } / count,
                eyeX: collected.reduce(0) { $0 + $1.eyeX } / count,
                eyeY: collected.reduce(0) { $0 + $1.eyeY } / count)
            references.append(GazeReference(display: display, sample: mean))
            debugLog(String(format: "calibration recorded display %u from %d frames: head %.3f/%.3f eye %.3f/%.3f",
                            display, collected.count, mean.headX, mean.headY, mean.eyeX, mean.eyeY))
        }
        index += 1
        advance()
    }

    private func finish(save: Bool) {
        guard running else { return }
        stepTimer?.invalidate()
        stepTimer = nil
        watchdog?.invalidate()
        watchdog = nil
        collecting = false
        running = false

        GazeTracker.shared.onRawSample = nil
        GazeTracker.shared.stopSoon()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        for window in windows { window.orderOut(nil) }
        windows = []
        views = [:]

        var saved = false
        // Every display needs at least one reading, or the ones that got none
        // could never win and their windows would be unreachable.
        let covered = Set(references.map(\.display))
        let expected = Set(NSScreen.screens.map { displayID(of: $0) })
        if save, !references.isEmpty, covered == expected {
            Settings.shared.gazeProfile = GazeProfile(references: references)
            Settings.shared.gazeCalibrationArrangement = screenArrangementFingerprint()
            saved = true
            log("gaze: calibrated on \(references.count) readings across \(covered.count) displays")
        } else if save {
            log("gaze: calibration incomplete, no face seen on \(expected.subtracting(covered).count) display(s)")
        } else {
            log("gaze: calibration cancelled")
        }

        GazeFocus.shared.resume()
        onFinish?(saved)
        onFinish = nil
    }

    // MARK: Windows

    private func buildWindows() {
        for screen in NSScreen.screens {
            let window = NSWindow(contentRect: screen.frame,
                                  styleMask: .borderless,
                                  backing: .buffered,
                                  defer: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
            window.setFrame(screen.frame, display: false)

            let view = CalibrationView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.onClick = { [weak self] in self?.finish(save: false) }
            window.contentView = view
            window.orderFrontRegardless()

            windows.append(window)
            views[displayID(of: screen)] = view
        }
    }

    /// The dot lives in AX coordinates; each view draws in its own screen's
    /// flipped, screen-local space.
    private func show(target: CGPoint, progress: Double) {
        let screen = nearestScreen(to: target)
        let identifier = displayID(of: screen)
        let screenRect = flipRect(screen.frame)
        let local = CGPoint(x: target.x - screenRect.minX,
                            y: target.y - screenRect.minY)

        for (key, view) in views {
            view.progress = progress
            view.target = key == identifier ? local : nil
            view.needsDisplay = true
        }
    }

    private func installCancelMonitor() {
        // Accessibility is already granted, so a global key monitor works
        // without an event tap of our own. Clicking anywhere cancels too, which
        // is the path that still works if Secure Input is up.
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.finish(save: false) }
        }
    }
}

/// Dimmed backdrop with a target dot. Coordinates are top-left origin to match
/// the AX space everything else in Shiftly works in.
final class CalibrationView: NSView {
    var target: CGPoint?
    var progress: Double = 0
    var onClick: (() -> Void)?

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.72).setFill()
        bounds.fill()

        let accent = Settings.shared.overlayColor

        if let target {
            let outer = NSRect(x: target.x - 22, y: target.y - 22, width: 44, height: 44)
            accent.withAlphaComponent(0.25).setFill()
            NSBezierPath(ovalIn: outer).fill()

            let inner = NSRect(x: target.x - 7, y: target.y - 7, width: 14, height: 14)
            accent.setFill()
            NSBezierPath(ovalIn: inner).fill()

            let ring = NSBezierPath(ovalIn: outer.insetBy(dx: -6, dy: -6))
            ring.lineWidth = 2
            accent.withAlphaComponent(0.7).setStroke()
            ring.stroke()
        }

        let hint = target == nil
            ? "Calibrating on another display…"
            : "Look at the dot. Esc or click to cancel."
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 17, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.85),
        ]
        let size = hint.size(withAttributes: attributes)
        hint.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: bounds.height - 90),
                  withAttributes: attributes)

        let barWidth = min(bounds.width * 0.3, 320.0)
        let bar = NSRect(x: (bounds.width - barWidth) / 2, y: bounds.height - 56, width: barWidth, height: 4)
        NSColor.white.withAlphaComponent(0.2).setFill()
        NSBezierPath(roundedRect: bar, xRadius: 2, yRadius: 2).fill()
        var filled = bar
        filled.size.width = bar.width * CGFloat(min(max(progress, 0), 1))
        accent.setFill()
        NSBezierPath(roundedRect: filled, xRadius: 2, yRadius: 2).fill()
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}
