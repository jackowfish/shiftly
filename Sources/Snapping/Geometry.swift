import AppKit

// AppKit's origin is bottom-left, the Accessibility API's is top-left.
// flipRect converts between them (it is its own inverse).

var primaryHeight: CGFloat {
    NSScreen.screens.first?.frame.height ?? 0
}

func flipRect(_ rect: CGRect) -> CGRect {
    CGRect(x: rect.minX,
           y: primaryHeight - rect.maxY,
           width: rect.width,
           height: rect.height)
}

/// Usable area (no menu bar / Dock) in AX coordinates.
func usableFrame(of screen: NSScreen) -> CGRect {
    flipRect(screen.visibleFrame)
}

func screenContaining(_ axRect: CGRect) -> NSScreen {
    let center = CGPoint(x: axRect.midX, y: axRect.midY)
    for screen in NSScreen.screens where flipRect(screen.frame).contains(center) {
        return screen
    }
    return NSScreen.main ?? NSScreen.screens[0]
}

/// Display containing the point, or the closest one if it lands in the gap
/// between two displays or off the end of the arrangement.
func nearestScreen(to point: CGPoint) -> NSScreen {
    var best = NSScreen.main ?? NSScreen.screens[0]
    var bestDistance = CGFloat.greatestFiniteMagnitude
    for screen in NSScreen.screens {
        let rect = flipRect(screen.frame)
        if rect.contains(point) { return screen }
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        let distance = hypot(dx, dy)
        if distance < bestDistance {
            bestDistance = distance
            best = screen
        }
    }
    return best
}

func displayID(of screen: NSScreen) -> CGDirectDisplayID {
    let key = NSDeviceDescriptionKey("NSScreenNumber")
    return (screen.deviceDescription[key] as? NSNumber)?.uint32Value ?? 0
}

/// Identity of the current display arrangement, so a calibration can tell the
/// user it was fitted against a different set of screens.
func screenArrangementFingerprint() -> String {
    NSScreen.screens
        .map { screen -> String in
            let rect = flipRect(screen.frame)
            return "\(displayID(of: screen)):\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height))"
        }
        .sorted()
        .joined(separator: "|")
}

/// Every display as the gesture engine sees it, primary first.
func snapScreens() -> [SnapScreen] {
    let screens = NSScreen.screens
    guard let primary = screens.first else { return [] }
    let primaryFrame = flipRect(primary.frame)
    let menuBarBand = primaryFrame.minY..<max(primaryFrame.minY, usableFrame(of: primary).minY)
    return screens.map { screen in
        SnapScreen(frame: flipRect(screen.frame),
                   area: snapArea(visible: usableFrame(of: screen), menuBarBand: menuBarBand))
    }
}
