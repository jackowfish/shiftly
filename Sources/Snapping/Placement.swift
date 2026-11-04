import CoreGraphics

/// A display as a gesture sees it, in AX coordinates.
struct SnapScreen: Equatable {
    /// Full frame, used to find the neighbour in a direction.
    let frame: CGRect
    /// The part of the display that windows snap into.
    let area: CGRect
}

/// The window server keeps every title bar below the menu bar line, on all displays.
/// A slot above that line is unreachable, so the area starts at the line.
func snapArea(visible: CGRect, menuBarBand: Range<CGFloat>) -> CGRect {
    guard menuBarBand.contains(visible.minY), visible.maxY > menuBarBand.upperBound else { return visible }
    return CGRect(x: visible.minX,
                  y: menuBarBand.upperBound,
                  width: visible.width,
                  height: visible.maxY - menuBarBand.upperBound)
}

extension CGRect {
    /// Mirror across the diagonal, so the column logic also works on rows.
    var transposed: CGRect {
        CGRect(x: minY, y: minX, width: height, height: width)
    }

    func matches(_ other: CGRect, tolerance: CGFloat = slotTolerance) -> Bool {
        abs(minX - other.minX) <= tolerance
            && abs(minY - other.minY) <= tolerance
            && abs(width - other.width) <= tolerance
            && abs(height - other.height) <= tolerance
    }
}

extension Direction {
    /// The same press after a `CGRect.transposed` swap of the axes.
    var transposed: Direction {
        switch self {
        case .left: return .up
        case .up: return .left
        case .right: return .down
        case .down: return .right
        }
    }
}

/// Index of the display that holds the centre of the rect, or the nearest one.
func screenIndex(containing rect: CGRect, in screens: [SnapScreen]) -> Int {
    let center = CGPoint(x: rect.midX, y: rect.midY)
    if let index = screens.firstIndex(where: { $0.frame.contains(center) }) { return index }
    let distances = screens.map { screen -> CGFloat in
        let dx = max(screen.frame.minX - center.x, 0, center.x - screen.frame.maxX)
        let dy = max(screen.frame.minY - center.y, 0, center.y - screen.frame.maxY)
        return hypot(dx, dy)
    }
    return distances.indices.min { distances[$0] < distances[$1] } ?? 0
}

/// Nearest display in a direction. Displays that overlap on the other axis win.
func adjacentScreen(from index: Int, direction: Direction, in screens: [SnapScreen]) -> Int? {
    let source = screens[index].frame

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

    let inDirection = screens.indices.filter { $0 != index && lies(screens[$0].frame) }
    let aligned = inDirection.filter { overlapsPerpendicular(screens[$0].frame) }
    let pool = aligned.isEmpty ? inDirection : aligned
    return pool.min { distance(screens[$0].frame) < distance(screens[$1].frame) }
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

/// A thirds slot, or its upper (`sixth` 1) or lower (`sixth` -1) half.
func thirdsRect(slot: Int, sixth: Int, in area: CGRect) -> CGRect {
    if slot == fullLeft || slot == fullRight { return area }
    let rect = thirdSlots[slot].rect(in: area)
    guard sixth != 0 else { return rect }
    return CGRect(x: rect.minX,
                  y: sixth > 0 ? rect.minY : rect.midY,
                  width: rect.width,
                  height: rect.height / 2)
}

func nearestSlot(_ window: CGRect, in area: CGRect) -> Int {
    let scored = thirdSlots.enumerated().map { index, slot -> (Int, CGFloat) in
        let rect = slot.rect(in: area)
        return (index, abs(rect.midX - window.midX) + abs(rect.width - window.width))
    }
    return scored.min { $0.1 < $1.1 }?.0 ?? 1
}

// MARK: - Placement

/// The pending placement of one gesture. It knows nothing of AX or AppKit, so tests can drive it.
struct Placement {
    let screens: [SnapScreen]
    /// Frame of the window when the gesture began. The commit compares against this.
    let start: CGRect
    /// Where the current layer began. Walking a ladder back to its start returns here.
    private(set) var original: CGRect
    private(set) var preview: CGRect
    private(set) var screen: Int
    private(set) var layer: Layer

    // Halves layer: a ladder per axis. horiz -1/0/1 = left/none/right;
    // vert 1 = maximize, 2 = top half, -1 = center, -2 = bottom half.
    // Both axes set gives a quarter.
    private var horiz = 0
    private var vert = 0

    /// The layer began on a snap position, so the ladder skips the "unsnap to itself" rung.
    private var seeded = false

    // Thirds layer: index into thirdSlots (or the endcaps) plus a top/bottom-half ladder.
    // On a portrait display the same ladder runs down the rows.
    private var slot: Int?
    private var sixth = 0

    init(window: CGRect, layer: Layer, screens: [SnapScreen]) {
        precondition(!screens.isEmpty, "a placement needs at least one display")
        self.screens = screens
        start = window
        original = window
        preview = window
        screen = screenIndex(containing: window, in: screens)
        self.layer = layer
        resetLayerState()
    }

    /// Applies one arrow press. Returns false when the press has no display to go to.
    @discardableResult
    mutating func press(_ direction: Direction, layer newLayer: Layer) -> Bool {
        if newLayer != layer {
            // Carry the pending placement across so layers compose.
            original = preview
            screen = screenIndex(containing: preview, in: screens)
            layer = newLayer
            resetLayerState()
        }

        let area = screens[screen].area
        switch layer {
        case .halves:
            stepHalves(direction, area: area)
        case .thirds:
            stepThirds(direction, area: area)
        case .displays:
            return stepDisplays(direction)
        }
        return true
    }

    private var isPortrait: Bool {
        let area = screens[screen].area
        return area.height > area.width
    }

    private mutating func resetLayerState() {
        horiz = 0
        vert = 0
        seeded = false
        slot = nil
        sixth = 0
        switch layer {
        case .halves: seedHalves()
        case .thirds: seedThirds()
        case .displays: break
        }
    }

    /// Start the ladder from the window's current snap position, if it is in one.
    private mutating func seedHalves() {
        let area = screens[screen].area
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
        for position in positions where position.rect.matches(original) {
            horiz = position.h
            vert = position.v
            seeded = true
            return
        }
    }

    /// Start the thirds ladder from the slot or sixth the window is already in.
    private mutating func seedThirds() {
        let portrait = isPortrait
        let space = portrait ? screens[screen].area.transposed : screens[screen].area
        let window = portrait ? original.transposed : original
        for index in thirdSlots.indices {
            for half in [0, 1, -1] where thirdsRect(slot: index, sixth: half, in: space).matches(window) {
                slot = index
                sixth = half
                return
            }
        }
    }

    // Every press changes something: pushing into a fully covered edge goes
    // fullscreen, a quarter pushed into its own edge flattens to that half,
    // quarters walk across to their sibling, and maximize/center plus a
    // horizontal gives a half.
    private mutating func stepHalves(_ direction: Direction, area: CGRect) {
        switch direction {
        case .left, .right:
            let edge = direction == .left ? -1 : 1
            if horiz == edge {
                if vert == 0 { horiz = 0; vert = 1 } else { vert = 0 }
            } else {
                let fromCenterColumn = horiz == 0
                horiz += edge
                if horiz == 0 && (vert != 0 || seeded) { horiz += edge }
                horiz = min(1, max(-1, horiz))
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
                if vert == 2 { vert = 1 } else {
                    vert += 1
                    if vert == 0 && seeded { vert += 1 }
                    vert = min(2, vert)
                }
            } else {
                if vert == 1 { horiz = 0; vert = 2 } else { vert = min(1, vert + 1) }
            }
        case .down:
            if horiz == 0 {
                if vert == -2 { vert = 1 } else {
                    vert -= 1
                    if vert == 0 && seeded { vert -= 1 }
                    vert = max(-2, vert)
                }
            } else {
                if vert == -1 { horiz = 0; vert = -2 } else { vert = max(-1, vert - 1) }
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

    // A portrait display runs the ladder down the rows, so its sixths come out close to square.
    // The column logic does the work on a transposed copy of the display.
    private mutating func stepThirds(_ direction: Direction, area: CGRect) {
        let portrait = isPortrait
        let space = portrait ? area.transposed : area
        let window = portrait ? original.transposed : original
        let way = portrait ? direction.transposed : direction

        switch way {
        case .left, .right:
            let delta = way == .left ? -1 : 1
            if let current = slot {
                var next = current + delta
                // Endcaps need the edge fully covered; a sixth does not qualify.
                if (next == fullLeft || next == fullRight) && sixth != 0 { next = current }
                slot = min(fullRight, max(fullLeft, next))
            } else {
                slot = way == .left ? 0 : thirdSlots.count - 1
            }
        case .up, .down:
            if slot == nil { slot = nearestSlot(window, in: space) }
            if slot != fullLeft && slot != fullRight {
                sixth = way == .up ? min(1, sixth + 1) : max(-1, sixth - 1)
            }
        }

        let rect = thirdsRect(slot: slot ?? 0, sixth: sixth, in: space)
        preview = portrait ? rect.transposed : rect
    }

    private mutating func stepDisplays(_ direction: Direction) -> Bool {
        guard let destination = adjacentScreen(from: screen, direction: direction, in: screens) else {
            return false
        }
        preview = proportionalRect(preview, from: screens[screen].area, to: screens[destination].area)
        screen = destination
        return true
    }
}
