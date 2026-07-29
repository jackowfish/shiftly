import AVFoundation
import AppKit
import CoreMedia
import Vision

/// One frame of head and eye geometry, oriented like the desktop: +x right,
/// +y down, from the viewer's point of view.
struct GazeSample {
    /// Nose offset from the eye midpoint, in inter-ocular widths. Tracks yaw.
    var headX = 0.0
    /// Nose drop below the eye line, in inter-ocular widths. Tracks pitch, but
    /// carries a per-face baseline, so only changes in it mean anything.
    var headY = 0.0
    /// Pupil displacement from the eye centre, in half eye-widths, about -1...1.
    ///
    /// Both axes divide by the eye's *width*, including the vertical one. Eye
    /// height moves with the thing being measured — lids close as you look down,
    /// so the box shrinks exactly when the pupil drops, flattening the signal
    /// and amplifying its noise. Width is set by the corners, which don't move.
    var eyeX = 0.0
    var eyeY = 0.0
    /// How open the lids are, as eye height over inter-ocular distance.
    ///
    /// A second, independent read on the vertical axis, which is the one that
    /// costs window-level accuracy. Owes nothing to finding the pupil: it's
    /// measured across the whole eye contour rather than from one point inside a
    /// region a third as tall as it is wide. Worth 182px against 142px.
    var lidY = 0.0

    /// Head rotation as Vision reports it, in radians. Recorded in every capture
    /// but not fitted against; `GazeProfile.fitted` has the measurements.
    ///
    /// The old objection to these was that the sign convention is undocumented
    /// and flips with mirroring. That doesn't hold: every use compares a reading
    /// against labelled readings or a fit solved from them, and calibration
    /// absorbs an inverted sign without noticing.
    ///
    /// Only ever populated by a revision 3 rectangles pass. See `captureOutput`
    /// — getting that wrong yields plausible numbers rather than none.
    var faceYaw = 0.0
    var facePitch = 0.0
    var faceRoll = 0.0

    /// Every axis a reading carries, in stored and captured order. Enumerated
    /// once here rather than at each of the eight places a sample gets averaged,
    /// differenced, serialised or written to CSV.
    static let axes: [WritableKeyPath<GazeSample, Double>] =
        [\.headX, \.headY, \.eyeX, \.eyeY, \.lidY, \.faceYaw, \.facePitch, \.faceRoll]

    static let names = ["headX", "headY", "eyeX", "eyeY", "lidY", "faceYaw", "facePitch", "faceRoll"]

    /// A sample built by working out each axis independently, which is the
    /// shape of every mean, median and spread taken over a set of readings.
    static func perAxis(_ value: (WritableKeyPath<GazeSample, Double>) -> Double) -> GazeSample {
        var out = GazeSample()
        for axis in axes { out[keyPath: axis] = value(axis) }
        return out
    }
}

/// Front camera plus Vision face landmarks, on device. Runs only while
/// something is listening, so the camera light tracks actual use.
final class GazeTracker: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    static let shared = GazeTracker()

    /// Called on the main queue for every frame that found a face.
    var onSample: ((GazeSample) -> Void)?

    private(set) var isRunning = false

    /// Recent frames, newest last. Kept here rather than derived from the
    /// callback so whoever is listening can't change what a decision draws on.
    private var history: [(at: TimeInterval, sample: GazeSample)] = []

    /// Frames from the last `window` seconds, newest last.
    func recent(within window: TimeInterval) -> [GazeSample] {
        let cutoff = ProcessInfo.processInfo.systemUptime - window
        return history.filter { $0.at >= cutoff }.map(\.sample)
    }

    /// When the camera last saw a face at all, whatever it made of it.
    var lastFaceAt: TimeInterval { history.last?.at ?? 0 }

    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "com.jackdecker.shiftly.gaze")
    private let request = VNDetectFaceLandmarksRequest()
    private let rectangles = VNDetectFaceRectanglesRequest()
    private var configured = false
    private var mirrored = false
    private var lingerTimer: Timer?

    private override init() {
        super.init()
        // Revision 3 is the 76-point constellation, the one with pupils.
        request.revision = VNDetectFaceLandmarksRequestRevision3
        // Revision 3 is also the only one that computes pitch at all, and the
        // only one that reports any of the three angles continuously rather
        // than snapped to 45° buckets.
        rectangles.revision = VNDetectFaceRectanglesRequestRevision3
    }

    // MARK: Lifecycle

    /// Resolves camera permission, prompting the first time. Always calls back
    /// on the main queue.
    static func requestAccess(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        default:
            completion(false)
        }
    }

    /// Brings the camera up if it isn't already. Safe to call repeatedly.
    func start() {
        lingerTimer?.invalidate()
        lingerTimer = nil
        guard !isRunning else { return }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            beginSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted {
                        self.beginSession()
                    } else {
                        log("gaze: camera access denied")
                    }
                }
            }
        default:
            log("gaze: camera access denied, grant it in Privacy & Security > Camera")
        }
    }

    /// Drops the camera after a short grace period, so a burst of sessions
    /// doesn't restart it repeatedly.
    func stopSoon() {
        guard isRunning, !Settings.shared.gazeCameraAlwaysOn else { return }
        lingerTimer?.invalidate()
        lingerTimer = Timer.scheduledTimer(withTimeInterval: gazeCameraLinger, repeats: false) { [weak self] _ in
            self?.stop()
        }
    }

    func stop() {
        lingerTimer?.invalidate()
        lingerTimer = nil
        guard isRunning else { return }
        isRunning = false
        history = []
        queue.async { self.session.stopRunning() }
        log("gaze: camera stopped")
    }

    private func beginSession() {
        guard configure() else { return }
        isRunning = true
        history = []
        queue.async { self.session.startRunning() }
        log("gaze: camera started")
    }

    private func configure() -> Bool {
        if configured { return true }

        guard let device = AVCaptureDevice.default(for: .video) else {
            log("gaze: no video capture device")
            return false
        }
        guard let input = try? AVCaptureDeviceInput(device: device) else {
            log("gaze: could not open \(device.localizedName)")
            return false
        }

        session.beginConfiguration()
        // Pupil offset is measured inside an eye maybe thirty pixels across at
        // 720p, and the vertical half of that is where window-level accuracy is
        // lost. 1080p is 1.5x the pixels across the same eye, which is the one
        // improvement available that costs no calibration time.
        //
        // It does cost frame rate, since Vision then works over 2.25x the area.
        // The fps is in the debug trace for exactly this reason: the decision
        // takes a median of the newest three frames, so a halved rate doubles
        // the age of the oldest of them.
        for preset in [AVCaptureSession.Preset.hd1920x1080, .hd1280x720, .high]
        where session.canSetSessionPreset(preset) {
            session.sessionPreset = preset
            break
        }
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            log("gaze: could not add camera input")
            return false
        }
        session.addInput(input)

        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            log("gaze: could not add video output")
            return false
        }
        session.addOutput(output)

        // Mirror the feed so image-right is the viewer's right. Every sign in
        // the sample derivation below depends on this holding.
        if let connection = output.connection(with: .video), connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
            mirrored = true
        } else {
            mirrored = false
        }

        session.commitConfiguration()
        configured = true
        log("gaze: using \(device.localizedName), mirrored: \(mirrored)")
        return true
    }

    // MARK: Frames

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // Two passes on two separate handlers, and both details matter.
        //
        // Pose needs its own rectangles pass: a landmarks request runs an older
        // detector that snaps yaw to 45° buckets, roll to 30°, and computes no
        // pitch at all. Only revision 3 reports the angles continuously.
        //
        // They can't share a handler, because VNImageRequestHandler caches face
        // detection and serves the first request's answer to the second whatever
        // revision it asked for. That fails silently with plausible numbers: it
        // read as "Vision can't do this on this camera" for a while, revisions 1,
        // 2 and 3 agreeing precisely because only one of them ever ran.
        //
        // Seeding the landmarks request from the pose result would be cheaper
        // (2.6ms against 7.8ms, and one observation would carry both), but then
        // landmarks are fitted inside the rectangles detector's box instead of
        // their own, and every axis here is a ratio of landmark positions. That
        // raised per-frame jitter on all five, headX by 27%. Not worth 5ms.
        let poseHandler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up, options: [:])
        try? poseHandler.perform([rectangles])
        let pose = rectangles.results?.first

        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return
        }
        guard let face = request.results?.first,
              let sample = derive(from: face, pose: pose) else { return }

        DispatchQueue.main.async {
            let now = ProcessInfo.processInfo.systemUptime
            self.history.append((at: now, sample: sample))
            let cutoff = now - gazeHistoryWindow
            if let keep = self.history.firstIndex(where: { $0.at >= cutoff }), keep > 0 {
                self.history.removeFirst(keep)
            }
            self.onSample?(sample)
        }
    }

    /// Landmark points are normalized to the face's bounding box, so every
    /// ratio below is scale invariant, and Vision's y axis points up.
    private func derive(from face: VNFaceObservation, pose: VNFaceObservation?) -> GazeSample? {
        guard let landmarks = face.landmarks,
              let leftEye = landmarks.leftEye,
              let rightEye = landmarks.rightEye,
              let nose = landmarks.nose
        else { return nil }

        let leftCenter = centroid(leftEye)
        let rightCenter = centroid(rightEye)
        let eyeMid = CGPoint(x: (leftCenter.x + rightCenter.x) / 2,
                             y: (leftCenter.y + rightCenter.y) / 2)
        let interOcular = hypot(rightCenter.x - leftCenter.x, rightCenter.y - leftCenter.y)
        guard interOcular > 0.01 else { return nil }

        let noseCenter = centroid(nose)
        // Turning toward your right walks the nose to image-right in a mirrored
        // feed, hence +x. The nose sits below the eye line, so the raw vertical
        // ratio is negative; flipping it makes larger mean "looking further down".
        let flip = mirrored ? 1.0 : -1.0
        let headX = flip * Double((noseCenter.x - eyeMid.x) / interOcular)
        let headY = Double((eyeMid.y - noseCenter.y) / interOcular)

        var eyeX = 0.0
        var eyeY = 0.0
        var eyeCount = 0.0
        // Aperture is measured whether or not the pupil was found, since it
        // needs only the eye contour. A blink that loses the pupil still says
        // something about where you're looking.
        var lidY = 0.0
        var lidCount = 0.0
        for (region, pupil) in [(leftEye, landmarks.leftPupil), (rightEye, landmarks.rightPupil)] {
            let box = bounds(of: region)
            guard box.width > 0.001, box.height > 0.001 else { continue }
            lidY += Double(box.height / interOcular)
            lidCount += 1

            guard let pupil, let point = pupil.normalizedPoints.first else { continue }
            eyeX += flip * Double((CGFloat(point.x) - box.midX) / (box.width / 2))
            // Vision's y is up, the desktop's is down. Divided by width, not
            // height: see the note on GazeSample.eyeY.
            eyeY += Double((box.midY - CGFloat(point.y)) / (box.width / 2))
            eyeCount += 1
        }
        if eyeCount > 0 {
            eyeX = clamp(eyeX / eyeCount, to: 1.5)
            eyeY = clamp(eyeY / eyeCount, to: 1.5)
        }
        if lidCount > 0 { lidY /= lidCount }

        var sample = GazeSample(headX: headX, headY: headY, eyeX: eyeX, eyeY: eyeY, lidY: lidY)
        // Flipped to match the desktop convention the rest of the sample uses,
        // so the debug trace reads sensibly. Nothing downstream depends on it:
        // every coefficient these feed is solved from calibration, which
        // absorbs a sign. A missing angle stays 0, and a constant axis is
        // dropped from the fit rather than making it singular.
        sample.faceYaw = flip * (pose?.yaw?.doubleValue ?? 0)
        sample.facePitch = pose?.pitch?.doubleValue ?? 0
        sample.faceRoll = flip * (pose?.roll?.doubleValue ?? 0)
        return sample
    }

    private func centroid(_ region: VNFaceLandmarkRegion2D) -> CGPoint {
        let points = region.normalizedPoints
        guard !points.isEmpty else { return .zero }
        var sum = CGPoint.zero
        for point in points {
            sum.x += CGFloat(point.x)
            sum.y += CGFloat(point.y)
        }
        return CGPoint(x: sum.x / CGFloat(points.count), y: sum.y / CGFloat(points.count))
    }

    private func bounds(of region: VNFaceLandmarkRegion2D) -> CGRect {
        let points = region.normalizedPoints
        guard let first = points.first else { return .zero }
        var minX = CGFloat(first.x), maxX = CGFloat(first.x)
        var minY = CGFloat(first.y), maxY = CGFloat(first.y)
        for point in points.dropFirst() {
            minX = min(minX, CGFloat(point.x))
            maxX = max(maxX, CGFloat(point.x))
            minY = min(minY, CGFloat(point.y))
            maxY = max(maxY, CGFloat(point.y))
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func clamp(_ value: Double, to limit: Double) -> Double {
        min(max(value, -limit), limit)
    }
}
