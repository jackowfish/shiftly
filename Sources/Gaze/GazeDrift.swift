import AppKit

/// Learns what the placement fit is currently getting wrong, from clicks.
///
/// You look at what you click — the gaze literature has measured it at well
/// under 100px — so every ordinary click is a free labelled reading, taken in
/// today's posture rather than the one you calibrated in. That matters because
/// sitting drift is half the placement error: refit against held-out sessions,
/// a plain offset-and-gain correction per display recovered most of what a
/// whole extra calibration would. See `tools/gaze_eval.py --sessions`.
///
/// Only the correction is learned here, never the fit itself. Clicks cluster
/// wherever your work happens to be, and a model refit on clustered labels
/// forgets the rest of the screen; an offset and a clamped gain can't.
final class GazeDrift {
    static let shared = GazeDrift()

    private struct Pair {
        let predicted: CGPoint
        let actual: CGPoint
    }

    private var pairs: [CGDirectDisplayID: [Pair]] = [:]

    private init() {}

    /// Forget everything, for when a new calibration makes the pairs describe
    /// a fit that no longer exists.
    func reset() {
        pairs = [:]
    }

    /// Pair counts per display, for the debug trace.
    var summary: String {
        guard !pairs.isEmpty else { return "no pairs" }
        return pairs.sorted { $0.key < $1.key }
            .map { "\($0.key):\($0.value.count)" }
            .joined(separator: " ")
    }

    /// Records one accepted click. `predicted` is the raw placement estimate,
    /// before correction — the correction maps raw estimates to truth, so
    /// feeding it corrected ones would chase its own tail.
    func note(predicted: CGPoint, actual: CGPoint, on display: CGDirectDisplayID) {
        var list = pairs[display, default: []]
        list.append(Pair(predicted: predicted, actual: actual))
        if list.count > gazeDriftPairLimit {
            list.removeFirst(list.count - gazeDriftPairLimit)
        }
        pairs[display] = list
    }

    /// The estimate with today's learned correction applied, clamped onto the
    /// display so a gain can't push the dot off-screen and turn a decent
    /// estimate into "not over any window".
    func corrected(_ point: CGPoint, on display: CGDirectDisplayID) -> CGPoint {
        guard let list = pairs[display], list.count >= gazeDriftMinPairs else { return point }

        // Newest pairs count most, on the WebGazer ramp: weight 1/sqrt(age).
        // Old pairs fade rather than vanish, so one odd recent click can't
        // swing the correction the way it could with a short hard window.
        let count = list.count
        let weights = (0..<count).map { 1.0 / Double(count - $0).squareRoot() }
        let total = weights.reduce(0, +)
        let bounds = CGDisplayBounds(display)

        func corrected(_ value: (CGPoint) -> CGFloat, span: CGFloat) -> CGFloat {
            let predicted = list.map { Double(value($0.predicted)) }
            let actual = list.map { Double(value($0.actual)) }
            let meanPredicted = zip(predicted, weights).reduce(0) { $0 + $1.0 * $1.1 } / total
            let meanActual = zip(actual, weights).reduce(0) { $0 + $1.0 * $1.1 } / total

            var gain = 1.0
            // Gain only once the pairs span a real fraction of the display; a
            // slope fitted to a cluster of clicks in one corner extrapolates
            // disaster across the rest of the screen. Offset alone until then.
            if let low = predicted.min(), let high = predicted.max(),
               high - low >= Double(span) * Double(gazeDriftGainSpan) {
                var variance = 0.0
                var covariance = 0.0
                for i in 0..<count {
                    let dp = predicted[i] - meanPredicted
                    variance += weights[i] * dp * dp
                    covariance += weights[i] * dp * (actual[i] - meanActual)
                }
                if variance > 1e-9 {
                    gain = min(max(covariance / variance, gazeDriftGainRange.lowerBound),
                               gazeDriftGainRange.upperBound)
                }
            }
            return CGFloat(meanActual + gain * (Double(value(point)) - meanPredicted))
        }

        let x = corrected(\.x, span: bounds.width)
        let y = corrected(\.y, span: bounds.height)
        return CGPoint(x: min(max(x, bounds.minX), bounds.maxX),
                       y: min(max(y, bounds.minY), bounds.maxY))
    }
}
