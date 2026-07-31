import AppKit

/// Checks GitHub releases for a newer version and self-updates: downloads
/// Shiftly.zip, then hands off to a detached shell that waits for this
/// process to exit, swaps the bundle in place, and relaunches it.
enum Updater {
    static let repo = "jackowfish/shiftly"

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    static func check() {
        let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
        URLSession.shared.dataTask(with: url) { data, _, error in
            DispatchQueue.main.async { handle(data: data, error: error) }
        }.resume()
    }

    private static func handle(data: Data?, error: Error?) {
        guard let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String
        else {
            alert("Couldn't check for updates",
                  error?.localizedDescription ?? "Unexpected response from GitHub.")
            return
        }

        let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard isNewer(latest, than: currentVersion) else {
            alert("You're up to date", "Shiftly \(currentVersion) is the latest version.")
            return
        }

        let assets = json["assets"] as? [[String: Any]] ?? []
        guard let zipString = assets
                .first(where: { ($0["name"] as? String) == "Shiftly.zip" })?["browser_download_url"] as? String,
              let zipURL = URL(string: zipString)
        else {
            alert("Update found", "Shiftly \(latest) is out, but the release has no Shiftly.zip asset.")
            return
        }

        if confirm("Shiftly \(latest) is available",
                   "You're running \(currentVersion). Update and relaunch?",
                   button: "Update") {
            download(zipURL, version: latest)
        }
    }

    private static func download(_ url: URL, version: String) {
        URLSession.shared.downloadTask(with: url) { temp, _, error in
            DispatchQueue.main.async {
                guard let temp else {
                    alert("Download failed", error?.localizedDescription ?? "No file received.")
                    return
                }
                unpack(temp, version: version)
            }
        }.resume()
    }

    private static func unpack(_ zip: URL, version: String) {
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("shiftly-update-\(version)")
        try? FileManager.default.removeItem(at: staging)

        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zip.path, staging.path]
        do {
            try ditto.run()
            ditto.waitUntilExit()
        } catch {
            alert("Couldn't unpack update", error.localizedDescription)
            return
        }

        let newApp = staging.appendingPathComponent("Shiftly.app")
        guard FileManager.default.fileExists(atPath: newApp.path) else {
            alert("Couldn't unpack update", "Shiftly.app missing from the downloaded archive.")
            return
        }
        install(newApp, staging: staging)
    }

    private static func install(_ newApp: URL, staging: URL) {
        let dest = Bundle.main.bundleURL

        // A quarantined app can run translocated from a read-only path that
        // cannot be replaced; fall back to revealing the download.
        if dest.path.contains("AppTranslocation") {
            NSWorkspace.shared.activateFileViewerSelecting([newApp])
            alert("Can't update in place",
                  "Shiftly is running from a translocated path. Drag the new Shiftly.app over your current copy manually.")
            return
        }

        // Wait for us to exit, swap the bundle, relaunch, clean up.
        let script = """
        while /bin/kill -0 "$1" 2>/dev/null; do /bin/sleep 0.2; done
        /bin/rm -rf "$3"
        /usr/bin/ditto "$2" "$3"
        /usr/bin/open "$3"
        /bin/rm -rf "$4"
        """
        let updater = Process()
        updater.executableURL = URL(fileURLWithPath: "/bin/sh")
        updater.arguments = ["-c", script, "shiftly-updater",
                             String(ProcessInfo.processInfo.processIdentifier),
                             newApp.path, dest.path, staging.path]
        do {
            try updater.run()
        } catch {
            alert("Couldn't start updater", error.localizedDescription)
            return
        }
        log("updating: replacing \(dest.path) and relaunching")
        NSApp.terminate(nil)
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private static func alert(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }

    private static func confirm(_ title: String, _ text: String, button: String) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
