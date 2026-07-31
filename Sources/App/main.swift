import AppKit

// Shiftly - keyboard window snapping via Carbon hot keys and the
// Accessibility API, immune to stuck Secure Input. See README.md.

let logURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/Shiftly.log")

func log(_ message: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    let line = "\(stamp) \(message)\n"
    if let handle = try? FileHandle(forWritingTo: logURL) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        try? handle.close()
    } else {
        try? Data(line.utf8).write(to: logURL)
    }
}

/// Verbose tracing, off unless Debug Logging is on in the menu. The message is
/// an autoclosure because some of these sit on the 30fps sample path and would
/// otherwise build strings nobody reads.
func debugLog(_ message: @autoclosure () -> String) {
    guard Settings.shared.debugLogging else { return }
    log("debug: \(message())")
}

/// Timers on the gaze paths run in `.common` so menu tracking or a mouse drag
/// cannot stall a sequence that is meant to advance on its own.
func scheduleTimer(after interval: TimeInterval,
                   repeats: Bool = false,
                   _ action: @escaping () -> Void) -> Timer {
    let timer = Timer(timeInterval: interval, repeats: repeats) { _ in action() }
    RunLoop.main.add(timer, forMode: .common)
    return timer
}

let application = NSApplication.shared
let appDelegate = AppDelegate()
application.delegate = appDelegate
application.setActivationPolicy(.accessory)
application.run()
