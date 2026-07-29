<p align="center">
  <img src="assets/icon.png" width="160" alt="Shiftly icon">
</p>

# Shiftly

Keyboard window snapping I built for macOS that bypasses the Secure Input problems swish has.

Same workflow but keyboard driven here. You hold down a modifier key, tap arrow keys to move a window's placement (shown as a colored rectangle), release to move the window there. You have different modifiers for halves, quarters, thirds, sixths, and multi-display moves.

## Demo

https://github.com/user-attachments/assets/bc166245-b65a-4eed-aa4d-b076ffbe9108

## Why

Window managers like Swish and Rectangle read the keyboard through a CGEventTap. MacOS Secure Input, which a lot of apps grab via a password field, blinds event taps system-wide. This has recently become an issue as recently Electron apps have a habit of grabbing it and it breaks until we reboot.

Shiftly avoids the event tap entirely (but not w/o some drawbacks). 

Hotkeys come in through Carbon's `RegisterEventHotKey`, which WindowServer dispatches even while Secure Input is held (same mechanism that keeps Spotlight's Cmd+Space alive in a password field). Release detection polls `CGEventSource.flagsState`, a state query rather than an event stream, and window moves go through the Accessibility API. These all together lets us avoid the Secure Input problems. 

This _does_ mean that we are grabbing these modifier keys in essentially any context. You can change the modifers in the menu bar settings to avoid conflicts with other application keybindings if you'd like.

## Gestures

| Layer | Default | Arrows |
|---|---|---|
| Halves & quarters | Cmd | Left/Right snap to halves, Up maximizes, Down centers. Combine them for quarters - Left then Up and you get the top-left quarter. |
| Thirds & sixths | Cmd+Opt | Left/Right walk the window across the screen: left 1/3, left 2/3, middle 1/3, right 2/3, right 1/3. Up/Down will grab the upper or lower half of whatever slot you're in. |
| Displays | Cmd+Shift | Sends the window to the display in that direction, keeping its relative size and position. |

## Eye Tracking

Off by default, under Eye Tracking in the menu bar item. It doesn't add a gesture. It changes which window the gestures above act on: hold your usual modifier, look at the window you want, and the next arrow press grabs that one instead of whatever happened to be frontmost. The window never has to be focused first.

If the calibration can place a point on screen, the window under that point wins, which is what makes it work between two windows sitting side by side on one display. Failing that, looking at another display still takes the frontmost window over there.

That works mid-gesture too. Keep the modifier down, place a window, glance at the next one, and the following arrow hands off, committing whatever was pending on the window you left.

Nothing steals focus on its own. The camera warms while a Shiftly modifier is down and the estimate updates in the background, but focus only moves when an arrow actually lands and a gesture begins. That's what makes it safe to key off Cmd, which you're also holding for Cmd+C and Cmd+Tab all day. Glancing at another monitor during those does nothing.

It stays inert whenever the answer is the window you're already on, and whenever the estimate doesn't land clearly inside anything. Gaze from a webcam is good to a few degrees, which is a couple of hundred pixels at desk distance, so a point near the seam between two windows carries no real opinion about which side of it you meant. Requiring the point to be properly inside a window trades some presses that do nothing for not flipping between two windows as you read along their shared edge.

### How well it picks

Depends on how small the target is, and the honest answer is that it's measured rather than guessed. Replaying a real calibration through `tools/gaze_eval.py --placement` scores whether the dot lands in the right slot of a given layout:

| layout | display | slot size | column | row |
|---|---|---|---|---|
| halves | 3440x1440 | 1720x1440 | 96.9% | 100% |
| thirds | 3440x1440 | 1147x1440 | 96.9% | 100% |
| sixths | 3440x1440 | 1147x720 | 96.9% | 60.3% |
| sixths | 1692x3008 | 564x1504 | 68.5% | 100% |

So halves and thirds are comfortable, and sixths is not there yet. Which axis runs out first depends on the display rather than on the axis: the ultrawide fails on rows, the portrait one on columns, and both are just the axis whose slots got small. Since a slot only has to beat the *other windows actually open*, two or three windows on a screen is a much easier problem than a full six-way tiling, and that's the case it handles well today.

### How it sees

Camera plus Vision's face landmarks, all on device, nothing recorded or sent anywhere. Head rotation comes from nose position relative to the eye line rather than Vision's `yaw`, whose sign convention is undocumented and flips with mirroring. The pupils matter too, because a camera on one display can't see your head turn far enough to face a monitor off to the side; the eyes make up the angle the head didn't travel.

Five measurements per frame: head yaw and pitch, pupil offset horizontally and vertically, and how open your eyelids are. The last one is there because vertical is the axis that costs accuracy, and it's a reading that owes nothing to finding the pupil: your lids narrow as you look down, measured across the whole eye contour rather than from a single point inside a region a third as tall as it is wide. Both pupil offsets are now scaled by eye *width* as well. Vertical used to divide by eye height, which moves with the thing being measured, since the box shrinks exactly when the pupil drops. Eye width is set by the corners, which don't move when you look anywhere.

Calibration records what each display measures like, and a reading is classified by whichever labelled reading it sits closest to. There's deliberately nothing to configure. An earlier version mapped face geometry onto desktop coordinates, which meant telling it which way round the camera was mounted, and that's where a "Flip Horizontal" control came from that nobody could be expected to interpret. Comparing against labelled readings makes mirroring, mounting, and how far you personally turn your head all fall out of the calibration for free.

How much each of the four measurements counts is learned from the calibration too: how far the displays sit apart on that axis, over how much it wobbles while you hold a single dot. The denominator is the subtle part. It used to be how much the axis varied across one display's dots, which quietly buried the pupil terms, because pupil position sweeps its whole range on every screen and so scored as the noisiest thing on offer. That produced a profile weighted almost entirely on head yaw, which is why the first version needed a real head turn before it noticed anything. Per-frame wobble instead separates "moves a lot because it's tracking something" from "moves a lot because it can't be pinned down".

A display has to win by a clear margin, or focus stays where it is.

### How fast

The answer is worked out when you press the key, from the newest few camera frames, not read off an estimate that's been running in the background. So the delay is one camera frame plus however long the app you're switching to takes to answer a window query, and there's no settling time to wait out.

That's a correction. The first version smoothed every frame into a moving average and then made the winner hold a lead for several frames before it counted, stacking one lag on the other and turning a deliberate glance into a multi-second wait. None of that damping was buying anything, because nothing acts on the estimate continuously: the only instant it matters is the press. It also gave the thing a memory, which is what made it feel stuck on the last display it picked. Deciding fresh each time removes the state that could get stuck at all.

The last few frames are combined with a median rather than an average, which follows a real move as soon as most of the window is past it while still discarding a single bad landmark fit.

### When it's wrong

Click the display you want. A click outranks gaze for a couple of seconds afterwards, so if a reading disagrees with you, saying so out loud wins.

**Show Gaze Dot** under Eye Tracking outlines the display a gesture would act on, outlines the window it would pick within it, and draws roughly where on it you're looking, with the distances and the margin ratio underneath. The caption says whether the window was chosen by the dot or fell back to frontmost. A window outline on the wrong window is the bug worth reporting.

The dot is fitted separately from the display choice, and it has to be. The classifier scales each axis by how well it tells displays apart, which on a side-by-side desk puts vertical at about a quarter of horizontal, correctly, since vertical says nothing about which of two adjacent screens you're on. Drawing the dot through that same metric made it slide left and right while barely moving up or down: measured against held-out calibration dots, it covered 207px of vertical range where the real answer covered 788px. Placement instead takes each axis at face value and least-squares fits horizontal gaze from head yaw plus eye yaw, vertical from head pitch plus eye pitch, per display. That drops median error from 634x/653y px to 238x/387y px and tracks the full vertical range.

Where the calibration is big enough, each axis also picks up the other two as correction terms, since looking down does shift the horizontal reading a little. That needs the dots to pay for the parameters: at four per screen per pass, adding them helped one display and hurt the other, which is what overfitting looks like. Six per pass carries them, and a calibration recorded at four keeps the fit it was measured to be best at.

For scale, the resulting error is around 2.4° to 4.9° of visual angle, which is ordinary for a webcam without infrared illumination. Published appearance-based models land near 4° on the standard benchmark, and dedicated eye-tracking hardware gets under 1° by lighting your eyes with IR and watching the corneal reflection. So the dot's wobble is close to the method's floor rather than a calibration that needs redoing. It has 20x the margin it needs to pick between two displays, which is why the same recording classifies at 99.2%.

### Calibration

Required. Without labelled readings there's nothing to compare against, so the feature does nothing until you calibrate. A dot walks a three-by-three grid on each screen, a bit over a second per stop, and you look at it. Recalibrate after changing your display arrangement; the menu says when the saved calibration was recorded against a different one.

Three rows rather than two because a two-row grid gives the vertical fit a straight line through two clusters and no third level able to contradict it. That was survivable while the job was picking a display and became the limit as soon as it was picking a window.

It goes round **twice**: once with your head facing straight ahead, moving only your eyes, and once looking naturally. Both passes are kept and matched against individually. One pass isn't enough and picking the "right" one doesn't save it, because the two styles put the same gaze in different places: the head absorbs angle the eyes would otherwise cover. Replaying a natural-movement session against a hold-still-only profile puts about a third of frames on the wrong display.

In the first pass your head stays in **one** position for the whole thing, including when the dot crosses to another screen. Re-aiming it at each display makes the pass a second copy of the free one, and the eye-only extreme it exists to record never gets recorded. Reach as far as is comfortable rather than straining, since a reading taken at the limit of how far your eyes will go is one you'll never reproduce while actually working.

A calibration recorded before this release won't load, and the menu says so rather than going quiet. `eyeY` changed what it's measured against, so an old profile would parse cleanly and then send windows to the wrong place.

### Working on the classifier

Every calibration writes the raw frames it saw, labelled with the display and dot that was on screen, to `~/Library/Logs/Shiftly-gaze/`. `tools/gaze_eval.py` replays those through candidate metrics and scores each one on accuracy, how often it's confident enough to act, how often it's confidently wrong, and how many frames it lags a change of target.

That exists because tuning this by feel needs a person, a rebuild and a fresh opinion per change, which is slow enough that it mostly gets guessed at instead. Every claim above about which metric wins came out of that script, including the two-pass finding, which was caught replaying one style's session against the other's profile before it shipped.

The menu also shows which display it currently thinks you're looking at, which is the quickest way to tell whether it's working.

### Camera

Two modes, under Eye Tracking > Camera.

**Always on** (default) runs the camera the whole time eye tracking is enabled. The light stays on, and the estimate is always current. This is the only mode where a fast gesture is reliably retargeted.

**Only while holding a modifier** starts the camera after you've held a modifier long enough for it to be a gesture rather than a Cmd+C, and stops it five seconds after you let go. The dwell matters: Cmd is a prefix of the default layers and gets pressed constantly, so warming on every press left the camera on more or less permanently. In this mode a gesture that beats the camera starting falls back to normal focus rather than acting on a stale reading.

## Install

```sh
git clone https://github.com/jackowfish/shiftly
cd shiftly
./build.sh
open build/Shiftly.app
```

Grant Accessibility when prompted (System Settings, Privacy & Security, Accessibility). Without it the app can see your keys but can't move anything.

The build signs with a `Shiftly Dev Signing` certificate if one exists in your keychain, and falls back to ad-hoc signing otherwise.

## Settings

All settings are in the menu bar item. Currently thats per-layer modifier combos, placement rectangle color (or off entirely, which moves windows live on each press), animation speed, and the eye tracking options above. Settings persist across restarts.

## License

MIT
