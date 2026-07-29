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

## Eye Tracking (Beta)

Off by default, under Eye Tracking (Beta) in the menu bar. It doesn't add a gesture, it changes which window the gestures above act on. Look at a window, hold your modifier, tap an arrow, and it grabs that one instead of whatever was frontmost. The window never has to be focused first.

It picks the target once, when the gesture opens, so glancing around while you adjust won't move it. It also only ever picks the window on top at that spot, and it does nothing at all when the estimate doesn't land clearly inside something.

Camera plus Vision's face landmarks, all on device, nothing recorded or sent anywhere. It reads your head angle from where your nose sits relative to your eye line, plus pupil offset and how open your eyelids are. The eyes matter because a webcam can't see your head turn far enough to face a monitor off to one side.

### Calibrating

Required, and it takes about a minute. A dot walks a 3x3 grid on each screen and you look at it, twice: once with your head facing straight ahead the whole time moving only your eyes, then once looking naturally. Both passes are needed because your head absorbs angle your eyes would otherwise cover. Recalibrate if you change your display arrangement - the menu tells you when it thinks you should.

### How well it works

Measured rather than guessed: two calibrations, fit on one and scored against the other. A point that doesn't land clearly inside a window does nothing instead of guessing, so there are three outcomes and only one of them costs you anything.

| slot | acts right | acts wrong | does nothing |
|---|---|---|---|
| half of a 3440x1440 | 68% | 3% | 29% |
| third of a 3440x1440 | 61% | 6% | 33% |
| sixth of a 3440x1440 | 48% | 10% | 42% |
| sixth of a 1692x3008 | 39% | 16% | 45% |

So it's good for grabbing one of the two or three windows you actually have open, and it gets shaky once the slots get small. A slot only has to beat the other windows that are really there, which is an easier problem than a full tiling.

Webcam gaze is good to about 3-4° of visual angle, a couple hundred pixels at desk distance, and that's the real ceiling here rather than the calibration - IR eye trackers get under 1°.

### When it's wrong

Click the display you want and that outranks gaze for a couple of seconds. **Show Gaze Dot** draws where it thinks you're looking, outlines the window it would pick, and says why it picked it (or why it declined).

Under Eye Tracking > Camera you can leave the camera always on, which is the default and keeps the estimate current, or start it only while you're holding a modifier, which keeps the light off at the cost of a fast gesture falling back to normal focus.

Every calibration dumps its raw frames to `~/Library/Logs/Shiftly-gaze/`, and `tools/gaze_eval.py` replays them to score a change instead of guessing at it. Run it as `tools/gaze_eval.py a.csv b.csv --placement` to fit on one calibration and test on another, which is the only way to tell a real improvement from a good sitting position. The code comments cover what else was tried and why it didn't make it.

## Install

```sh
git clone https://github.com/jackowfish/shiftly
cd shiftly
./build.sh
open build/Shiftly.app
```

Grant Accessibility when prompted (System Settings, Privacy & Security, Accessibility). Without it the app can see your keys but can't move anything.

The build signs with a `Shiftly Dev Signing` certificate if one exists in your keychain, and falls back to ad-hoc signing otherwise.

`build.sh` is what produces the app: SwiftPM can't assemble a `.app`, since that needs the Info.plist, the icon, the entitlements and a signature.

There's a `Package.swift` anyway, purely so editors resolve the module. Without it SourceKit analyses each file alone and reports every cross-file symbol as missing, which buries real diagnostics under hundreds of fake ones. `swift build` type-checks everything and gives you a bare binary; it just isn't the shippable artifact.

## Layout

```
Sources/App/        menu bar app, settings, updater
Sources/Snapping/   hotkeys, the gesture ladders, geometry, the overlay
Sources/Gaze/       camera, calibration, the profile, window targeting
tools/              gaze_eval.py and the calibration screenshot renderer
build.sh            assembles and signs the .app
Package.swift       for editors and `swift build`, not for shipping
```

## Settings

All settings are in the menu bar item. Currently thats per-layer modifier combos, placement rectangle color (or off entirely, which moves windows live on each press), animation speed, and the eye tracking options above. Settings persist across restarts.

## License

MIT
