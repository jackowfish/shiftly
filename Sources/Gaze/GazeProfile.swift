import AppKit

/// One calibration reading: what the camera saw while you looked at a known
/// display, and the spot on it you were looking at.
///
/// The point is only ever used to draw the debug dot; which display you're on
/// is decided from the labels alone. Profiles saved before the point was
/// recorded load with it missing, so an old calibration still works and just
/// can't draw a dot.
///
/// The session says which calibration run the reading came from. Runs are
/// pooled rather than replaced — see the note on `GazeProfile` — and the fits
/// that compare models need to hold out whole runs, since readings within one
/// run share its posture.
struct GazeReference {
    let display: CGDirectDisplayID
    let sample: GazeSample
    var point: CGPoint?
    var session = 0
}

/// What "looking at that display" measures like, learned from calibration.
///
/// This replaced a linear map from face geometry to desktop coordinates, which
/// had to be told how the camera was mounted and how far a face turns before it
/// means anything — the origin of the old Flip Horizontal control. Comparing
/// against labelled readings instead makes mirroring, mounting and how far you
/// personally turn your head fall out of the calibration for free, with nothing
/// left to configure.
///
/// Axis weights are learned too: display separation over measurement precision.
/// Hand-picked weights can't know which axis carries the signal on a given desk
/// — side by side it's yaw, stacked it's pitch, held still it's the pupils.
///
/// Calibrations accumulate instead of replacing each other. Half the placement
/// error is session drift — you sit a little differently every time — and a fit
/// that has only seen one posture mistakes it for the truth. Measured across
/// held-out sessions, pooling four calibrations nearly doubled the rate of
/// acting on the right sixth-of-a-screen slot over training on one. See
/// `tools/gaze_eval.py --sessions`.
struct GazeProfile {
    let references: [GazeReference]

    /// How much weight each axis earned from the calibration.
    private let weights: GazeSample

    /// Per-display fit from a reading to a point on that display, for the dot.
    private let placements: [CGDirectDisplayID: (x: AxisFit, y: AxisFit)]

    var displays: Set<CGDirectDisplayID> { Set(references.map(\.display)) }

    /// How many calibration runs the profile holds.
    var sessionCount: Int { Set(references.map(\.session)).count }

    /// Eye aperture below this is a blink, not a gaze. Set under the smallest
    /// aperture any calibration dot produced — looking down narrows the lids,
    /// and the floor has to sit below everything normal looking measures, or
    /// rejecting "blinks" would bias readings against looking down. Nil when
    /// the profile predates the lid axis.
    let lidFloor: Double?

    /// Every display and how far its nearest reading is, nearest first.
    ///
    /// Nearest reading rather than nearest average. Once axes are scaled by
    /// measurement noise, the spread within a display is real information about
    /// where on it you were looking, and a mean throws it away — on an ultrawide
    /// that mean sits mid-screen, and the two edges measure nothing alike.
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
    /// point. The classifier scales each axis by how well it separates displays,
    /// which on a side-by-side desk weights vertical at a quarter of horizontal
    /// — correct, since vertical says nothing about which of two adjacent
    /// screens you're on. Drawing the dot through that same metric made it slide
    /// sideways while barely moving up or down.
    ///
    /// Placement wants the opposite: every axis at face value, fit per display.
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

    /// The axes the profile learns from. `GazeSample.axes` carries more: Vision's
    /// head pose, the corner-anchored per-eye reads and the face box are
    /// recorded but deliberately not fitted until captures score them in.
    ///
    /// The pose angles were measured and rejected: training on one calibration
    /// and testing on another, every way of including them scored worse (720px
    /// without against 814px for yaw and pitch, 939px for all three), because
    /// they aren't new information — `faceYaw` correlates with `headX` at
    /// r = 0.87. A near-collinear column costs coefficient variance and adds no
    /// signal. Head-pose *interaction* terms were tried too and also lost.
    ///
    /// Scoring within one capture reverses such verdicts, which is the part
    /// worth remembering: extra parameters fit the session rather than the
    /// person. Everything here is judged across sessions now for exactly that
    /// reason. See `tools/gaze_eval.py --sessions`.
    private static let fitted: [WritableKeyPath<GazeSample, Double>] =
        [\.headX, \.headY, \.eyeX, \.eyeY, \.lidY]

    // MARK: Placement

    /// One term of a linear placement fit: an axis, optionally multiplied by a
    /// second one, which covers both the linear and the product terms.
    struct Term {
        let first: Int
        let second: Int?

        func value(_ sample: GazeSample, _ axes: [KeyPath<GazeSample, Double>]) -> Double {
            let a = sample[keyPath: axes[first]]
            guard let second else { return a }
            return a * sample[keyPath: axes[second]]
        }
    }

    /// One axis of the dot as a plain least-squares fit: a constant plus a
    /// weighted sum of terms.
    struct Placement {
        var constant = 0.0
        var terms: [(term: Term, weight: Double)] = []

        func callAsFunction(_ sample: GazeSample) -> Double {
            terms.reduce(constant) { $0 + $1.weight * $1.term.value(sample, GazeProfile.axes) }
        }
    }

    /// One axis of the dot as a ridge fit over the quadratic expansion of the
    /// measured axes: every axis, every square, every product, standardized.
    ///
    /// Standardizing is what makes one lambda meaningful across axes measured
    /// in different units; the penalty is what lets twenty terms fit a
    /// session's eighteen dots without memorizing them. A column that never
    /// moved standardizes to zero and its weight goes to zero with it, so dead
    /// axes need no special handling here.
    struct RidgePlacement {
        var constant = 0.0
        var mean: [Double] = []
        var scale: [Double] = []
        var coefficients: [Double] = []

        func callAsFunction(_ sample: GazeSample) -> Double {
            let features = GazeProfile.quadFeatures(sample)
            var out = constant
            for i in 0..<coefficients.count {
                out += coefficients[i] * (features[i] - mean[i]) / scale[i]
            }
            return out
        }
    }

    /// One axis of one display's dot, whichever fit won the model comparison.
    enum AxisFit {
        case linear(Placement)
        case quad(RidgePlacement)

        func callAsFunction(_ sample: GazeSample) -> Double {
            switch self {
            case let .linear(fit): return fit(sample)
            case let .quad(fit): return fit(sample)
            }
        }

        var name: String {
            switch self {
            case .linear: return "linear"
            case .quad: return "quad"
            }
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

    /// The quadratic expansion the ridge fit works over.
    static func quadFeatures(_ sample: GazeSample) -> [Double] {
        let base = axes.map { sample[keyPath: $0] }
        var out = base
        for i in 0..<base.count {
            for j in i..<base.count { out.append(base[i] * base[j]) }
        }
        return out
    }

    /// Terms for one axis of one display: every measured axis, linearly, with
    /// the ones that carry this direction first.
    private static func terms(own: [Int], cross: [Int]) -> [Term] {
        (own + cross).map { Term(first: $0, second: nil) }
    }

    /// Gauss-Jordan with partial pivoting over an augmented system, or nil
    /// when it's singular. Shared by both solvers; at most 20x21.
    private static func eliminate(_ matrix: inout [[Double]], terms: Int) -> [Double]? {
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

        let design = features.map { [1.0] + $0 }
        var matrix = [[Double]](repeating: [Double](repeating: 0, count: terms + 1), count: terms)
        for (row, value) in zip(design, values) {
            for i in 0..<terms {
                for j in 0..<terms { matrix[i][j] += row[i] * row[j] }
                matrix[i][terms] += row[i] * value
            }
        }
        return eliminate(&matrix, terms: terms)
    }

    /// The linear fit for one axis of one display. `own` are the axes that
    /// carry it directly, `cross` the ones that only correct it.
    private static func linearPlacement(_ group: [GazeReference],
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

    /// The ridge fit for one axis of one display.
    private static func ridgePlacement(_ group: [GazeReference],
                                       value: (CGPoint) -> CGFloat) -> RidgePlacement? {
        let rows = group.map { quadFeatures($0.sample) }
        let values = group.map { Double(value($0.point!)) }
        let count = rows.count
        guard count >= 5, let width = rows.first?.count else { return nil }

        let mean = (0..<width).map { i in rows.reduce(0) { $0 + $1[i] } / Double(count) }
        let scale = (0..<width).map { i in max(spread(rows.map { $0[i] }), 1e-9) }
        let standardized = rows.map { row in
            (0..<width).map { (row[$0] - mean[$0]) / scale[$0] }
        }
        let valueMean = values.reduce(0, +) / Double(count)
        let centred = values.map { $0 - valueMean }

        var matrix = [[Double]](repeating: [Double](repeating: 0, count: width + 1), count: width)
        for (row, value) in zip(standardized, centred) {
            for i in 0..<width {
                for j in 0..<width { matrix[i][j] += row[i] * row[j] }
                matrix[i][width] += row[i] * value
            }
        }
        for i in 0..<width { matrix[i][i] += gazeRidgeLambda * Double(count) }
        guard let solved = eliminate(&matrix, terms: width) else { return nil }
        return RidgePlacement(constant: valueMean, mean: mean, scale: scale, coefficients: solved)
    }

    /// Both candidate fits for one axis of one display's group.
    private static func candidates(_ group: [GazeReference],
                                   own: [Int],
                                   cross: [Int],
                                   value: @escaping (CGPoint) -> CGFloat) -> (AxisFit?, AxisFit?) {
        (linearPlacement(group, own: own, cross: cross, value: value).map(AxisFit.linear),
         ridgePlacement(group, value: value).map(AxisFit.quad))
    }

    /// Picks linear or quadratic per display and axis by holding each session
    /// out in turn: fit both on the others, score on the one held out, keep
    /// whichever lands closer overall.
    ///
    /// Selection needs whole sessions, not dots. An inner split within one
    /// session shares that session's posture, which flatters the richer model
    /// — that's how the quadratic terms first got rejected here, judged on
    /// eighteen dots. Judged across sessions the answer is stable and differs
    /// by display: linear on an ultrawide, quadratic on a portrait display, on
    /// the captures so far. A single-session profile can't run the comparison
    /// and takes the linear fit, which won on those grounds originally.
    private static func select(_ group: [GazeReference],
                               own: [Int],
                               cross: [Int],
                               value: @escaping (CGPoint) -> CGFloat) -> AxisFit? {
        let sessions = Set(group.map(\.session))
        let (linear, quad) = candidates(group, own: own, cross: cross, value: value)
        guard sessions.count >= 2, linear != nil, quad != nil else { return linear ?? quad }

        var linearErrors: [Double] = []
        var quadErrors: [Double] = []
        for session in sessions {
            let held = group.filter { $0.session == session }
            let rest = group.filter { $0.session != session }
            let (restLinear, restQuad) = candidates(rest, own: own, cross: cross, value: value)
            guard let restLinear, let restQuad else { continue }
            for reference in held {
                let truth = Double(value(reference.point!))
                linearErrors.append(abs(restLinear(reference.sample) - truth))
                quadErrors.append(abs(restQuad(reference.sample) - truth))
            }
        }
        guard !linearErrors.isEmpty else { return linear }
        return median(linearErrors) <= median(quadErrors) ? linear : quad
    }

    private static func fitPlacements(
        _ references: [GazeReference]
    ) -> [CGDirectDisplayID: (x: AxisFit, y: AxisFit)] {
        var grouped: [CGDirectDisplayID: [GazeReference]] = [:]
        for reference in references where reference.point != nil {
            grouped[reference.display, default: []].append(reference)
        }

        var out: [CGDirectDisplayID: (x: AxisFit, y: AxisFit)] = [:]
        for (display, group) in grouped {
            guard let x = select(group, own: horizontal, cross: vertical, value: \.x),
                  let y = select(group, own: vertical, cross: horizontal, value: \.y)
            else { continue }
            out[display] = (x: x, y: y)
        }
        return out
    }

    // MARK: Fitting

    /// Weight per axis: how far the displays sit apart on it, over how precisely
    /// it can be measured at all.
    ///
    /// The denominator is the subtle part. It used to be the axis's spread across
    /// one display's dots, which buried the pupil terms: dots span a whole
    /// screen, so pupil position sweeps its full range on every display and the
    /// most informative axis scored as the noisiest. That profile put nearly all
    /// its weight on head yaw and needed a real head turn to notice anything.
    /// Per-frame jitter instead separates "moves because it's tracking
    /// something" from "moves because it can't be pinned down".
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

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
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

    /// Flattened as one row per reading: a format tag, the session, the display
    /// id, every axis, then the point on screen if it was recorded.
    ///
    /// The tag is what makes an older calibration fail to load rather than load
    /// wrong. Several changes have altered what a recorded number means without
    /// altering its shape, and such a profile parses cleanly and then sends
    /// windows to the wrong place, which is worse than asking for a recalibration.
    var storage: [[Double]] {
        references.map { reference in
            var row = [Double(GazeProfile.format), Double(reference.session), Double(reference.display)]
            row += GazeSample.axes.map { reference.sample[keyPath: $0] }
            if let point = reference.point {
                row.append(Double(point.x))
                row.append(Double(point.y))
            }
            return row
        }
    }

    /// Negative on purpose: rows used to begin with an unsigned display id, so a
    /// negative leading value is one an older profile can never produce. Tagging
    /// with 2 nearly shipped — a pre-point row from display 2 is seven numbers
    /// starting with a 2, exactly the shape of a tagged row without a point.
    ///
    /// Versions 3 onward are all the same width, so the tag is the only thing
    /// separating them, and each was wrong in a way nothing downstream could
    /// notice. 3 read its pose off a landmarks pass, giving a three-valued yaw
    /// and flat-zero pitch and roll, and zero radians reads as a face pointing
    /// at the camera rather than as a missing reading. 4 fixed the pose but
    /// measured landmarks inside the wrong bounding box. 6 added the session
    /// column and the recorded-only axes.
    private static let format = -6

    /// Whether the dot has anywhere to go, which the debug overlay reports so a
    /// blank screen doesn't read as a broken tracker.
    var hasPoints: Bool { !placements.isEmpty }

    /// Which fit each display's dot ended up with, for the debug trace.
    var placementSummary: String {
        placements.sorted { $0.key < $1.key }
            .map { "\($0.key) x:\($0.value.x.name) y:\($0.value.y.name)" }
            .joined(separator: "  ")
    }

    init(references: [GazeReference], noise: GazeSample? = nil) {
        self.references = references
        let lids = references.map(\.sample.lidY).filter { $0 > 0 }
        lidFloor = lids.min().map { $0 * gazeBlinkLidFraction }

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
            let withPoint = 3 + axes + 2
            guard row.count == 3 + axes || row.count == withPoint else { return nil }
            var sample = GazeSample()
            for (index, axis) in GazeSample.axes.enumerated() {
                sample[keyPath: axis] = row[3 + index]
            }
            parsed.append(GazeReference(
                display: CGDirectDisplayID(row[2]),
                sample: sample,
                point: row.count == withPoint
                    ? CGPoint(x: row[withPoint - 2], y: row[withPoint - 1]) : nil,
                session: Int(row[1])))
        }
        self.init(references: parsed, noise: noise)
    }
}
