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

Off by default, under Eye Tracking in the menu bar item. It doesn't add a gesture. It changes which window the gestures above act on: hold your usual modifier, look at another display, and the next arrow press grabs the frontmost window over there instead of whatever was frontmost before.

That works mid-gesture too. Keep the modifier down, place a window, glance at the next display, and the following arrow hands off to a window there, committing whatever was pending on the one you left.

Nothing steals focus on its own. The camera warms while a Shiftly modifier is down and the estimate updates in the background, but focus only moves when an arrow actually lands and a gesture begins. That's what makes it safe to key off Cmd, which you're also holding for Cmd+C and Cmd+Tab all day. Glancing at another monitor during those does nothing.

On a single display it's inert, and it stays inert whenever you're already looking at the display that owns the focused window, so it only ever fires on a genuine cross-display switch.

### How it sees

Camera plus Vision's face landmarks, all on device, nothing recorded or sent anywhere. Head rotation comes from nose position relative to the eye line rather than Vision's `yaw`, whose sign convention is undocumented and flips with mirroring. The pupils matter too, because a camera on one display can't see your head turn far enough to face a monitor off to the side; the eyes make up the angle the head didn't travel.

Calibration records what each display measures like, and a reading is classified by whichever labelled reading it sits closest to. There's deliberately nothing to configure. An earlier version mapped face geometry onto desktop coordinates, which meant telling it which way round the camera was mounted, and that's where a "Flip Horizontal" control came from that nobody could be expected to interpret. Comparing against labelled readings makes mirroring, mounting, and how far you personally turn your head all fall out of the calibration for free.

How much each of the four measurements counts is learned from the calibration too: how far the displays sit apart on that axis, over how much it wobbles while you hold a single dot. The denominator is the subtle part. It used to be how much the axis varied across one display's dots, which quietly buried the pupil terms, because pupil position sweeps its whole range on every screen and so scored as the noisiest thing on offer. That produced a profile weighted almost entirely on head yaw, which is why the first version needed a real head turn before it noticed anything. Per-frame wobble instead separates "moves a lot because it's tracking something" from "moves a lot because it can't be pinned down".

A display has to win by a clear margin, or focus stays where it is.

### How fast

The answer is worked out when you press the key, from the newest few camera frames, not read off an estimate that's been running in the background. So the delay is one camera frame plus however long the app you're switching to takes to answer a window query, and there's no settling time to wait out.

That's a correction. The first version smoothed every frame into a moving average and then made the winner hold a lead for several frames before it counted, stacking one lag on the other and turning a deliberate glance into a multi-second wait. None of that damping was buying anything, because nothing acts on the estimate continuously: the only instant it matters is the press. It also gave the thing a memory, which is what made it feel stuck on the last display it picked. Deciding fresh each time removes the state that could get stuck at all.

The last few frames are combined with a median rather than an average, which follows a real move as soon as most of the window is past it while still discarding a single bad landmark fit.

### When it's wrong

Click the display you want. A click outranks gaze for a couple of seconds afterwards, so if a reading disagrees with you, saying so out loud wins.

**Show Gaze Dot** under Eye Tracking outlines the display a gesture would act on right now and draws roughly where on it you're looking, with the distances and the margin ratio underneath. The outline is the part that's actually decided; the dot interpolates between calibration points and is only good enough to show which way things lean. A dot on the wrong screen is the bug worth reporting. Calibrations recorded before this existed still work, they just can't place the dot until you recalibrate.

### Calibration

Required. Without labelled readings there's nothing to compare against, so the feature does nothing until you calibrate. A dot walks around each screen, about a second and a half per stop, and you look at it. Recalibrate after changing your display arrangement; the menu says when the saved calibration was recorded against a different one.

It goes round **twice**: once holding your head still and moving only your eyes, once looking naturally. Both passes are kept and matched against individually. One pass isn't enough and picking the "right" one doesn't save it, because the two styles put the same gaze in different places: the head absorbs angle the eyes would otherwise cover. Replaying a natural-movement session against a hold-still-only profile puts about a third of frames on the wrong display.

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
