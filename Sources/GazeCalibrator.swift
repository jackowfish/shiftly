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
    private var targets: [CGPoint] = []
    private var observations: [GazeObservation] = []
    private var collected: [GazeSample] = []
    private var index = 0
    private var collecting = false
    private var stepTimer: Timer?
    private var keyMonitor: Any?
    private var running = false
    private var onFinish: ((Bool) -> Void)?

    private init() {}

    func start(completion: ((Bool) -> Void)? = nil) {
        guard !running else { return }
        guard !NSScreen.screens.isEmpty else { return }
        running = true
        onFinish = completion

        GazeSession.shared.suspend()
        observations = []
        collected = []
        index = 0

        targets = NSScreen.screens.flatMap { screen -> [CGPoint] in
            let area = usableFrame(of: screen)
            return gazeCalibrationTargets.map { fraction in
                CGPoint(x: area.minX + area.width * fraction.x,
                        y: area.minY + area.height * fraction.y)
            }
        }

        buildWindows()
        installCancelMonitor()

        GazeTracker.shared.onRawSample = { [weak self] sample in
            guard let self, self.collecting else { return }
            self.collected.append(sample)
        }
        GazeTracker.shared.start()

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
        show(target: target, progress: Double(index) / Double(targets.count))

        // Settle first, then average a burst. Averaging across the settle would
        // bake in the travel from the previous dot.
        stepTimer = Timer.scheduledTimer(withTimeInterval: gazeCalibrationSettle, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.collecting = true
            self.stepTimer = Timer.scheduledTimer(withTimeInterval: gazeCalibrationCollect, repeats: false) { _ in
                self.record(target: target)
            }
        }
    }

    private func record(target: CGPoint) {
        collecting = false
        if !collected.isEmpty {
            let count = Double(collected.count)
            let mean = GazeSample(
                headX: collected.reduce(0) { $0 + $1.headX } / count,
                headY: collected.reduce(0) { $0 + $1.headY } / count,
                eyeX: collected.reduce(0) { $0 + $1.eyeX } / count,
                eyeY: collected.reduce(0) { $0 + $1.eyeY } / count)
            observations.append(GazeObservation(target: target, sample: mean))
        }
        index += 1
        advance()
    }

    private func finish(save: Bool) {
        stepTimer?.invalidate()
        stepTimer = nil
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
        if save, let maps = GazeFit.maps(from: observations) {
            Settings.shared.gazeHeadMap = maps.head
            Settings.shared.gazeFineMap = maps.fine
            Settings.shared.gazeCalibrationArrangement = screenArrangementFingerprint()
            saved = true
            log("gaze: calibrated on \(observations.count) points")
        } else if save {
            log("gaze: calibration failed to fit (\(observations.count) usable points)")
        } else {
            log("gaze: calibration cancelled")
        }

        GazeSession.shared.resume()
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
