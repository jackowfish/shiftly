import AppKit

/// A dot showing where the tracker currently thinks you are looking, plus the
/// numbers behind it. Purely a diagnostic: nothing reads it, and it changes
/// nothing about how gestures behave.
///
/// The dot is much rougher than the display choice it sits on. Calibration pins
/// the mapping down at a handful of points per screen and the dot interpolates
/// between them, so treat it as "leaning that way", not a cursor. Which
/// display it is on is the part that is actually decided, and the part worth
/// watching: if the dot sits on the wrong screen, that is the bug.
final class GazeDebugOverlay {
    static let shared = GazeDebugOverlay()

    private var windows: [CGDirectDisplayID: NSWindow] = [:]
    private var views: [CGDirectDisplayID: GazeDotView] = [:]
    private var trail: [CGPoint] = []
    private var lastDrawAt: TimeInterval = 0

    private init() {}

    /// Builds or tears down the windows to match the setting.
    func refresh() {
        let wanted = Settings.shared.gazeEnabled && Settings.shared.gazeDebugOverlay
        guard wanted else { return teardown() }

        // Rebuilt, not moved when the layout changes: they cost little,
        // and a stale frame would put the dot in the wrong place entirely.
        teardown()
        for screen in NSScreen.screens {
            let window = NSWindow(contentRect: screen.frame,
                                  styleMask: .borderless,
                                  backing: .buffered,
                                  defer: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.level = .screenSaver
            window.ignoresMouseEvents = true
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            window.setFrame(screen.frame, display: false)

            let view = GazeDotView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.screenRect = flipRect(screen.frame)
            window.contentView = view
            window.orderFrontRegardless()

            let identifier = displayID(of: screen)
            windows[identifier] = window
            views[identifier] = view
        }
        log("gaze: debug dot on")
    }

    /// Taken down while calibration owns the screens, so the two full-screen
    /// overlays do not draw over each other.
    func hide() {
        teardown()
    }

    private func teardown() {
        guard !windows.isEmpty else { return }
        for window in windows.values { window.orderOut(nil) }
        windows = [:]
        views = [:]
        trail = []
    }

    /// Called for every frame the camera resolves.
    func update() {
        guard !views.isEmpty else { return }
        // These windows are the size of the desktop, so a full redraw per frame
        // is real work. Throttled, because the thing being diagnosed here is
        // latency and a diagnostic that costs latency is no use.
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastDrawAt >= gazeDotRedraw else { return }
        lastDrawAt = now

        let profile = Settings.shared.gazeProfile
        let reading = GazeFocus.shared.reading()
        let chosen = GazeFocus.shared.gazedDisplay()
        // Asked without the display a gesture is currently on, so the overlay
        // shows what the estimate points at, not what a press would
        // change. Those differ whenever you are already on the right window, and
        // a diagnostic that goes blank when it agrees with you is no use.
        let window = GazeFocus.shared.gazedTarget()
        var point = reading.flatMap { profile?.point(for: $0) }
        // The fit is linear and will extrapolate past the edges when you look
        // beyond the outermost calibration dots. Pinned to the screen so it
        // rides the edge instead of disappearing, which would read as the
        // tracker having lost you.
        if let chosen, let estimate = point,
           let screen = NSScreen.screens.first(where: { displayID(of: $0) == chosen }) {
            let bounds = flipRect(screen.frame).insetBy(dx: gazeDotRadius, dy: gazeDotRadius)
            point = CGPoint(x: min(max(estimate.x, bounds.minX), bounds.maxX),
                            y: min(max(estimate.y, bounds.minY), bounds.maxY))
        }

        if let point {
            trail.append(point)
            if trail.count > gazeDotTrail { trail.removeFirst(trail.count - gazeDotTrail) }
        } else {
            trail = []
        }

        var caption = "no face"
        if let reading, let profile {
            let ranked = profile.ranking(for: reading)
            let scores = ranked.map { String(format: "%u %.2f", $0.display, $0.distance) }
                .joined(separator: "   ")
            // The ratio is the whole decision: below the margin it acts, above
            // it the two displays are too close to call and it leaves focus be.
            let ratio = ranked.count > 1 ? ranked[0].distance / max(ranked[1].distance, 0.0001) : 0
            // Two lines, not one. This used to be a single row that ran
            // wider than the display and got clipped at both ends, which took
            // out the window reason on the right and the display scores on the
            // left - the two things it exists to tell you.
            caption = String(format: "%@   ratio %.2f / %.2f   window: %@",
                             scores, ratio, gazeMargin, window.reason)
                + String(format: "\nhead %.2f/%.2f   eye %.2f/%.2f   lid %.2f   pose %.2f/%.2f/%.2f",
                         reading.headX, reading.headY, reading.eyeX, reading.eyeY,
                         reading.lidY, reading.faceYaw, reading.facePitch, reading.faceRoll)
            // A blank screen otherwise reads as a broken tracker, not an
            // old calibration that predates the dot having anywhere to go.
            if !profile.hasPoints {
                caption += "   (recalibrate to place the dot)"
            }
        } else if reading != nil {
            caption = "not calibrated"
        }

        for (identifier, view) in views {
            view.trail = identifier == chosen ? trail : []
            view.isChosen = identifier == chosen
            view.windowRect = window.pick?.display == identifier ? window.pick?.bounds : nil
            view.caption = caption
            view.needsDisplay = true
        }
    }
}

/// Draws in its own screen's flipped, screen-local space, matching the AX
/// coordinates the estimate arrives in.
final class GazeDotView: NSView {
    var screenRect = CGRect.zero
    var trail: [CGPoint] = []
    var isChosen = false
    /// The window a gesture would act on, in AX coordinates. Named around
    /// `NSView.window` instead of shadowing it.
    var windowRect: CGRect?
    var caption = ""

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let accent = Settings.shared.overlayColor

        // A border on the display that a gesture would act on right now, so the
        // answer is readable from the corner of your eye without finding the dot.
        if isChosen {
            let edge = NSBezierPath(rect: bounds.insetBy(dx: 3, dy: 3))
            edge.lineWidth = 6
            accent.withAlphaComponent(0.55).setStroke()
            edge.stroke()
        }

        // The window itself, which is the answer now that gaze picks between
        // windows on one screen, not only between screens.
        if let windowRect {
            let local = NSRect(x: windowRect.minX - screenRect.minX,
                               y: windowRect.minY - screenRect.minY,
                               width: windowRect.width, height: windowRect.height)
            let outline = NSBezierPath(roundedRect: local.insetBy(dx: 2, dy: 2), xRadius: 10, yRadius: 10)
            outline.lineWidth = 4
            accent.withAlphaComponent(0.9).setStroke()
            outline.stroke()
            accent.withAlphaComponent(0.10).setFill()
            outline.fill()
        }

        // Older positions fade out, which turns jitter into something you can
        // see the shape of, not a dot that twitches.
        for (index, point) in trail.enumerated() {
            let age = Double(index + 1) / Double(trail.count)
            let local = CGPoint(x: point.x - screenRect.minX, y: point.y - screenRect.minY)
            let radius = gazeDotRadius * CGFloat(0.35 + 0.65 * age)
            let dot = NSRect(x: local.x - radius, y: local.y - radius,
                             width: radius * 2, height: radius * 2)
            accent.withAlphaComponent(CGFloat(0.10 + 0.45 * age * age)).setFill()
            NSBezierPath(ovalIn: dot).fill()
        }

        if let last = trail.last {
            let local = CGPoint(x: last.x - screenRect.minX, y: last.y - screenRect.minY)
            let ring = NSBezierPath(ovalIn: NSRect(x: local.x - gazeDotRadius, y: local.y - gazeDotRadius,
                                                   width: gazeDotRadius * 2, height: gazeDotRadius * 2))
            ring.lineWidth = 2.5
            accent.setStroke()
            ring.stroke()
        }

        guard isChosen, !caption.isEmpty else { return }
        // Laid out in a bounded rect, not drawn at a point. Drawing at a
        // point puts everything on one line however wide that gets, and the box
        // was centred without a clamp, so on a narrow display the caption ran
        // off both edges at once and lost the two fields worth reading.
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph,
        ]
        let limit = max(bounds.width - 60, 200)
        let text = caption as NSString
        let measured = text.boundingRect(with: NSSize(width: limit, height: 400),
                                         options: [.usesLineFragmentOrigin],
                                         attributes: attributes)
        let box = NSRect(x: max((bounds.width - measured.width) / 2 - 10, 10), y: 24,
                         width: min(measured.width + 20, bounds.width - 20),
                         height: measured.height + 12)
        NSColor.black.withAlphaComponent(0.68).setFill()
        NSBezierPath(roundedRect: box, xRadius: 7, yRadius: 7).fill()
        text.draw(with: box.insetBy(dx: 10, dy: 6),
                  options: [.usesLineFragmentOrigin], attributes: attributes)
    }
}
