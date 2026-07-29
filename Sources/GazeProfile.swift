import AppKit

/// One calibration reading: what the camera saw while you looked at a known
/// display, and the spot on it you were looking at.
///
/// The point is only ever used to draw the debug dot; which display you're on
/// is decided from the labels alone. Profiles saved before the point was
/// recorded load with it missing, so an old calibration still works and just
/// can't draw a dot.
struct GazeReference {
    let display: CGDirectDisplayID
    let sample: GazeSample
    var point: CGPoint?
}

/// What "looking at that display" measures like, learned from calibration.
///
/// This replaced a linear map from face geometry to desktop coordinates. That
/// map had to be told which way round the camera was mounted and how far a face
/// turns before it means anything, which is where the Flip Horizontal control
/// came from. Since the only question ever asked is which display, none of that
/// is needed: label a handful of readings per display and compare against them.
/// Mirroring, mounting, and how far you personally turn your head all fall out
/// of the labels for free, with nothing left for anyone to configure.
///
/// The axes are weighted by how well they actually separate the displays,
/// measured from the calibration readings themselves. On a side-by-side desk
/// that lands almost all the weight on head yaw and near none on the pupil
/// terms, which vary just as much within one display as between two and were
/// otherwise adding pure noise. Hand-picked weights couldn't know that; they
/// have to be wrong for either a stacked arrangement or a side-by-side one.
struct GazeProfile {
    let references: [GazeReference]

    /// Mean reading per display, and how much weight each axis has earned.
    private let centers: [CGDirectDisplayID: GazeSample]
    private let weights: GazeSample

    var displays: Set<CGDirectDisplayID> { Set(references.map(\.display)) }

    /// Every display and how far its centre is from this reading, nearest first.
    func ranking(for sample: GazeSample) -> [(display: CGDirectDisplayID, distance: Double)] {
        centers
            .map { (display: $0.key, distance: distance(sample, $0.value)) }
            .sorted { $0.distance < $1.distance }
    }

    /// The display being looked at, or nil when it's too close to call.
    func display(for sample: GazeSample) -> CGDirectDisplayID? {
        let ranked = ranking(for: sample)
        guard let winner = ranked.first else { return nil }
        guard ranked.count > 1 else { return winner.display }
        // Has to win clearly. A coin flip between two displays should leave
        // focus alone rather than pick one.
        guard winner.distance <= ranked[1].distance * gazeMargin else { return nil }
        return winner.display
    }

    /// Rough spot on the winning display this reading points at, in AX
    /// coordinates, or nil if there's nothing confident to draw.
    ///
    /// Only good enough to show which way things are leaning. The calibration
    /// points are the only places the mapping is pinned down, so this is an
    /// inverse-distance blend of them and it pulls toward whichever one is
    /// nearest. Restricted to the winning display's points, because the screens
    /// aren't contiguous in desktop coordinates and blending across a gap would
    /// put the dot in space that isn't on any display.
    func point(for sample: GazeSample) -> CGPoint? {
        guard let display = display(for: sample) else { return nil }
        let known = references.filter { $0.display == display && $0.point != nil }
        guard !known.isEmpty else { return nil }

        var x = 0.0, y = 0.0, total = 0.0
        for reference in known {
            let measured = distance(sample, reference.sample)
            let weight = 1 / (measured * measured + 0.05)
            x += weight * Double(reference.point!.x)
            y += weight * Double(reference.point!.y)
            total += weight
        }
        guard total > 0 else { return nil }
        return CGPoint(x: x / total, y: y / total)
    }

    /// How readable each axis turned out to be, for the debug trace.
    var weightSummary: String {
        String(format: "headX %.2f headY %.2f eyeX %.2f eyeY %.2f",
               weights.headX, weights.headY, weights.eyeX, weights.eyeY)
    }

    private func distance(_ a: GazeSample, _ b: GazeSample) -> Double {
        let headX = (a.headX - b.headX) * weights.headX
        let headY = (a.headY - b.headY) * weights.headY
        let eyeX = (a.eyeX - b.eyeX) * weights.eyeX
        let eyeY = (a.eyeY - b.eyeY) * weights.eyeY
        return (headX * headX + headY * headY + eyeX * eyeX + eyeY * eyeY).squareRoot()
    }

    // MARK: Fitting

    /// Weight per axis: how far the displays sit apart on it, over how much it
    /// wanders while you look at one of them. An axis that moves more within a
    /// display than between displays is measuring your posture, not your gaze,
    /// and comes out near zero.
    private static func fit(_ groups: [CGDirectDisplayID: [GazeSample]]) -> GazeSample {
        func weight(_ axis: (GazeSample) -> Double) -> Double {
            let perDisplay = groups.values.map { samples in
                samples.map(axis)
            }
            let means = perDisplay.map { mean($0) }
            guard means.count > 1 else { return 1 }
            let between = spread(means)
            // Pooled, so one twitchy display doesn't drag an otherwise clean
            // axis down on its own.
            let within = mean(perDisplay.map { spread($0) })
            return between / max(within, gazeAxisFloor)
        }

        var raw = GazeSample(headX: weight(\.headX), headY: weight(\.headY),
                             eyeX: weight(\.eyeX), eyeY: weight(\.eyeY))
        // Scale is arbitrary since only ratios of distances are ever compared;
        // normalising just makes the trace readable.
        let peak = max(raw.headX, raw.headY, raw.eyeX, raw.eyeY)
        if peak > 0 {
            raw.headX /= peak
            raw.headY /= peak
            raw.eyeX /= peak
            raw.eyeY /= peak
        }
        return raw
    }

    private static func mean(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    /// Standard deviation, and zero rather than a divide-by-zero for a single
    /// reading, which is what a display calibrated from one point gives.
    private static func spread(_ values: [Double]) -> Double {
        guard values.count > 1 else { return 0 }
        let average = mean(values)
        let variance = values.reduce(0) { $0 + ($1 - average) * ($1 - average) } / Double(values.count - 1)
        return variance.squareRoot()
    }

    // MARK: Storage

    /// Flattened as one row per reading: display id, the four axes, then the
    /// point on screen if it was recorded.
    var storage: [[Double]] {
        references.map { reference in
            var row = [Double(reference.display),
                       reference.sample.headX, reference.sample.headY,
                       reference.sample.eyeX, reference.sample.eyeY]
            if let point = reference.point {
                row.append(Double(point.x))
                row.append(Double(point.y))
            }
            return row
        }
    }

    init(references: [GazeReference]) {
        self.references = references

        var groups: [CGDirectDisplayID: [GazeSample]] = [:]
        for reference in references {
            groups[reference.display, default: []].append(reference.sample)
        }
        centers = groups.mapValues { samples in
            let count = Double(samples.count)
            return GazeSample(headX: samples.reduce(0) { $0 + $1.headX } / count,
                              headY: samples.reduce(0) { $0 + $1.headY } / count,
                              eyeX: samples.reduce(0) { $0 + $1.eyeX } / count,
                              eyeY: samples.reduce(0) { $0 + $1.eyeY } / count)
        }
        weights = GazeProfile.fit(groups)
    }

    init?(storage: [[Double]]) {
        guard !storage.isEmpty else { return nil }
        var parsed: [GazeReference] = []
        for row in storage {
            // Five columns is a profile from before the point was recorded.
            guard row.count == 5 || row.count == 7 else { return nil }
            parsed.append(GazeReference(
                display: CGDirectDisplayID(row[0]),
                sample: GazeSample(headX: row[1], headY: row[2], eyeX: row[3], eyeY: row[4]),
                point: row.count == 7 ? CGPoint(x: row[5], y: row[6]) : nil))
        }
        self.init(references: parsed)
    }
}
