import AppKit

/// One calibration reading: what the camera saw while you looked at a known
/// display.
struct GazeReference {
    let display: CGDirectDisplayID
    let sample: GazeSample
}

/// What "looking at that display" measures like, learned from calibration.
///
/// This replaced a linear map from face geometry to desktop coordinates. That
/// map had to be told which way round the camera was mounted and how far a face
/// turns before it means anything, which is where the Flip Horizontal control
/// came from. Since the only question ever asked is which display, none of that
/// is needed: label a handful of readings per display and take the nearest one.
/// Mirroring, mounting, and how far you personally turn your head all fall out
/// of the labels for free, with nothing left for anyone to configure.
///
/// Nearest reading rather than nearest average, because an ultrawide is wide
/// enough that looking at its left edge and its right edge are quite different
/// readings, and an average of the two can land closer to the display next door.
struct GazeProfile {
    let references: [GazeReference]

    var displays: Set<CGDirectDisplayID> { Set(references.map(\.display)) }

    /// The display being looked at, or nil when it's too close to call.
    func display(for sample: GazeSample) -> CGDirectDisplayID? {
        var closest: [CGDirectDisplayID: Double] = [:]
        for reference in references {
            let measured = distance(sample, reference.sample)
            closest[reference.display] = min(closest[reference.display] ?? .greatestFiniteMagnitude, measured)
        }

        let ranked = closest.sorted { $0.value < $1.value }
        guard let winner = ranked.first else { return nil }
        guard ranked.count > 1 else { return winner.key }
        // Has to win clearly. A coin flip between two displays should leave
        // focus alone rather than pick one.
        guard winner.value <= ranked[1].value * gazeMargin else { return nil }
        return winner.key
    }

    /// Each axis is divided by its own plausible range first, so the pupil
    /// terms (which swing over a much wider numeric range than head rotation)
    /// don't dominate the comparison.
    private func distance(_ a: GazeSample, _ b: GazeSample) -> Double {
        let headX = (a.headX - b.headX) / gazeHeadXSpan * gazeHeadWeight
        let headY = (a.headY - b.headY) / gazeHeadYSpan * gazeHeadWeight
        let eyeX = (a.eyeX - b.eyeX) / gazeEyeSpan * gazeEyeWeight
        let eyeY = (a.eyeY - b.eyeY) / gazeEyeSpan * gazeEyeWeight
        return (headX * headX + headY * headY + eyeX * eyeX + eyeY * eyeY).squareRoot()
    }

    // MARK: Storage

    /// Flattened as one row per reading: display id, then the four axes.
    var storage: [[Double]] {
        references.map {
            [Double($0.display), $0.sample.headX, $0.sample.headY, $0.sample.eyeX, $0.sample.eyeY]
        }
    }

    init(references: [GazeReference]) {
        self.references = references
    }

    init?(storage: [[Double]]) {
        guard !storage.isEmpty else { return nil }
        var parsed: [GazeReference] = []
        for row in storage {
            guard row.count == 5 else { return nil }
            parsed.append(GazeReference(
                display: CGDirectDisplayID(row[0]),
                sample: GazeSample(headX: row[1], headY: row[2], eyeX: row[3], eyeY: row[4])))
        }
        self.init(references: parsed)
    }
}
