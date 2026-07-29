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

/// Weight on the pupil term. The head covers most of the angle to a side
/// display; the eyes cover the part it didn't travel, which on a wide desk is
/// the part a single camera can't see the head make.
let gazeHeadWeight = 0.7
let gazeEyeWeight = 0.3

/// Uncalibrated fallbacks. `headXSpan` is the nose offset (in inter-ocular
/// widths) that reaches the edge of the desktop; `headYBias` is where a
/// relaxed face sits before anyone has looked anywhere in particular.
let gazeHeadXSpan = 0.30
let gazeHeadYSpan = 0.18
let gazeHeadYBias = 0.55
let gazeEyeSpan = 0.70

/// Frames are averaged into an exponential moving average before use. Raw
/// landmarks jitter enough to flip the estimate across a display edge.
let gazeSmoothing = 0.25

/// A display has to win this many frames in a row, and the gaze point has to
/// land this far inside it, before it counts as the one being looked at.
let gazeDisplayHold = 6
let gazeDisplayDeadband: CGFloat = 0.06

/// Modifier poll. A flagsState query, not an event tap, so Secure Input can't
/// blind it. It only warms the camera: nothing is focused until an arrow lands.
let gazePoll: TimeInterval = 0.04

/// How long the camera stays up after the modifiers go, when it isn't pinned
/// warm. Long enough to cover a burst of window management, short enough that
/// the light goes out when you stop.
let gazeCameraLinger: TimeInterval = 20

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
