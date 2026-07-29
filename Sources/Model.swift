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
        case .thirds: return "Thirds"
        case .displays: return "Displays"
        }
    }

    /// Arrows this layer answers to. The thirds layer used to sub-halve a slot
    /// on up and down, which is where sixths came from; it doesn't any more, so
    /// it has no use for the vertical arrows.
    ///
    /// Worth listing rather than ignoring the presses, because a bound hot key
    /// is taken from every other app on the machine whether this one acts on it
    /// or not. Not binding them hands ⌘⌥↑ and ⌘⌥↓ back.
    var directions: [Direction] {
        switch self {
        case .thirds: return [.left, .right]
        case .halves, .displays: return [.left, .right, .up, .down]
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

/// How far inside a window the estimate has to land before that window is taken
/// as the one you mean, capped at a fifth of the window so small ones stay
/// reachable.
///
/// Gaze from a webcam is good to a few degrees, which is a couple of hundred
/// pixels at desk distance, so a dot near the seam between two windows carries
/// no real opinion about which side it's on. Requiring it to be properly inside
/// trades a few "did nothing" presses for not flipping between two windows as
/// you read along their shared edge.
let gazeWindowInset: CGFloat = 80

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

    /// Shown throughout the pass, including under the count-in.
    ///
    /// The still pass says "for this whole pass" deliberately. Holding your head
    /// still only within one screen and then re-aiming it at the next makes the
    /// pass a second copy of the free one, and the eye-only extreme it exists to
    /// record never gets recorded. Reaching as far as is comfortable rather than
    /// straining is part of it too: a reading taken at the limit of how far your
    /// eyes will go is one you'll never reproduce while actually working.
    var hint: String {
        switch self {
        case .still:
            return "Keep your head facing straight ahead for this whole pass, "
                + "even when the dot moves to another screen. Move only your eyes, as far as is comfortable."
        case .free:
            return "Now look at the dot naturally, turning your head as much as you like."
        }
    }

    /// Heading over the count-in. The still pass must not say "look at" the way
    /// the free pass does, because that reads as an instruction to turn towards
    /// the screen, which is the one thing this pass is trying to exclude.
    func countdownTitle(for display: String) -> String {
        switch self {
        case .still: return "Eyes only to \(display), head stays put"
        case .free: return "Look at \(display)"
        }
    }

    var name: String {
        switch self {
        case .still: return "still"
        case .free: return "free"
        }
    }
}

/// Targets per display per pass, as fractions of its frame: a 3x3 grid.
///
/// It was four corners, which is enough to fit each axis of the dot from its own
/// terms but not enough to also fit the cross terms, nor to see any curvature.
/// Two rows in particular means the vertical fit is a straight line through two
/// clusters, with no third level able to contradict it.
///
/// That mattered once the target became picking a window rather than a display.
/// Measured on a real capture, four corners put the dot in the right half of a
/// 3440x1440 screen 96.9% of the time horizontally and 60.3% vertically, and
/// 60.3% is a coin flip. Nine dots is about twenty seconds more.
let gazeCalibrationTargets: [CGPoint] = [
    CGPoint(x: 0.12, y: 0.14), CGPoint(x: 0.50, y: 0.14), CGPoint(x: 0.88, y: 0.14),
    CGPoint(x: 0.12, y: 0.50), CGPoint(x: 0.50, y: 0.50), CGPoint(x: 0.88, y: 0.50),
    CGPoint(x: 0.12, y: 0.86), CGPoint(x: 0.50, y: 0.86), CGPoint(x: 0.88, y: 0.86),
]

/// Shortened alongside the move to nine dots, so more of the budget goes on
/// covering the screen and less on waiting at each spot. A saccade lands and
/// settles well inside 0.7s, and 0.6s of collection is still eighteen frames to
/// average.
let gazeCalibrationSettle: TimeInterval = 0.7
let gazeCalibrationCollect: TimeInterval = 0.6

/// Counted in on each display before its run of dots starts.
///
/// Without it the first dot of a group lands on a screen you may not be looking
/// at yet, and its reading is whatever your eyes were doing on the way there —
/// a bad reference that then gets matched against for the life of the profile.
/// It's also where the instruction for the pass gets read, since the two passes
/// ask you to sit differently.
let gazeCalibrationCountdown = 3
let gazeCalibrationTick: TimeInterval = 0.8

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
