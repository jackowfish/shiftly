// Live check for setFrame: moves an invisible test window between every pair of
// displays and reads the frame back. It never touches your own windows.
//
// Run with ./tools/axcheck.sh. It needs Accessibility for the terminal and two displays.
import AppKit
import ApplicationServices

func log(_ message: String) { print(message) }
func debugLog(_ message: @autoclosure () -> String) {}

/// Host mode: show one transparent, click-through window that never takes focus.
func runHost() -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 900, height: 700),
                          styleMask: [.titled, .resizable, .closable, .miniaturizable],
                          backing: .buffered, defer: false)
    window.alphaValue = 0
    window.ignoresMouseEvents = true
    window.hasShadow = false
    window.orderFrontRegardless()
    app.run()
    exit(0)
}

func wait(_ seconds: TimeInterval) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
}

func hostWindow(pid: pid_t) -> AXUIElement? {
    let app = AXUIElementCreateApplication(pid)
    for _ in 0..<40 {
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
           let window = (value as? [AXUIElement])?.first {
            return window
        }
        wait(0.1)
    }
    return nil
}

/// Slots on a display, taken from the same Placement logic the gestures use.
func targets(on index: Int, screens: [SnapScreen]) -> [(String, CGRect)] {
    let area = screens[index].area
    let seed = CGRect(x: area.midX - 200, y: area.midY - 150, width: 400, height: 300)
    let gestures: [(String, [(Layer, Direction)])] = [
        ("maximize", [(.halves, .up)]),
        ("left half", [(.halves, .left)]),
        ("top-right quarter", [(.halves, .right), (.halves, .up)]),
        ("top half", [(.halves, .up), (.halves, .up)]),
        ("first third", [(.thirds, .left)]),
        ("first-third sixth", [(.thirds, .left), (.thirds, .down)]),
        ("last third", [(.thirds, .right)]),
        ("last-third sixth", [(.thirds, .right), (.thirds, .right), (.thirds, .left), (.thirds, .left), (.thirds, .up)]),
    ]
    return gestures.map { name, steps in
        var placement = Placement(window: seed, layer: steps[0].0, screens: screens)
        for (layer, direction) in steps { placement.press(direction, layer: layer) }
        return (name, placement.preview.integral)
    }
}

if CommandLine.arguments.contains("--host") { runHost() }

guard AXIsProcessTrusted() else {
    print("skip: this terminal has no Accessibility permission")
    exit(0)
}
let screens = snapScreens()
guard screens.count >= 2 else {
    print("skip: needs two displays, found \(screens.count)")
    exit(0)
}

let host = Process()
host.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
host.arguments = ["--host"]
try host.run()

/// Top-level `defer` does not run before `exit`, and a live host keeps the output pipe open.
func finish(_ code: Int32) -> Never {
    host.terminate()
    host.waitUntilExit()
    exit(code)
}

guard let window = hostWindow(pid: host.processIdentifier) else {
    print("FAIL: the test window never appeared")
    finish(1)
}

var failures = 0
var total = 0
for source in screens.indices {
    let starts = targets(on: source, screens: screens)
    for destination in screens.indices where destination != source {
        for (startName, start) in starts {
            for (name, target) in targets(on: destination, screens: screens) {
                setFrame(start, on: window)
                wait(0.25)
                setFrame(target, on: window)
                wait(0.35)
                total += 1
                let actual = frame(of: window) ?? .null
                if !actual.matches(target, tolerance: 2) {
                    failures += 1
                    print("FAIL display \(source) \(startName) -> display \(destination) \(name): want \(target), got \(actual)")
                }
            }
        }
    }
}
print("\(total - failures)/\(total) cross-display moves landed")
finish(failures == 0 ? 0 : 1)
