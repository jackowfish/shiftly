import AppKit

/// Linear map from head and eye geometry to a point on the global desktop.
///
/// Only one question gets asked of it: which display. That's a tens-of-degrees
/// signal, which is the forgiving end of what a webcam can resolve, and the
/// hysteresis around it absorbs the rest. The pupil term still earns its place
/// because a camera on the centre display can't see your head turn far enough
/// to face an outer one; the eyes cover the angle the head didn't travel.
struct GazeMap {
    /// x = xBias + xHead * headX + xEye * eyeX
    var xBias: Double
    var xHead: Double
    var xEye: Double
    /// y = yBias + yHead * headY + yEye * eyeY
    var yBias: Double
    var yHead: Double
    var yEye: Double

    func point(for sample: GazeSample) -> CGPoint {
        CGPoint(x: xBias + xHead * sample.headX + xEye * sample.eyeX,
                y: yBias + yHead * sample.headY + yEye * sample.eyeY)
    }

    var storage: [Double] { [xBias, xHead, xEye, yBias, yHead, yEye] }

    init(xBias: Double, xHead: Double, xEye: Double,
         yBias: Double, yHead: Double, yEye: Double) {
        self.xBias = xBias
        self.xHead = xHead
        self.xEye = xEye
        self.yBias = yBias
        self.yHead = yHead
        self.yEye = yEye
    }

    init?(storage: [Double]) {
        guard storage.count == 6 else { return nil }
        self.init(xBias: storage[0], xHead: storage[1], xEye: storage[2],
                  yBias: storage[3], yHead: storage[4], yEye: storage[5])
    }

    /// Fallback for anyone who hasn't calibrated. The spans are a guess at an
    /// average face at an average desk, which is usually enough to tell two or
    /// three displays apart and not much more.
    static func fallback() -> GazeMap {
        let desktop = desktopFrame()
        let halfWidth = desktop.width / 2
        let halfHeight = desktop.height / 2
        let headShare = gazeHeadWeight
        let eyeShare = gazeEyeWeight

        return GazeMap(
            xBias: Double(desktop.midX),
            xHead: Double(halfWidth) * headShare / gazeHeadXSpan,
            xEye: Double(halfWidth) * eyeShare / gazeEyeSpan,
            yBias: Double(desktop.midY) - Double(halfHeight) * headShare * gazeHeadYBias / gazeHeadYSpan,
            yHead: Double(halfHeight) * headShare / gazeHeadYSpan,
            yEye: Double(halfHeight) * eyeShare / gazeEyeSpan)
    }
}

/// A calibration target and the geometry observed while the user looked at it.
struct GazeObservation {
    let target: CGPoint
    let sample: GazeSample
}

enum GazeFit {
    /// Fits a map from the observations. Returns nil if the samples are too
    /// degenerate to solve, which in practice means the face barely moved
    /// between targets.
    static func map(from observations: [GazeObservation]) -> GazeMap? {
        guard observations.count >= 4 else { return nil }

        let targetX = observations.map { Double($0.target.x) }
        let targetY = observations.map { Double($0.target.y) }
        let headX = observations.map { $0.sample.headX }
        let headY = observations.map { $0.sample.headY }
        let eyeX = observations.map { $0.sample.eyeX }
        let eyeY = observations.map { $0.sample.eyeY }
        let ones = [Double](repeating: 1, count: observations.count)

        guard let xFit = solve(columns: [ones, headX, eyeX], values: targetX),
              let yFit = solve(columns: [ones, headY, eyeY], values: targetY)
        else { return nil }

        return GazeMap(xBias: xFit[0], xHead: xFit[1], xEye: xFit[2],
                       yBias: yFit[0], yHead: yFit[1], yEye: yFit[2])
    }

    /// Ridge-regularized least squares. The ridge term keeps the solve stable
    /// when a column is nearly constant, which happens whenever someone holds
    /// very still or the pupil signal is washed out by glare.
    private static func solve(columns: [[Double]], values: [Double]) -> [Double]? {
        let width = columns.count
        guard width > 0, values.count >= width else { return nil }

        var normal = [[Double]](repeating: [Double](repeating: 0, count: width), count: width)
        var rhs = [Double](repeating: 0, count: width)
        for row in 0..<width {
            for column in 0..<width {
                normal[row][column] = zip(columns[row], columns[column]).reduce(0) { $0 + $1.0 * $1.1 }
            }
            rhs[row] = zip(columns[row], values).reduce(0) { $0 + $1.0 * $1.1 }
        }

        let trace = (0..<width).reduce(0.0) { $0 + normal[$1][$1] }
        let ridge = max(trace, 1) * 1e-9
        for index in 0..<width {
            normal[index][index] += ridge
        }

        return gaussianElimination(&normal, &rhs)
    }

    private static func gaussianElimination(_ matrix: inout [[Double]], _ rhs: inout [Double]) -> [Double]? {
        let size = rhs.count
        for pivot in 0..<size {
            var best = pivot
            for row in (pivot + 1)..<size where abs(matrix[row][pivot]) > abs(matrix[best][pivot]) {
                best = row
            }
            if abs(matrix[best][pivot]) < 1e-12 { return nil }
            if best != pivot {
                matrix.swapAt(best, pivot)
                rhs.swapAt(best, pivot)
            }
            for row in (pivot + 1)..<size {
                let factor = matrix[row][pivot] / matrix[pivot][pivot]
                guard factor != 0 else { continue }
                for column in pivot..<size {
                    matrix[row][column] -= factor * matrix[pivot][column]
                }
                rhs[row] -= factor * rhs[pivot]
            }
        }

        var solution = [Double](repeating: 0, count: size)
        for row in stride(from: size - 1, through: 0, by: -1) {
            var total = rhs[row]
            for column in (row + 1)..<size {
                total -= matrix[row][column] * solution[column]
            }
            solution[row] = total / matrix[row][row]
        }
        return solution.allSatisfy { $0.isFinite } ? solution : nil
    }
}
