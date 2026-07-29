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

/// The gaze layer's own key, kept out of `Layer` because it has no arrow
/// bindings: it's a modifier-only chord watched by polling.
let gazeSettingsKey = "gazeMods"

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

/// Chords offered for the gaze layer. Plain ⌘ is missing on purpose: nothing
/// commits this layer but the chord's own release, so a single common modifier
/// would arm it during every Cmd+Tab.
let gazeModifierChoices: [(title: String, mods: UInt32)] = [
    ("⌃⌘", UInt32(controlKey | cmdKey)),
    ("⌥⌘", UInt32(optionKey | cmdKey)),
    ("⇧⌘", UInt32(shiftKey | cmdKey)),
    ("⌃⌥", UInt32(controlKey | optionKey)),
    ("⌃⌥⌘", UInt32(controlKey | optionKey | cmdKey)),
    ("⇧⌥⌘", UInt32(shiftKey | optionKey | cmdKey)),
    ("⌃⇧⌘", UInt32(controlKey | shiftKey | cmdKey)),
]

/// How the gaze layer carves up whichever display you're facing.
let gazeGridChoices: [(title: String, columns: Int, rows: Int)] = [
    ("Halves (2 × 1)", 2, 1),
    ("Quarters (2 × 2)", 2, 2),
    ("Sixths (3 × 2)", 3, 2),
    ("Ninths (3 × 3)", 3, 3),
]

/// Weight on the pupil term. The head covers most of the angle to a side
/// display; the eyes cover the part it didn't travel.
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
/// landmarks jitter enough to strobe the overlay across a zone seam.
let gazeSmoothing = 0.25

/// A new zone has to win this many frames in a row, and the gaze point has to
/// clear this much of the zone's own size, before the overlay follows. Crossing
/// displays is held to a stricter version of both: a flicker there costs you a
/// whole screen rather than a neighbouring rectangle.
let gazeZoneHold = 3
let gazeScreenHold = 6
let gazeZoneDeadband: CGFloat = 0.12
let gazeScreenDeadband: CGFloat = 0.06

/// The chord poll runs whenever gaze is enabled. It's a flagsState query, not
/// an event tap, so Secure Input can't blind it.
///
/// Arming takes a deliberate hold, because plenty of apps bind a key to the
/// same chord and we can't see the keystroke to rule it out. ⌃⌘Space is down
/// and up well inside 240ms; a gaze gesture isn't. The camera starts at the
/// shorter count so its warmup runs during the dwell rather than after it.
let gazeChordPoll: TimeInterval = 0.04
let gazeChordPrewarm = 2
let gazeChordDebounce = 6

/// Dangling gaze sessions commit themselves after this long.
let gazeTimeout: TimeInterval = 15

/// How long the camera stays up after a session ends, when it isn't pinned warm.
let gazeCameraLinger: TimeInterval = 2.5

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
