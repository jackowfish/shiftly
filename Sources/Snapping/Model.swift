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
/// cannot be handed an enormous weight.
let gazeAxisFloor = 0.02

/// The nearest display has to be at least this much closer than the runner-up
/// to count. Anything closer than that leaves focus where it is.
let gazeMargin = 0.85

/// The decision is made at the instant a key is pressed, from the newest frames
/// only, not from a running estimate that has to settle first.
///
/// This is the whole latency budget. An earlier version smoothed frames into a
/// moving average and made the winner hold a lead before it counted, stacking
/// two lags and turning a deliberate glance into a multi-second wait. Nothing
/// acts on the estimate continuously, so the damping bought nothing: the only
/// moment the answer matters is the press.
///
/// Median, not mean, because a median tracks a step as soon as most of
/// its window is past it while still discarding one bad landmark fit.
let gazeDecisionFrames = 3
let gazeDecisionWindow: TimeInterval = 0.4

/// Frames kept for the press-time decision to draw from.
let gazeHistoryWindow: TimeInterval = 1.0

/// How far inside a window the estimate has to land before that window is taken
/// as the one you mean, capped at a fifth of the window so small ones stay
/// reachable.
///
/// Webcam gaze is good to a few degrees, a couple of hundred pixels at desk
/// distance, so a dot near the seam between two windows carries no real opinion
/// about which side it is on. Requiring it properly inside trades a few "did
/// nothing" presses for not flipping as you read along a shared edge.
let gazeWindowInset: CGFloat = 80

/// Clicking a display says plainly which screen you mean, so it outranks gaze
/// for a moment afterwards. The escape hatch for a reading that disagrees with
/// you: click the screen you want and it does what you said.
let gazeClickOverride: TimeInterval = 2.0

/// Ridge penalty for the quadratic placement fit, scaled by the reading count.
/// Swept offline against held-out sessions; anything within a decade of this
/// scores the same, so it is not delicate.
let gazeRidgeLambda = 0.01

/// Calibration runs kept in the profile, newest first. Pooling runs is worth
/// more than any model change measured so far - each run samples a different
/// sitting posture, and a fit that has seen only one mistakes it for the truth
/// - but a run from months ago can describe a desk that no longer exists.
let gazeSessionLimit = 6

/// Calibration burst frames whose eye aperture falls below this fraction of
/// the burst's median are dropped as blinks before averaging. Lids matter to
/// the fit - aperture is a real vertical signal - so the threshold sits well
/// under the range normal looking produces.
let gazeBlinkLidFraction = 0.7

/// A click teaches placement, since you look at what you click. Each accepted
/// click pairs the estimate with the click point, and an offset-and-gain
/// correction per display and axis is refit from the newest pairs. This is
/// what absorbs session drift - sitting differently today than when you
/// calibrated - which measured as half the placement error.
///
/// A pair is accepted only when the estimate is steady (the eye axes' spread
/// over the decision window within a few times their calibrated jitter - a
/// glance-away mid-click fails this) and the estimate lands near the click,
/// so a click made while genuinely looking elsewhere teaches nothing.
let gazeDriftAcceptRadius: CGFloat = 500
let gazeDriftSteadyFactor = 4.0
let gazeDriftPairLimit = 40
/// Offset needs a few pairs before it is trusted; gain also needs the pairs to
/// span a real fraction of the display, since a slope fitted to a cluster of
/// clicks in one corner extrapolates disaster across the rest of the screen.
let gazeDriftMinPairs = 4
let gazeDriftGainSpan = 0.15
let gazeDriftGainRange = 0.5...1.5

/// Cap on how long a window query to another app can block. These are
/// synchronous calls into processes that can be busy, and they run on the
/// press, so an app mid-beachball would otherwise stall the gesture.
let gazeAXTimeout: Float = 0.1

/// Modifier poll, used only to decide when to warm the camera. A flagsState
/// query, not an event tap, so Secure Input cannot blind it.
///
/// The dwell exists because ⌘ is a prefix of the default layers and you press
/// it all day for Cmd+C and Cmd+Tab. Warming on every one of those left the
/// camera effectively always on. A real gesture holds it past the dwell; a
/// copy-paste does not.
let gazePoll: TimeInterval = 0.04
let gazeWarmDwell = 5

/// How long the camera stays up after the modifiers go, in on-demand mode.
let gazeCameraLinger: TimeInterval = 5

/// Camera health. Undocking can kill the device behind a running session
/// without a disconnect notification ever matching it, leaving a session that
/// looks fine and delivers nothing - or frames of pure black - until relaunch.
/// A session with no frames for this long is torn down and rebuilt on the
/// current default camera.
let gazeCameraStallAfter: TimeInterval = 3

/// Mean sampled brightness (0...1) below which a frame counts as black, and
/// how many in a row mean the feed is dead, not the lens briefly
/// covered. A real camera in a dark room still auto-exposes well above this.
let gazeCameraBlackLevel = 0.03
let gazeCameraBlackFrames = 45

/// Floor between watchdog-triggered rebuilds, so a camera that is genuinely
/// covered or absent does not cycle the session and its light every few
/// seconds. Reconnect notifications bypass this: a returning camera is a
/// real event, not a retry.
let gazeCameraRetryEvery: TimeInterval = 10

/// A gaze estimate older than this is thrown away, not acted on, so a
/// gesture that beats the camera's warmup falls back to normal focus instead of
/// retargeting off a stale reading.
let gazeStaleAfter: TimeInterval = 1.0

/// Radius of the debug dot, and how long its trail of recent positions lasts.
let gazeDotRadius: CGFloat = 26
let gazeDotTrail = 12
let gazeDotRedraw: TimeInterval = 1.0 / 20

/// How often the menu's gaze readout retitles itself while the menu is open.
/// Fast enough to follow a glance, slow enough not to look like it is flickering.
let gazeStatusRefresh: TimeInterval = 0.2

/// Calibration runs twice, once holding your head still and once moving
/// naturally, and keeps both sets of readings.
///
/// Neither pass is enough on its own. Head-free teaches it that yaw is the
/// signal, so a glance without a head turn registers nothing. Still-only
/// inverts it: a head-free session replayed against a still-only profile puts
/// about a third of frames on the wrong display, because the head absorbs angle
/// the eyes were calibrated to cover. See tools/gaze_eval.py.
enum GazeCalibrationStyle: CaseIterable {
    case still, free

    /// Shown throughout the pass, including under the count-in.
    ///
    /// "For this whole pass" is deliberate: holding still within one screen and
    /// re-aiming at the next makes this a second copy of the free pass, and the
    /// eye-only extreme never gets recorded. So is "as far as is comfortable" -
    /// a reading taken at the limit of your eyes is one you will never reproduce.
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
    /// the screen, which is exactly what this pass must exclude.
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
/// Four corners can fit each axis from its own terms but cannot pay for the cross
/// terms or see any curvature, and two rows make the vertical fit a straight
/// line through two clusters with no third level to contradict it. That was
/// survivable while the job was picking a display and became the limit as soon
/// as it was picking a window: four corners scored 60.3% vertically on a
/// 3440x1440 screen, which is a coin flip. Nine dots costs twenty seconds more.
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
/// Without it the first dot of a group lands on a screen your eyes have not
/// reached yet, and its reading is whatever they did on the way there -
/// a bad reference that then gets matched against for the life of the profile.
/// It is also where the instruction for the pass gets read, since the two passes
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
