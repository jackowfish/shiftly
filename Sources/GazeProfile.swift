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
/// The axes are weighted by how well each one separates the displays against
/// how precisely it can be measured, both taken from the calibration readings.
/// Hand-picked weights can't know which axis carries the signal on a given
/// desk: side by side it's yaw, stacked it's pitch, and held still it's the
/// pupils.
struct GazeProfile {
    let references: [GazeReference]

    /// How much weight each axis earned from the calibration.
    private let weights: GazeSample

    /// Per-display fit from a reading to a point on that display, for the dot.
    private let placements: [CGDirectDisplayID: (x: Placement, y: Placement)]

    var displays: Set<CGDirectDisplayID> { Set(references.map(\.display)) }

    /// Every display and how far its nearest reading is, nearest first.
    ///
    /// Nearest reading rather than nearest average. Once the axes are scaled by
    /// measurement noise instead of by how much they vary across a display, the
    /// spread within a display is real information about where on it you were
    /// looking, and collapsing five readings to their mean throws it away. On an
    /// ultrawide that mean sits in the middle of a screen wide enough that its
    /// two edges measure nothing alike.
    func ranking(for sample: GazeSample) -> [(display: CGDirectDisplayID, distance: Double)] {
        var closest: [CGDirectDisplayID: Double] = [:]
        for reference in references {
            let measured = distance(sample, reference.sample)
            closest[reference.display] = min(closest[reference.display] ?? .greatestFiniteMagnitude, measured)
        }
        return closest.sorted { $0.value < $1.value }.map { (display: $0.key, distance: $0.value) }
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
    /// coordinates, or nil if the calibration can't pin one down.
    ///
    /// Fitted separately from the display choice, and that separation is the
    /// point. The classifier scales each axis by how well it tells displays
    /// apart, which on a side-by-side desk weights vertical at about a quarter
    /// of horizontal — correct, because vertical says nothing about which of
    /// two screens beside each other you're on. Blending calibration points
    /// through that same metric made the dot slide left and right while barely
    /// moving up or down, and sit near the middle of whichever screen won.
    ///
    /// Placement wants the opposite: every axis at face value, fitted to where
    /// you were actually looking. Horizontal gaze is mostly head yaw plus eye
    /// yaw and vertical mostly head pitch plus eye pitch, so each is a
    /// least-squares fit per display, over its own two axes and — where the
    /// calibration has the dots to support it — the other two as well.
    func point(for sample: GazeSample) -> CGPoint? {
        guard let display = display(for: sample), let fit = placements[display] else { return nil }
        return CGPoint(x: fit.x(sample), y: fit.y(sample))
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

    // MARK: Placement

    /// One axis of the dot, as a weight on each measured axis plus an offset.
    /// The cross-axis weights stay zero when the calibration was too small to
    /// fit them.
    struct Placement {
        var constant = 0.0
        var headX = 0.0
        var eyeX = 0.0
        var headY = 0.0
        var eyeY = 0.0

        func callAsFunction(_ sample: GazeSample) -> Double {
            constant + headX * sample.headX + eyeX * sample.eyeX
                + headY * sample.headY + eyeY * sample.eyeY
        }
    }

    /// The measured axes and the Placement weights they pair with, in one fixed
    /// order so a solved coefficient vector reads back into a Placement.
    private static let axes: [KeyPath<GazeSample, Double>] = [\.headX, \.eyeX, \.headY, \.eyeY]
    private static let slots: [WritableKeyPath<Placement, Double>] = [\.headX, \.eyeX, \.headY, \.eyeY]

    /// Least squares for `value ≈ c + Σ coefficient · feature`, or nil when the
    /// readings can't pin the coefficients down — a calibration where every dot
    /// measured the same has nothing to fit and should draw nothing rather than
    /// a confident guess.
    private static func solve(features: [[Double]], values: [Double]) -> [Double]? {
        let terms = (features.first?.count ?? 0) + 1
        // Headroom over the parameter count, not merely enough to be solvable.
        // A fit with as many parameters as readings passes exactly through
        // every one of them, which means it has fitted the jitter.
        guard features.count >= terms + 2 else { return nil }

        // Normal equations, built with a leading 1 for the constant term, then
        // Gauss-Jordan with partial pivoting. At most 5x5.
        let design = features.map { [1.0] + $0 }
        var matrix = [[Double]](repeating: [Double](repeating: 0, count: terms + 1), count: terms)
        for (row, value) in zip(design, values) {
            for i in 0..<terms {
                for j in 0..<terms { matrix[i][j] += row[i] * row[j] }
                matrix[i][terms] += row[i] * value
            }
        }

        for column in 0..<terms {
            guard let pivot = (column..<terms).max(by: { abs(matrix[$0][column]) < abs(matrix[$1][column]) }),
                  abs(matrix[pivot][column]) > 1e-9 else { return nil }
            matrix.swapAt(column, pivot)
            let lead = matrix[column][column]
            for j in column...terms { matrix[column][j] /= lead }
            for row in 0..<terms where row != column {
                let factor = matrix[row][column]
                guard factor != 0 else { continue }
                for j in column...terms { matrix[row][j] -= factor * matrix[column][j] }
            }
        }
        return (0..<terms).map { matrix[$0][terms] }
    }

    /// One axis of one display's dot. `own` are the axes that carry it directly,
    /// `cross` the ones that only correct it, dropped when the dots are too few
    /// to tell a real correction from noise.
    private static func placement(_ group: [GazeReference],
                                  own: [Int],
                                  cross: [Int],
                                  value: (CGPoint) -> CGFloat) -> Placement? {
        let used = group.count >= gazePlacementCoupledDots ? own + cross : own
        let features = group.map { reference in
            used.map { reference.sample[keyPath: axes[$0]] }
        }
        guard let solved = solve(features: features, values: group.map { Double(value($0.point!)) })
        else { return nil }

        var out = Placement(constant: solved[0])
        for (axis, coefficient) in zip(used, solved.dropFirst()) {
            out[keyPath: slots[axis]] = coefficient
        }
        return out
    }

    private static func fitPlacements(
        _ references: [GazeReference]
    ) -> [CGDirectDisplayID: (x: Placement, y: Placement)] {
        var grouped: [CGDirectDisplayID: [GazeReference]] = [:]
        for reference in references where reference.point != nil {
            grouped[reference.display, default: []].append(reference)
        }

        var out: [CGDirectDisplayID: (x: Placement, y: Placement)] = [:]
        for (display, group) in grouped {
            guard let x = placement(group, own: [0, 1], cross: [2, 3], value: \.x),
                  let y = placement(group, own: [2, 3], cross: [0, 1], value: \.y)
            else { continue }
            out[display] = (x: x, y: y)
        }
        return out
    }

    // MARK: Fitting

    /// Weight per axis: how far the displays sit apart on it, over how precisely
    /// it can be measured at all.
    ///
    /// The denominator matters more than it looks. It used to be how much the
    /// axis varied across one display's readings, which quietly punished the
    /// pupil terms: calibration dots span a whole screen, so pupil position
    /// varies over its full range at every display, and the axis carrying the
    /// most usable information scored as the noisiest. The result was a profile
    /// that put essentially all its weight on head yaw and then needed a real
    /// head turn to register anything.
    ///
    /// Using per-frame jitter instead — how much an axis wobbles while you hold
    /// a single dot — separates "moves a lot because it's tracking something"
    /// from "moves a lot because it can't be pinned down".
    private static func fit(_ groups: [CGDirectDisplayID: [GazeSample]],
                            noise: GazeSample?) -> GazeSample {
        func weight(_ axis: (GazeSample) -> Double) -> Double {
            let perDisplay = groups.values.map { samples in
                samples.map(axis)
            }
            let means = perDisplay.map { mean($0) }
            guard means.count > 1 else { return 1 }
            let between = spread(means)
            // Profiles saved before jitter was measured fall back to the old
            // within-display spread, so an existing calibration still loads.
            let scale = noise.map(axis) ?? mean(perDisplay.map { spread($0) })
            return between / max(scale, gazeAxisFloor)
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

    /// Whether the dot has anywhere to go, which the debug overlay reports so a
    /// blank screen doesn't read as a broken tracker.
    var hasPoints: Bool { !placements.isEmpty }

    init(references: [GazeReference], noise: GazeSample? = nil) {
        self.references = references

        var groups: [CGDirectDisplayID: [GazeSample]] = [:]
        for reference in references {
            groups[reference.display, default: []].append(reference.sample)
        }
        weights = GazeProfile.fit(groups, noise: noise)
        placements = GazeProfile.fitPlacements(references)
    }

    init?(storage: [[Double]], noise: GazeSample? = nil) {
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
        self.init(references: parsed, noise: noise)
    }
}
