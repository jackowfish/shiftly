import AppKit

// AppKit's origin is bottom-left, the Accessibility API's is top-left.
// flipRect converts between them (it's its own inverse).

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

/// Nearest display in a direction, preferring ones that overlap on the
/// perpendicular axis.
func adjacentScreen(from screen: NSScreen, direction: Direction) -> NSScreen? {
    let source = flipRect(screen.frame)
    let candidates = NSScreen.screens.filter { $0 !== screen }.map { ($0, flipRect($0.frame)) }

    func lies(_ rect: CGRect) -> Bool {
        switch direction {
        case .left: return rect.midX < source.midX
        case .right: return rect.midX > source.midX
        case .up: return rect.midY < source.midY
        case .down: return rect.midY > source.midY
        }
    }

    func overlapsPerpendicular(_ rect: CGRect) -> Bool {
        switch direction {
        case .left, .right: return rect.maxY > source.minY && rect.minY < source.maxY
        case .up, .down: return rect.maxX > source.minX && rect.minX < source.maxX
        }
    }

    func distance(_ rect: CGRect) -> CGFloat {
        hypot(rect.midX - source.midX, rect.midY - source.midY)
    }

    let inDirection = candidates.filter { lies($0.1) }
    let aligned = inDirection.filter { overlapsPerpendicular($0.1) }
    let pool = aligned.isEmpty ? inDirection : aligned
    return pool.min { distance($0.1) < distance($1.1) }?.0
}

/// Same relative position and size, on a different screen.
func proportionalRect(_ window: CGRect, from source: CGRect, to destination: CGRect) -> CGRect {
    guard source.width > 0, source.height > 0 else { return destination }

    let width = min(destination.width, destination.width * (window.width / source.width))
    let height = min(destination.height, destination.height * (window.height / source.height))
    let x = destination.minX + destination.width * ((window.minX - source.minX) / source.width)
    let y = destination.minY + destination.height * ((window.minY - source.minY) / source.height)

    return CGRect(x: min(max(destination.minX, x), destination.maxX - width),
                  y: min(max(destination.minY, y), destination.maxY - height),
                  width: width,
                  height: height)
}

// MARK: - Thirds ladder

/// The ladder the thirds layer walks: left 1/3, left 2/3, middle 1/3,
/// right 2/3, right 1/3. Off either end is fullscreen.
struct Slot {
    let x: CGFloat
    let width: CGFloat

    func rect(in area: CGRect) -> CGRect {
        CGRect(x: area.minX + x * area.width,
               y: area.minY,
               width: width * area.width,
               height: area.height)
    }
}

let thirdSlots = [
    Slot(x: 0, width: 1.0 / 3),
    Slot(x: 0, width: 2.0 / 3),
    Slot(x: 1.0 / 3, width: 1.0 / 3),
    Slot(x: 1.0 / 3, width: 2.0 / 3),
    Slot(x: 2.0 / 3, width: 1.0 / 3),
]

/// Fullscreen endcap pseudo-slots.
let fullLeft = -1
let fullRight = thirdSlots.count

/// Slot the window's full frame already matches, if any.
func matchingSlot(_ window: CGRect, in area: CGRect) -> Int? {
    for (index, slot) in thirdSlots.enumerated() {
        let rect = slot.rect(in: area)
        if abs(rect.minX - window.minX) <= slotTolerance,
           abs(rect.width - window.width) <= slotTolerance,
           abs(rect.minY - window.minY) <= slotTolerance,
           abs(rect.height - window.height) <= slotTolerance {
            return index
        }
    }
    return nil
}

func nearestSlot(_ window: CGRect, in area: CGRect) -> Int {
    let scored = thirdSlots.enumerated().map { index, slot -> (Int, CGFloat) in
        let rect = slot.rect(in: area)
        return (index, abs(rect.midX - window.midX) + abs(rect.width - window.width))
    }
    return scored.min { $0.1 < $1.1 }?.0 ?? 1
}
