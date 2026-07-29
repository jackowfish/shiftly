import AVFoundation
import AppKit
import CoreMedia
import Vision

/// One frame of head and eye geometry, oriented like the desktop: +x right,
/// +y down, from the viewer's point of view.
///
/// Head rotation comes from landmark ratios rather than `VNFaceObservation.yaw`
/// and `.pitch`. Those are better conditioned, but their sign convention is
/// undocumented and flips with mirroring, and a tracker that snaps windows to
/// the wrong side of the desk is worse than one that's slightly less linear.
/// Nose-relative-to-eye-line has a sign we can derive from first principles.
struct GazeSample {
    /// Nose offset from the eye midpoint, in inter-ocular widths. Tracks yaw.
    var headX: Double
    /// Nose drop below the eye line, in inter-ocular widths. Tracks pitch, but
    /// carries a per-face baseline, so only changes in it mean anything.
    var headY: Double
    /// Pupil displacement inside the eye opening, about -1...1.
    var eyeX: Double
    var eyeY: Double
}

/// Front camera plus Vision face landmarks, on device. Runs only while
/// something is listening, so the camera light tracks actual use.
final class GazeTracker: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    static let shared = GazeTracker()

    /// Called on the main queue for every frame that found a face.
    var onSample: ((GazeSample) -> Void)?

    /// Raw, unsmoothed samples, for the calibrator to average itself.
    var onRawSample: ((GazeSample) -> Void)?

    private(set) var isRunning = false

    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "com.jackdecker.shiftly.gaze")
    private let request = VNDetectFaceLandmarksRequest()
    private var configured = false
    private var mirrored = false
    private var smoothed: GazeSample?
    private var lingerTimer: Timer?

    private override init() {
        super.init()
        // Revision 3 is the 76-point constellation, the one with pupils.
        request.revision = VNDetectFaceLandmarksRequestRevision3
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
        smoothed = nil
        queue.async { self.session.stopRunning() }
        log("gaze: camera stopped")
    }

    private func beginSession() {
        guard configure() else { return }
        isRunning = true
        smoothed = nil
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
        // 720p is the sweet spot: enough pixels across the eye for the pupil
        // term to mean something, few enough that Vision keeps up at 30fps.
        session.sessionPreset = session.canSetSessionPreset(.hd1280x720) ? .hd1280x720 : .high
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

        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return
        }
        guard let face = request.results?.first, let sample = derive(from: face) else { return }

        DispatchQueue.main.async {
            self.onRawSample?(sample)
            let blended = self.blend(sample)
            self.onSample?(blended)
        }
    }

    private func blend(_ sample: GazeSample) -> GazeSample {
        guard let previous = smoothed else {
            smoothed = sample
            return sample
        }
        let alpha = gazeSmoothing
        let next = GazeSample(
            headX: previous.headX + alpha * (sample.headX - previous.headX),
            headY: previous.headY + alpha * (sample.headY - previous.headY),
            eyeX: previous.eyeX + alpha * (sample.eyeX - previous.eyeX),
            eyeY: previous.eyeY + alpha * (sample.eyeY - previous.eyeY))
        smoothed = next
        return next
    }

    /// Landmark points are normalized to the face's bounding box, so every
    /// ratio below is scale invariant, and Vision's y axis points up.
    private func derive(from face: VNFaceObservation) -> GazeSample? {
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
        for (region, pupil) in [(leftEye, landmarks.leftPupil), (rightEye, landmarks.rightPupil)] {
            guard let pupil, let point = pupil.normalizedPoints.first else { continue }
            let box = bounds(of: region)
            guard box.width > 0.001, box.height > 0.001 else { continue }
            eyeX += flip * Double((CGFloat(point.x) - box.midX) / (box.width / 2))
            // Vision's y is up, the desktop's is down.
            eyeY += Double((box.midY - CGFloat(point.y)) / (box.height / 2))
            eyeCount += 1
        }
        if eyeCount > 0 {
            eyeX = clamp(eyeX / eyeCount, to: 1.5)
            eyeY = clamp(eyeY / eyeCount, to: 1.5)
        }

        return GazeSample(headX: headX, headY: headY, eyeX: eyeX, eyeY: eyeY)
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
