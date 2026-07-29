// Renders the calibration screens to PNGs without running a calibration.
//
//   tools/render_calibration.sh /tmp/shots
//
// Named main.swift because Swift only allows top-level code in a file with that
// name; the tool is a script, not a class.
//
// Checking a layout change by calibrating for real means a 35-second takeover
// of every display, which is slow and hard to look at closely. This draws the
// same view offscreen at whatever size you like instead.
//
// Compiled against the app's sources with main.swift and AppDelegate.swift left
// out, so the few globals those own are redeclared here.

import AppKit

func log(_ message: String) {
    FileHandle.standardError.write(("log: " + message + "\n").data(using: .utf8)!)
}

func debugLog(_ message: @autoclosure () -> String) { log(message()) }

func scheduleTimer(after interval: TimeInterval,
                   repeats: Bool = false,
                   _ action: @escaping () -> Void) -> Timer {
    let timer = Timer(timeInterval: interval, repeats: repeats) { _ in action() }
    RunLoop.main.add(timer, forMode: .common)
    return timer
}

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
try? FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)

func shot(_ name: String, size: NSSize, configure: (CalibrationView) -> Void) {
    let view = CalibrationView(frame: NSRect(origin: .zero, size: size))
    configure(view)
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
    view.cacheDisplay(in: view.bounds, to: rep)
    guard let data = rep.representation(using: .png, properties: [:]) else { return }
    let url = URL(fileURLWithPath: output).appendingPathComponent(name)
    try? data.write(to: url)
    print(url.path)
}

// Both aspect ratios, since the layout has to hold on a wide screen and a tall one.
let wide = NSSize(width: 1720, height: 720)
let tall = NSSize(width: 846, height: 1504)

shot("countdown-wide.png", size: wide) {
    $0.countdown = 3
    $0.countdownTitle = "Look at DELL U3423WE"
    $0.style = .still
}
shot("countdown-tall.png", size: tall) {
    $0.countdown = 1
    $0.countdownTitle = "Look at LG HDR 4K"
    $0.style = .free
    $0.progress = 0.5
}
shot("dot-wide.png", size: wide) {
    $0.target = CGPoint(x: wide.width * 0.12, y: wide.height * 0.16)
    $0.style = .still
    $0.progress = 0.25
}
shot("waiting-tall.png", size: tall) {
    $0.style = .still
    $0.progress = 0.25
}
