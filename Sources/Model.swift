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

/// The nearest display has to be at least this much closer than the runner-up
/// to count. Anything closer than that leaves focus where it is.
let gazeMargin = 0.85

/// The decision is made at the instant a key is pressed, from the newest frames
/// only, rather than from a running estimate that has to settle first.
///
/// This is the whole latency budget. An earlier version smoothed every frame
/// into a moving average and then required the winner to hold a lead for
/// several frames before it counted, which stacked the smoothing lag on top of
/// the hold and made a deliberate glance take seconds to register. Nothing acts
/// on the estimate continuously, so none of that damping bought anything: the
/// only moment the answer matters is the moment of the press.
///
/// A median of the last few frames instead of a mean, because a median tracks a
/// step as soon as most of its window is past the step, while still throwing
/// out a single bad landmark fit.
let gazeDecisionFrames = 3
let gazeDecisionWindow: TimeInterval = 0.4

/// Frames kept for the press-time decision to draw from.
let gazeHistoryWindow: TimeInterval = 1.0

/// Clicking a display says plainly which screen you mean, so it outranks gaze
/// for a moment afterwards. The escape hatch for a reading that disagrees with
/// you: click the screen you want and it does what you said.
let gazeClickOverride: TimeInterval = 2.0

/// Cap on how long a window query to another app may block. These are
/// synchronous calls into processes that might be busy, and they run on the
/// press, so an app mid-beachball would otherwise stall the gesture.
let gazeAXTimeout: Float = 0.1

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

/// Radius of the debug dot, and how long its trail of recent positions lasts.
let gazeDotRadius: CGFloat = 26
let gazeDotTrail = 12
let gazeDotRedraw: TimeInterval = 1.0 / 20

/// How often the menu's gaze readout retitles itself while the menu is open.
/// Fast enough to follow a glance, slow enough not to look like it's flickering.
let gazeStatusRefresh: TimeInterval = 0.2

/// Calibration runs twice, once holding your head still and once moving
/// naturally, and keeps both sets of readings.
///
/// One pass isn't enough, and which single pass you pick doesn't rescue it.
/// Calibrating head-free teaches it that yaw is the signal, so a glance without
/// a head turn registers nothing, which is what the first version did. Doing
/// only the still pass inverts the problem: replaying a head-free session
/// against a still-only profile lands roughly a third of frames on the wrong
/// display, because the head absorbs angle the eyes were calibrated to cover.
/// Keeping both, and matching against individual readings rather than a
/// per-display average, handles either style. See tools/gaze_eval.py.
enum GazeCalibrationStyle: CaseIterable {
    case still, free

    var hint: String {
        switch self {
        case .still: return "Keep your head still. Move only your eyes to the dot."
        case .free: return "Now look at the dot naturally, turning your head."
        }
    }

    var name: String {
        switch self {
        case .still: return "still"
        case .free: return "free"
        }
    }
}

/// Targets per display per pass, as fractions of its frame. Four rather than
/// five only to keep two passes to about half a minute.
let gazeCalibrationTargets: [CGPoint] = [
    CGPoint(x: 0.12, y: 0.16),
    CGPoint(x: 0.88, y: 0.16),
    CGPoint(x: 0.12, y: 0.84),
    CGPoint(x: 0.88, y: 0.84),
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
