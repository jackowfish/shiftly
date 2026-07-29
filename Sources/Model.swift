import AppKit
import Carbon.HIToolbox

enum Layer: CaseIterable {
    case halves, thirds, displays

    var settingsKey: String {
        switch self {
        case .halves: return "halvesMods"
        case .thirds: return "thirdsMods"
        case .displays: return "displaysMods"
        }
    }

    var menuTitle: String {
        switch self {
        case .halves: return "Halves & Quarters"
        case .thirds: return "Thirds & Sixths"
        case .displays: return "Displays"
        }
    }
}

enum Direction {
    case left, right, up, down
}

struct Binding {
    let keyCode: UInt32
    let modifiers: UInt32
    let layer: Layer
    let direction: Direction
    let label: String
}

/// Screen fraction a centered window occupies.
let centerScale: CGFloat = 2.0 / 3.0

/// Slack when deciding a window already sits in a snap position.
let slotTolerance: CGFloat = 12

/// Dangling gestures commit themselves after this long.
let gestureTimeout: TimeInterval = 10

/// Every choice includes Cmd: releasing Cmd is what commits a gesture.
let modifierChoices: [(title: String, mods: UInt32)] = [
    ("⌘", UInt32(cmdKey)),
    ("⌃⌘", UInt32(controlKey | cmdKey)),
    ("⌥⌘", UInt32(optionKey | cmdKey)),
    ("⇧⌘", UInt32(shiftKey | cmdKey)),
    ("⌃⌥⌘", UInt32(controlKey | optionKey | cmdKey)),
    ("⇧⌥⌘", UInt32(shiftKey | optionKey | cmdKey)),
    ("⌃⇧⌘", UInt32(controlKey | shiftKey | cmdKey)),
]

let animationChoices: [(title: String, duration: Double)] = [
    ("Off", 0),
    ("Fast", 0.08),
    ("Normal", 0.16),
    ("Slow", 0.28),
]

// MARK: - Gaze

/// Floor on an axis's measured within-display spread when weights are learned
/// from calibration, so an axis that happened to sit still for five readings
/// can't be handed an enormous weight.
let gazeAxisFloor = 0.02

/// Frames are averaged into an exponential moving average before use. Raw
/// landmarks jitter enough to flip the estimate across a display edge.
let gazeSmoothing = 0.25

/// The nearest display has to be at least this much closer than the runner-up
/// to count, and then has to hold that lead for this many frames.
///
/// The counter leaks rather than resetting: an ambiguous frame in the middle of
/// a glance takes one frame back off, instead of throwing away the evidence and
/// starting over. Hard resets made a genuine look across the desk take seconds,
/// because a single jittery frame anywhere in the run was enough to restart it.
let gazeMargin = 0.85
let gazeDisplayHold = 5

/// Modifier poll, used only to decide when to warm the camera. A flagsState
/// query, not an event tap, so Secure Input can't blind it.
///
/// The dwell exists because ⌘ is a prefix of the default layers and you press
/// it all day for Cmd+C and Cmd+Tab. Warming on every one of those left the
/// camera effectively always on. A real gesture holds it past the dwell; a
/// copy-paste doesn't.
let gazePoll: TimeInterval = 0.04
let gazeWarmDwell = 5

/// How long the camera stays up after the modifiers go, in on-demand mode.
let gazeCameraLinger: TimeInterval = 5

/// A gaze estimate older than this is thrown away rather than acted on, so a
/// gesture that beats the camera's warmup falls back to normal focus instead of
/// retargeting off a stale reading.
let gazeStaleAfter: TimeInterval = 1.0

/// Calibration targets per display, as fractions of its frame.
let gazeCalibrationTargets: [CGPoint] = [
    CGPoint(x: 0.12, y: 0.14),
    CGPoint(x: 0.88, y: 0.14),
    CGPoint(x: 0.50, y: 0.50),
    CGPoint(x: 0.12, y: 0.86),
    CGPoint(x: 0.88, y: 0.86),
]

let gazeCalibrationSettle: TimeInterval = 0.9
let gazeCalibrationCollect: TimeInterval = 0.7

let overlayColors: [(name: String, title: String, color: NSColor)] = [
    ("accent", "Accent", .controlAccentColor),
    ("blue", "Blue", .systemBlue),
    ("purple", "Purple", .systemPurple),
    ("pink", "Pink", .systemPink),
    ("red", "Red", .systemRed),
    ("orange", "Orange", .systemOrange),
    ("green", "Green", .systemGreen),
    ("mint", "Mint", .systemMint),
    ("graphite", "Graphite", .systemGray),
]
