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
| Eye tracking | Ctrl+Cmd | Off by default. Hold the chord and the placement rectangle follows wherever you're looking, across every display. Release to place. |

## Eye Tracking

Turn it on under Eye Tracking in the menu bar item. It uses the front camera with Vision's face landmarks, all on device, and nothing is recorded or sent anywhere. The camera runs only while the chord is held, so the green light tracks actual use (there's a "keep camera warm" option that trades that for a faster start).

Carbon can't register a hot key with no key in it, so this layer watches the chord by polling `CGEventSource.flagsState` instead. That's a state query rather than an event stream, same as the release detection the keyboard layers already use, so Secure Input can't blind it either.

Head rotation picks the display and head plus eyes pick the zone within it. Splitting it that way matters because the two are wildly different precision problems: which monitor you're facing is a tens-of-degrees signal that head pose alone gets right, while which sixth of that monitor is a few degrees and needs the pupils. Resolving in that order means eye noise can only cost you the wrong rectangle on the correct screen instead of throwing the window onto another display.

A single camera also can't see far enough to cover a wide desk on head pose alone. Turning far enough to face an outer monitor puts your face near the edge of what Vision will still track, and the pupil term is what makes up the angle your head didn't travel.

### Calibration

Uncalibrated it runs on guessed constants for an average face at an average desk, which lands the right display and roughly the right half of it. Calibrate walks a dot around each screen for about a second and a half per stop and fits the mapping to you, which also settles your vertical baseline and the sign of the horizontal axis. If you skip it and the tracking comes out mirrored, Flip Horizontal fixes it; calibrating supersedes both flips.

Recalibrate after changing your display arrangement. The menu tells you when the saved calibration was fitted against a different one.

### Notes

The chord has to be held for about a quarter second before a session arms, so app shortcuts on the same chord (Ctrl+Cmd+Space and friends) don't trigger one on the way past. Anything that holds those modifiers longer will still arm it, so pick a chord you don't otherwise lean on. Picking a chord already owned by a keyboard layer moves that layer out of the way automatically.

Gaze always previews into the placement rectangle, even with the placement window turned off for the keyboard layers, since driving a real window at frame rate fights every app that reflows on resize.

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
