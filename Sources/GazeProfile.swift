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
        zip(GazeSample.names, GazeSample.axes)
            .filter { GazeProfile.fitted.contains($0.1) }
            .map { String(format: "%@ %.2f", $0, weights[keyPath: $1]) }
            .joined(separator: " ")
    }

    private func distance(_ a: GazeSample, _ b: GazeSample) -> Double {
        GazeProfile.fitted.reduce(0) { total, axis in
            let delta = (a[keyPath: axis] - b[keyPath: axis]) * weights[keyPath: axis]
            return total + delta * delta
        }.squareRoot()
    }

    /// The axes the profile actually learns from, which is not everything a
    /// reading carries: `GazeSample.axes` also holds Vision's head pose, which
    /// is recorded but deliberately not fitted.
    ///
    /// The pose looked like the obvious fix. `headX` and `headY` are two
    /// landmark centroids over a third distance, a crude estimator of a
    /// rotation, and the head term is the part of the placement fit that runs
    /// out first, so a trained pose model should beat them. Measured on two
    /// calibrations recorded back to back, training on one and testing on the
    /// other, every way of including it came out worse: summing both axes and
    /// both directions of the split, 720px without the pose against 814px for
    /// yaw and pitch, 853px for yaw alone and 939px for all three. Scoring
    /// within a single capture reverses that and says yaw helps, which is what
    /// makes this worth writing down — at eighteen dots a display, extra
    /// parameters fit the session rather than the person.
    ///
    /// The reason is that it isn't new information. Across the calibration dots
    /// `faceYaw` correlates with `headX` at r = 0.87 and with `headY` at 0.72:
    /// it measures what the ratios already measure, so it buys a near-collinear
    /// column, and those inflate coefficient variance without adding signal.
    /// The head estimate being weak is real, but a second estimate of the same
    /// weak thing isn't the fix.
    ///
    /// The display classifier is a closer call and was nearly split out, since
    /// nearest-neighbour pays no parameter cost for an extra axis. It doesn't
    /// survive either: training on one calibration and testing on the other,
    /// the pose cuts wrong-display decisions from 2.9% to 0.6% in one direction
    /// and raises them from 1.2% to 2.7% in the other, while adding lag. A
    /// difference whose sign depends on which capture trains is not a
    /// difference two captures can resolve.
    private static let fitted: [WritableKeyPath<GazeSample, Double>] =
        [\.headX, \.headY, \.eyeX, \.eyeY, \.lidY]

    // MARK: Placement

    /// One term of a placement fit: an axis, optionally multiplied by a second
    /// one, which covers both the linear and the squared and product terms.
    struct Term {
        let first: Int
        let second: Int?

        func value(_ sample: GazeSample, _ axes: [KeyPath<GazeSample, Double>]) -> Double {
            let a = sample[keyPath: axes[first]]
            guard let second else { return a }
            return a * sample[keyPath: axes[second]]
        }
    }

    /// One axis of the dot: a constant plus a weighted sum of terms.
    struct Placement {
        var constant = 0.0
        var terms: [(term: Term, weight: Double)] = []

        func callAsFunction(_ sample: GazeSample) -> Double {
            terms.reduce(constant) { $0 + $1.weight * $1.term.value(sample, GazeProfile.axes) }
        }
    }

    /// The measured axes in one fixed order, so a solved coefficient vector
    /// reads back onto the right terms. Grouped horizontal first, then vertical,
    /// so each axis of the dot takes a contiguous slice as the terms that carry
    /// it directly, with the ones that point nowhere on their own last.
    private static let axes: [KeyPath<GazeSample, Double>] =
        [\.headX, \.eyeX, \.headY, \.eyeY, \.lidY]
    private static let horizontal = [0, 1]
    private static let vertical = [2, 3, 4]

    /// Terms for one axis of one display: every measured axis, linearly, with
    /// the ones that carry this direction first.
    ///
    /// Second-order terms are the standard mapping in the eye tracking
    /// literature and they were tried properly here. Fixed and measured against
    /// held-out dots they win on exactly one axis of one display, taking the
    /// ultrawide's vertical fit from 184px to 136px, while pushing its
    /// horizontal from 66px to 86px and making both axes of a portrait display
    /// worse. Choosing per axis from the calibration then scored worse than
    /// linear everywhere, 203px horizontal against 144px: at eighteen dots the
    /// gap between the two shapes sits inside the noise, so the choice comes out
    /// close to a coin flip, and the polynomial extrapolates badly when it loses.
    ///
    /// A shape that wins a quarter of the time and can't be identified when is
    /// worth less than the one that never blows up. `Term` stays general so the
    /// next attempt is a change here rather than a rewrite.
    private static func terms(own: [Int], cross: [Int]) -> [Term] {
        (own + cross).map { Term(first: $0, second: nil) }
    }

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
    /// `cross` the ones that only correct it.
    private static func placement(_ group: [GazeReference],
                                  own: [Int],
                                  cross: [Int],
                                  value: (CGPoint) -> CGFloat) -> Placement? {
        let values = group.map { Double(value($0.point!)) }
        func columns(_ terms: [Term]) -> [[Double]] {
            group.map { reference in terms.map { $0.value(reference.sample, axes) } }
        }
        // A term that never moved across the whole calibration is a column of
        // one repeated number, which is the constant term again and makes the
        // normal equations singular. Vision hands back no angle at all on some
        // cameras, so this is a real case rather than a defensive one, and
        // dropping the dead term beats refusing to place a dot.
        func live(_ candidates: [Term]) -> [Term] {
            let features = columns(candidates)
            return candidates.enumerated().filter { index, _ in
                spread(features.map { $0[index] }) > 1e-6
            }.map(\.element)
        }

        var chosen = live(terms(own: own, cross: cross))
        // Fall back to the carrying axes alone when a small calibration can't
        // support the corrections, so a short profile still places a dot.
        if solve(features: columns(chosen), values: values) == nil {
            chosen = live(own.map { Term(first: $0, second: nil) })
        }
        guard let solved = solve(features: columns(chosen), values: values) else { return nil }
        return Placement(constant: solved[0],
                         terms: Array(zip(chosen, solved.dropFirst()).map { (term: $0, weight: $1) }))
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
            guard let x = placement(group, own: horizontal, cross: vertical, value: \.x),
                  let y = placement(group, own: vertical, cross: horizontal, value: \.y)
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
        func weight(_ axis: WritableKeyPath<GazeSample, Double>) -> Double {
            let perDisplay = groups.values.map { samples in
                samples.map { $0[keyPath: axis] }
            }
            let means = perDisplay.map { mean($0) }
            guard means.count > 1 else { return 1 }
            let between = spread(means)
            // A calibration recorded before jitter was measured falls back to
            // the older within-display spread rather than refusing to load.
            let scale = noise?[keyPath: axis] ?? mean(perDisplay.map { spread($0) })
            return between / max(scale, gazeAxisFloor)
        }

        var raw = GazeSample()
        for axis in fitted { raw[keyPath: axis] = weight(axis) }
        // Scale is arbitrary since only ratios of distances are ever compared;
        // normalising just makes the trace readable.
        let peak = fitted.map { raw[keyPath: $0] }.max() ?? 0
        if peak > 0 {
            for axis in fitted { raw[keyPath: axis] /= peak }
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

    /// Flattened as one row per reading: a format tag, the display id, every
    /// axis, then the point on screen if it was recorded.
    ///
    /// The tag is what makes an older calibration fail to load rather than load
    /// wrong. `eyeY` used to be scaled by eye height and is now scaled by eye
    /// width, so the same number means a different angle: a profile from before
    /// that would parse cleanly and then send windows to the wrong place, which
    /// is worse than asking for a minute of recalibration.
    var storage: [[Double]] {
        references.map { reference in
            var row = [Double(GazeProfile.format), Double(reference.display)]
            row += GazeSample.axes.map { reference.sample[keyPath: $0] }
            if let point = reference.point {
                row.append(Double(point.x))
                row.append(Double(point.y))
            }
            return row
        }
    }

    /// Negative on purpose. A row used to begin with a display id, which is
    /// unsigned, so a negative leading value is one an older profile can never
    /// produce. Tagging with 2 very nearly shipped: a pre-point row from display
    /// 2 is seven numbers beginning with a 2, which is also exactly the shape of
    /// a tagged row without a point, and it parsed clean.
    ///
    /// Every version after 2 has the same width, so the tag is the only thing
    /// separating them, and each was wrong in a way nothing downstream could
    /// notice. 3 took its pose from a landmarks pass, which reports yaw as one
    /// of three values and pitch and roll as flat zero — and zero radians reads
    /// as a face pointing straight at the camera, not as a missing reading. 4
    /// fixed the pose but seeded the landmarks from the rectangles pass, so
    /// every landmark ratio was measured inside a different bounding box than
    /// the one the app now uses. Both would load and quietly mis-place.
    private static let format = -5

    /// Whether the dot has anywhere to go, which the debug overlay reports so a
    /// blank screen doesn't read as a broken tracker.
    var hasPoints: Bool { !placements.isEmpty }

    /// How many terms each display's fit ended up with, for the debug trace.
    var placementSummary: String {
        placements.sorted { $0.key < $1.key }
            .map { "\($0.key) x:\($0.value.x.terms.count) y:\($0.value.y.terms.count) terms" }
            .joined(separator: "  ")
    }

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
        let axes = GazeSample.axes.count
        var parsed: [GazeReference] = []
        for row in storage {
            guard row.first == Double(GazeProfile.format) else { return nil }
            let withPoint = 2 + axes + 2
            guard row.count == 2 + axes || row.count == withPoint else { return nil }
            var sample = GazeSample()
            for (index, axis) in GazeSample.axes.enumerated() {
                sample[keyPath: axis] = row[2 + index]
            }
            parsed.append(GazeReference(
                display: CGDirectDisplayID(row[1]),
                sample: sample,
                point: row.count == withPoint
                    ? CGPoint(x: row[withPoint - 2], y: row[withPoint - 1]) : nil))
        }
        self.init(references: parsed, noise: noise)
    }
}
