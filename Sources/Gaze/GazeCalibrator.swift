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
    private var targets: [(point: CGPoint, display: CGDirectDisplayID, style: GazeCalibrationStyle)] = []
    private var references: [GazeReference] = []
    private var collected: [GazeSample] = []
    /// Per-axis jitter measured inside each burst, which is the measurement
    /// noise the classifier scales distances by.
    private var noise: [GazeSample] = []
    private var capture: GazeCapture.Session?
    private var index = 0
    /// Counting in to the next group, and the target index already counted in
    /// for, so finishing a countdown doesn't immediately start another.
    private var countdown = 0
    private var countedIn = -1
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
        noise = []
        capture = GazeCapture.Session()
        index = 0
        countdown = 0
        countedIn = -1

        // Style outermost, so each pass is one continuous instruction rather
        // than asking you to switch how you're sitting at every dot.
        targets = GazeCalibrationStyle.allCases.flatMap { style in
            NSScreen.screens.flatMap { screen -> [(CGPoint, CGDirectDisplayID, GazeCalibrationStyle)] in
                let area = usableFrame(of: screen)
                let identifier = displayID(of: screen)
                return gazeCalibrationTargets.map { fraction in
                    (CGPoint(x: area.minX + area.width * fraction.x,
                             y: area.minY + area.height * fraction.y), identifier, style)
                }
            }
        }

        buildWindows()
        installCancelMonitor()

        GazeTracker.shared.onSample = { [weak self] sample in
            guard let self, self.collecting, self.index < self.targets.count else { return }
            self.collected.append(sample)
            let target = self.targets[self.index]
            self.capture?.add(sample, display: target.display, point: target.point,
                              style: target.style, at: ProcessInfo.processInfo.systemUptime)
        }
        GazeTracker.shared.start()

        // Nothing here should ever be able to hang without saying so. If the
        // step chain stalls, this ends it and leaves a line in the log.
        let groups = GazeCalibrationStyle.allCases.count * NSScreen.screens.count
        let budget = Double(targets.count) * (gazeCalibrationSettle + gazeCalibrationCollect)
            + Double(groups * gazeCalibrationCountdown) * gazeCalibrationTick + 15
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

        // Count in whenever the run moves to another screen or into the second
        // pass. Without it the first dot of each group appears on a display you
        // may not be looking at yet, and its reading is whatever your eyes were
        // doing on the way there.
        let previous = index > 0 ? targets[index - 1] : nil
        let newGroup = previous.map { $0.display != target.display || $0.style != target.style } ?? true
        if newGroup && countedIn != index {
            if countdown == 0 { countdown = gazeCalibrationCountdown }
            showCountdown(on: target.display, style: target.style, remaining: countdown,
                          progress: Double(index) / Double(targets.count))
            stepTimer = scheduleTimer(after: gazeCalibrationTick) { [weak self] in
                guard let self, self.running else { return }
                self.countdown -= 1
                if self.countdown == 0 { self.countedIn = self.index }
                self.advance()
            }
            return
        }

        show(target: target.point, style: target.style, progress: Double(index) / Double(targets.count))
        debugLog("calibration target \(index + 1)/\(targets.count) [\(target.style.name)] on display \(target.display) at \(target.point)")

        // Settle first, then average a burst. Averaging across the settle would
        // bake in the travel from the previous dot.
        stepTimer = scheduleTimer(after: gazeCalibrationSettle) { [weak self] in
            guard let self, self.running else { return }
            self.collecting = true
            self.stepTimer = scheduleTimer(after: gazeCalibrationCollect) { [weak self] in
                guard let self, self.running else { return }
                self.record(display: target.display, point: target.point)
            }
        }
    }

    private func record(display: CGDirectDisplayID, point: CGPoint) {
        collecting = false
        if collected.isEmpty {
            log("gaze: no face seen while looking at display \(display)")
        } else {
            let count = Double(collected.count)
            let mean = GazeSample.perAxis { axis in
                collected.reduce(0) { $0 + $1[keyPath: axis] } / count
            }
            references.append(GazeReference(display: display, sample: mean, point: point))
            // The spread inside a single burst, while you held still on one dot,
            // is how precisely each axis can be measured at all. That's the
            // right scale for comparing readings; the spread *across* a
            // display's dots is where you looked, which is signal, not noise.
            noise.append(GazeSample.perAxis { axis in spread(collected.map { $0[keyPath: axis] }) })
            let readings = zip(GazeSample.names, GazeSample.axes)
                .map { String(format: "%@ %.3f", $0, mean[keyPath: $1]) }
                .joined(separator: " ")
            debugLog("calibration recorded display \(display) from \(collected.count) frames: \(readings)")
        }
        index += 1
        advance()
    }

    /// Median jitter per axis across every burst. Median rather than mean so a
    /// single burst where a blink wrecked the landmarks doesn't set the scale
    /// for the whole profile.
    private func pooledNoise() -> GazeSample? {
        guard !noise.isEmpty else { return nil }
        return GazeSample.perAxis { axis in
            let sorted = noise.map { $0[keyPath: axis] }.sorted()
            return sorted[sorted.count / 2]
        }
    }

    private func spread(_ values: [Double]) -> Double {
        guard values.count > 1 else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count - 1)
        return variance.squareRoot()
    }

    private func finish(save: Bool) {
        guard running else { return }
        stepTimer?.invalidate()
        stepTimer = nil
        watchdog?.invalidate()
        watchdog = nil
        collecting = false
        running = false

        GazeTracker.shared.onSample = nil
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
        capture?.close()
        capture = nil

        if save, !references.isEmpty, covered == expected {
            Settings.shared.gazeNoise = pooledNoise()
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
    /// Full-screen count-in on one display, blank on the others, so the screen
    /// showing numbers is the one to look at.
    private func showCountdown(on display: CGDirectDisplayID,
                               style: GazeCalibrationStyle,
                               remaining: Int,
                               progress: Double) {
        let name = NSScreen.screens.first { displayID(of: $0) == display }?.localizedName
        for (key, view) in views {
            view.progress = progress
            view.target = nil
            view.style = style
            view.countdown = key == display ? remaining : nil
            view.countdownTitle = key == display
                ? style.countdownTitle(for: name ?? "this display") : ""
            view.needsDisplay = true
        }
        debugLog("calibration counting in on display \(display) [\(style.name)]: \(remaining)")
    }

    private func show(target: CGPoint, style: GazeCalibrationStyle, progress: Double) {
        let screen = nearestScreen(to: target)
        let identifier = displayID(of: screen)
        let screenRect = flipRect(screen.frame)
        let local = CGPoint(x: target.x - screenRect.minX,
                            y: target.y - screenRect.minY)

        for (key, view) in views {
            view.style = style
            view.progress = progress
            view.countdown = nil
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
    var style: GazeCalibrationStyle = .still
    var countdown: Int?
    var countdownTitle = ""
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

        if let countdown {
            drawCentered("\(countdown)",
                         font: .systemFont(ofSize: 132, weight: .thin),
                         color: accent,
                         y: bounds.midY - 66)
            drawCentered(countdownTitle,
                         font: .systemFont(ofSize: 30, weight: .semibold),
                         color: .white,
                         y: bounds.midY - 150)
            drawWrapped(style.hint,
                        font: .systemFont(ofSize: 19, weight: .regular),
                        color: NSColor.white.withAlphaComponent(0.8),
                        y: bounds.midY + 100)
        }

        let hint: String
        if countdown != nil {
            hint = ""
        } else {
            hint = target == nil ? "Calibrating on another display…" : style.hint
        }
        drawWrapped(hint,
                    font: .systemFont(ofSize: 17, weight: .medium),
                    color: NSColor.white.withAlphaComponent(0.85),
                    y: bounds.height - 110)

        let barWidth = min(bounds.width * 0.3, 320.0)
        let bar = NSRect(x: (bounds.width - barWidth) / 2, y: bounds.height - 56, width: barWidth, height: 4)
        NSColor.white.withAlphaComponent(0.2).setFill()
        NSBezierPath(roundedRect: bar, xRadius: 2, yRadius: 2).fill()
        var filled = bar
        filled.size.width = bar.width * CGFloat(min(max(progress, 0), 1))
        accent.setFill()
        NSBezierPath(roundedRect: filled, xRadius: 2, yRadius: 2).fill()
    }

    private func drawCentered(_ text: String, font: NSFont, color: NSColor, y: CGFloat) {
        guard !text.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = text.size(withAttributes: attributes)
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: y), withAttributes: attributes)
    }

    /// Wrapped and centred inside a column, so an instruction long enough to say
    /// what it means still fits on a portrait display.
    private func drawWrapped(_ text: String, font: NSFont, color: NSColor, y: CGFloat) {
        guard !text.isEmpty else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineSpacing = 3
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: color, .paragraphStyle: paragraph,
        ]
        let width = min(bounds.width - 80, 900.0)
        let box = NSRect(x: (bounds.width - width) / 2, y: y, width: width, height: 200)
        text.draw(with: box, options: [.usesLineFragmentOrigin], attributes: attributes)
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}
