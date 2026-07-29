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

Off by default, under Eye Tracking in the menu bar item. It doesn't add a gesture. It changes which window the gestures above start on: hold your usual modifier, look at another display, and the first arrow press grabs the frontmost window over there instead of whatever was frontmost before.

Nothing steals focus on its own. The camera warms while a Shiftly modifier is down and the estimate updates in the background, but focus only moves when an arrow actually lands and a gesture begins. That's what makes it safe to key off Cmd, which you're also holding for Cmd+C and Cmd+Tab all day. Glancing at another monitor during those does nothing.

On a single display it's inert, and it stays inert whenever you're already looking at the display that owns the focused window, so it only ever fires on a genuine cross-display switch.

### How it sees

Front camera plus Vision's face landmarks, all on device, nothing recorded or sent anywhere. Head rotation comes from nose position relative to the eye line rather than Vision's `yaw`, whose sign convention is undocumented and flips with mirroring.

The only question asked of the estimate is which display, a tens-of-degrees signal that's the forgiving end of what a webcam resolves, with a six-frame hold and a deadband so a flicker at a screen edge can't retarget you. The pupils still matter because a camera on the centre display can't see your head turn far enough to face an outer monitor; the eyes make up the angle the head didn't travel.

The camera runs while a modifier that could still become a gesture is held, and lingers 20 seconds after, so it's warm through a burst of window management and off when you stop. "Keep camera warm" pins it on for instant response at the cost of the green light. A gesture that beats the warmup falls back to normal focus rather than acting on a stale reading.

### Calibration

Uncalibrated it runs on guessed constants for an average face at an average desk, usually enough to tell two or three displays apart. Calibrate walks a dot around each screen for about a second and a half per stop and fits the mapping to you, which also settles your vertical baseline and the sign of the horizontal axis. If you skip it and it comes out mirrored, Flip Horizontal fixes it; calibrating supersedes both flips.

Recalibrate after changing your display arrangement. The menu tells you when the saved calibration was fitted against a different one.

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
