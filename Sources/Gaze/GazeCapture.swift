import AppKit

/// Writes every frame a calibration saw to a CSV, labelled with the display and
/// point that was on screen at the time.
///
/// This exists so the classifier can be worked on offline. Tuning by feel needs a
/// person, a rebuild and a fresh opinion per change, which is slow enough that it
/// mostly gets guessed at instead; a labelled capture makes it a scoring problem.
/// `tools/gaze_eval.py` replays these. Files accumulate in
/// ~/Library/Logs/Shiftly-gaze/, so a change can be tested against sessions it
/// was not tuned on - which is the only way to catch a fit that flatters itself.
enum GazeCapture {
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Shiftly-gaze", isDirectory: true)
    }

    /// One capture in progress. Rows are buffered and written on close, since a
    /// calibration is short and a partial file is more confusing than none.
    final class Session {
        private var rows: [String] = []
        private let started = Date()

        init() {
            // v2 added lidY and changed what eyeY means: it now divides by eye
            // width, not eye height. v3 adds Vision's own head pose. v4
            // adds the corner-anchored per-eye pupil reads and the face box.
            // The harness keys off the version, because mixing the two eyeY
            // definitions in one training set would compare angles measured
            // against different rulers.
            rows.append("# shiftly gaze capture v4")
            rows.append("# arrangement=\(screenArrangementFingerprint())")
            rows.append("t,display,targetX,targetY,style," + GazeSample.names.joined(separator: ","))
        }

        func add(_ sample: GazeSample, display: CGDirectDisplayID, point: CGPoint,
                 style: GazeCalibrationStyle, at time: TimeInterval) {
            let axes = GazeSample.axes.map { String(format: "%.6f", sample[keyPath: $0]) }
            rows.append(String(format: "%.3f,%u,%.1f,%.1f,%@,", time, display, point.x, point.y, style.name)
                + axes.joined(separator: ","))
        }

        /// Returns the file written, or nil if there was nothing worth keeping.
        @discardableResult
        func close() -> URL? {
            // Three header lines and nothing else means every target missed.
            guard rows.count > 3 else { return nil }

            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd-HHmmss"
            let url = directory.appendingPathComponent("\(formatter.string(from: started)).csv")
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try (rows.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
                log("gaze: capture written to \(url.path) (\(rows.count - 3) frames)")
                return url
            } catch {
                log("gaze: could not write capture: \(error.localizedDescription)")
                return nil
            }
        }
    }
}
