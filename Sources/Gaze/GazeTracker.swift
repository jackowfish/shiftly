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
    /// height moves with the thing being measured - lids close as you look down,
    /// so the box shrinks exactly when the pupil drops, flattening the signal
    /// and amplifying its noise. Width is set by the corners, which do not move.
    var eyeX = 0.0
    var eyeY = 0.0
    /// How open the lids are, as eye height over inter-ocular distance.
    ///
    /// A second, independent read on the vertical axis, which is the one that
    /// costs window-level accuracy. Owes nothing to finding the pupil: it is
    /// measured across the whole eye contour, not from one point inside a
    /// region a third as tall as it is wide. Worth 182px against 142px.
    var lidY = 0.0

    /// Head rotation as Vision reports it, in radians. Recorded in every capture
    /// but not fitted against; `GazeProfile.fitted` has the measurements.
    ///
    /// The old objection to these was that the sign convention is undocumented
    /// and flips with mirroring. That does not hold: every use compares a reading
    /// against labelled readings or a fit solved from them, and calibration
    /// absorbs an inverted sign without noticing.
    ///
    /// Populated only by a revision 3 rectangles pass. See `captureOutput`
    /// - getting that wrong yields plausible numbers, not none.
    var faceYaw = 0.0
    var facePitch = 0.0
    var faceRoll = 0.0

    /// Pupil displacement from the midpoint of the eye's two corners, per eye,
    /// in half inter-corner widths, with the axes rotated to follow the eye
    /// line. Recorded but not yet fitted, like the pose angles: the gaze
    /// literature anchors the pupil to the corners because they are rigid - the
    /// eye's bounding box tracks the lids, which move with vertical gaze, and
    /// that coupling is systematic error the current features cannot remove.
    /// Whether these earn a place in the fit is decided the same way the pose
    /// angles were: captures first, then `tools/gaze_eval.py`.
    var eyeLX = 0.0
    var eyeLY = 0.0
    var eyeRX = 0.0
    var eyeRY = 0.0

    /// Where the face sits in the frame and how large it is, from the landmark
    /// observation's bounding box. Head translation and camera distance in
    /// other words - axes nothing else here measures. `headX` conflates
    /// sliding your chair with turning your head; these separate the two.
    /// Recorded, not fitted, same policy as above.
    var faceX = 0.0
    var faceY = 0.0
    var faceSize = 0.0

    /// Every axis a reading carries, in stored and captured order. Enumerated
    /// once here, not at each of the eight places a sample gets averaged,
    /// differenced, serialised or written to CSV. New axes go at the end, so a
    /// capture's columns stay a prefix of any later version's.
    static let axes: [WritableKeyPath<GazeSample, Double>] =
        [\.headX, \.headY, \.eyeX, \.eyeY, \.lidY, \.faceYaw, \.facePitch, \.faceRoll,
         \.eyeLX, \.eyeLY, \.eyeRX, \.eyeRY, \.faceX, \.faceY, \.faceSize]

    static let names = ["headX", "headY", "eyeX", "eyeY", "lidY", "faceYaw", "facePitch", "faceRoll",
                        "eyeLX", "eyeLY", "eyeRX", "eyeRY", "faceX", "faceY", "faceSize"]

    /// A sample built by working out each axis independently, which is the
    /// shape of every mean, median and spread taken over a set of readings.
    static func perAxis(_ value: (WritableKeyPath<GazeSample, Double>) -> Double) -> GazeSample {
        var out = GazeSample()
        for axis in axes { out[keyPath: axis] = value(axis) }
        return out
    }
}

/// Front camera plus Vision face landmarks, on device. Runs only while
/// something listens, so the camera light tracks actual use.
final class GazeTracker: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    static let shared = GazeTracker()

    /// Called on the main queue for every frame that found a face.
    var onSample: ((GazeSample) -> Void)?

    private(set) var isRunning = false

    /// Recent frames, newest last. Kept here, not derived from the
    /// callback so a listener cannot change what a decision draws on.
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

    // MARK: Health

    /// The device the session was configured on, held so a disconnect
    /// notification can be matched against it.
    private var device: AVCaptureDevice?

    /// Whether anyone wants the camera up, as distinct from whether it is.
    /// Unplugging a dock mid-run can leave `isRunning` false with nobody
    /// having called stop(); the reconnect path uses this to come back.
    private var wantsCamera = false

    /// Uptime of the last frame delivered, face or not. `isRunning` says the
    /// session was told to run; this says frames actually arrive. A dock
    /// disconnect used to fail exactly in that gap - the session looked fine
    /// and delivered nothing until the app was relaunched.
    private var lastFrameAt: TimeInterval = 0
    private var startedAt: TimeInterval = 0
    private var healthTimer: Timer?
    private var lastRebuildAt: TimeInterval = 0
    private var rebuilding = false

    /// Consecutive black frames so far, and whether the run is long enough to
    /// call the feed dead. Black is a real failure mode: a camera that half
    /// survives a dock change keeps streaming frames with nothing in them,
    /// which "no face visible" misdiagnoses.
    private var blackFrames = 0
    private(set) var blackedOut = false

    private override init() {
        super.init()
        // Revision 3 is the 76-point constellation, the one with pupils.
        request.revision = VNDetectFaceLandmarksRequestRevision3
        // Revision 3 is also the only one that computes pitch at all, and the
        // only one that reports any of the three angles continuously, not
        // snapped to 45° buckets.
        rectangles.revision = VNDetectFaceRectanglesRequestRevision3

        // The dock cases. Losing the device in use rebuilds onto whatever
        // remains; a camera arriving rebuilds onto the new default, so
        // re-docking hands the feed back to the camera the profile was
        // calibrated against instead of staying on the fallback.
        let center = NotificationCenter.default
        center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification,
                           object: nil, queue: .main) { [weak self] note in
            guard let self, let gone = note.object as? AVCaptureDevice, gone == self.device else { return }
            self.rebuild("\(gone.localizedName) disconnected")
        }
        center.addObserver(forName: AVCaptureDevice.wasConnectedNotification,
                           object: nil, queue: .main) { [weak self] note in
            guard let self, self.wantsCamera,
                  let arrived = note.object as? AVCaptureDevice, arrived.hasMediaType(.video),
                  GazeTracker.isAllowed(arrived) else { return }
            if !self.isRunning || self.pickDevice() != self.device {
                self.rebuild("\(arrived.localizedName) connected")
            }
        }
        center.addObserver(forName: AVCaptureSession.runtimeErrorNotification,
                           object: session, queue: .main) { [weak self] note in
            guard let self, self.wantsCamera else { return }
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
            self.rebuild("session error: \(error?.localizedDescription ?? "unknown")")
        }
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

    /// Brings the camera up if it is not already. Safe to call repeatedly.
    func start() {
        lingerTimer?.invalidate()
        lingerTimer = nil
        wantsCamera = true
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
    /// does not restart it repeatedly.
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
        wantsCamera = false
        healthTimer?.invalidate()
        healthTimer = nil
        blackFrames = 0
        blackedOut = false
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
        startedAt = ProcessInfo.processInfo.systemUptime
        lastFrameAt = 0
        blackFrames = 0
        blackedOut = false
        queue.async { self.session.startRunning() }
        healthTimer?.invalidate()
        healthTimer = scheduleTimer(after: 1.0, repeats: true) { [weak self] in self?.checkHealth() }
        log("gaze: camera started")
    }

    /// Tears the session down to nothing and brings it back on the current
    /// default camera. Every recovery path funnels through here: device gone,
    /// device arrived, session error, stalled frames, black frames.
    private func rebuild(_ reason: String) {
        guard !rebuilding else { return }
        rebuilding = true
        lastRebuildAt = ProcessInfo.processInfo.systemUptime
        log("gaze: restarting camera (\(reason))")
        isRunning = false
        history = []
        configured = false
        device = nil
        blackFrames = 0
        blackedOut = false
        healthTimer?.invalidate()
        healthTimer = nil
        queue.async {
            self.session.stopRunning()
            self.session.beginConfiguration()
            for input in self.session.inputs { self.session.removeInput(input) }
            for output in self.session.outputs { self.session.removeOutput(output) }
            self.session.commitConfiguration()
            DispatchQueue.main.async {
                self.rebuilding = false
                // If configure() fails here - the camera left with the dock -
                // the connected notification retries when one returns.
                if self.wantsCamera { self.beginSession() }
            }
        }
    }

    /// The watchdog for failures no notification announces. A session that
    /// stops delivering, or delivers only black, is indistinguishable from a
    /// healthy one to every other code path.
    private func checkHealth() {
        guard isRunning, !rebuilding else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastRebuildAt > gazeCameraRetryEvery else { return }
        let lastSeen = max(lastFrameAt, startedAt)
        if now - lastSeen > gazeCameraStallAfter {
            rebuild("no frames for \(Int(now - lastSeen))s")
        } else if blackedOut {
            rebuild("feed is black")
        }
    }

    /// Per-frame health bookkeeping, on the main queue so the watchdog and
    /// the menu read consistent state.
    private func noteFrame(luminance: Double) {
        lastFrameAt = ProcessInfo.processInfo.systemUptime
        if luminance < gazeCameraBlackLevel {
            blackFrames += 1
            if blackFrames == gazeCameraBlackFrames {
                blackedOut = true
                log("gaze: camera feed has gone black")
            }
        } else if blackFrames > 0 {
            if blackedOut { log("gaze: camera feed is back") }
            blackFrames = 0
            blackedOut = false
        }
    }

    /// Mean brightness over a sparse grid, 0...1. Sixty-four pixels of a
    /// BGRA frame - little enough work to run on every frame before Vision.
    private func meanLuminance(of buffer: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return 0 }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        guard width > 0, height > 0 else { return 0 }
        let data = base.assumingMemoryBound(to: UInt8.self)
        var total = 0
        var count = 0
        for row in stride(from: height / 16, to: height, by: max(1, height / 8)) {
            for col in stride(from: width / 16, to: width, by: max(1, width / 8)) {
                let pixel = row * rowBytes + col * 4
                total += Int(data[pixel]) + Int(data[pixel + 1]) + Int(data[pixel + 2])
                count += 3
            }
        }
        return count > 0 ? Double(total) / Double(count) / 255 : 0
    }

    /// Every camera currently connected, for the menu and the picker.
    /// External cameras first: a webcam present at the desk is there on
    /// purpose, and the built-in camera sees the lid, not the desk, in
    /// clamshell mode.
    static func allCameras() -> [AVCaptureDevice] {
        let types: [AVCaptureDevice.DeviceType]
        if #available(macOS 14.0, *) {
            types = [.external, .continuityCamera, .builtInWideAngleCamera]
        } else {
            types = [.externalUnknown, .builtInWideAngleCamera]
        }
        return AVCaptureDevice.DiscoverySession(
            deviceTypes: types, mediaType: .video, position: .unspecified).devices
    }

    /// Whether the menu's camera list permits this device. An explicit choice
    /// wins; a camera never toggled defaults to allowed unless it looks
    /// virtual. OBS and its kind register cameras that replay whatever their
    /// app feeds them - no face, and pure black while the app is idle - and
    /// the tracker once attached to one and sat blind until relaunch, so they
    /// start deselected. The menu can still turn one on deliberately.
    static func isAllowed(_ device: AVCaptureDevice) -> Bool {
        if let choice = Settings.shared.gazeCameraChoices[device.uniqueID] { return choice }
        return !isVirtual(device)
    }

    /// The same rule for a camera known only by its remembered name, which is
    /// all the menu has for one that is not connected right now.
    static func isAllowed(id: String, name: String) -> Bool {
        if let choice = Settings.shared.gazeCameraChoices[id] { return choice }
        return !name.lowercased().contains("virtual")
    }

    /// Matches by name and model because there is no API-level marker: a
    /// camera extension looks exactly like a USB webcam to AVFoundation.
    private static func isVirtual(_ device: AVCaptureDevice) -> Bool {
        let name = device.localizedName.lowercased()
        let model = device.modelID.lowercased()
        return name.contains("virtual") || model.contains("virtual") || model.contains("obs")
    }

    /// The camera to use: the system default when the menu allows it, the
    /// first allowed camera otherwise, or nil - in which case tracking stays
    /// off until an allowed camera returns.
    private func pickDevice() -> AVCaptureDevice? {
        if let preferred = AVCaptureDevice.default(for: .video), GazeTracker.isAllowed(preferred) {
            return preferred
        }
        return GazeTracker.allCameras().first { GazeTracker.isAllowed($0) }
    }

    /// Re-evaluates the camera after a menu toggle. Deselecting the one in
    /// use switches to another allowed camera, or shuts the feed off when
    /// none is connected; selecting one while the tracker sits waiting
    /// brings it up.
    func cameraChoicesChanged() {
        guard wantsCamera else { return }
        if isRunning {
            if let device, GazeTracker.isAllowed(device), pickDevice() == device { return }
            rebuild("camera selection changed")
        } else {
            start()
        }
    }

    private func configure() -> Bool {
        if configured { return true }

        guard let device = pickDevice() else {
            log("gaze: no usable video capture device")
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
        self.device = device
        log("gaze: using \(device.localizedName), mirrored: \(mirrored)")
        return true
    }

    // MARK: Frames

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let luminance = meanLuminance(of: buffer)
        DispatchQueue.main.async { self.noteFrame(luminance: luminance) }
        // A black frame has no face in it. Skipping Vision keeps a dead feed
        // from burning two detector passes per frame while it lasts.
        guard luminance >= gazeCameraBlackLevel else { return }

        // Two passes on two separate handlers, and both details matter.
        //
        // Pose needs its own rectangles pass: a landmarks request runs an older
        // detector that snaps yaw to 45° buckets, roll to 30°, and computes no
        // pitch at all. Only revision 3 reports the angles continuously.
        //
        // They cannot share a handler, because VNImageRequestHandler caches face
        // detection and serves the first request's answer to the second whatever
        // revision it asked for. That fails silently with plausible numbers: it
        // read as "Vision cannot do this on this camera" for a while, revisions 1,
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
        // Aperture is measured even when the pupil was not found, since it
        // needs only the eye contour. A blink that loses the pupil still says
        // something about where you are looking.
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
        // dropped from the fit instead of making it singular.
        sample.faceYaw = flip * (pose?.yaw?.doubleValue ?? 0)
        sample.facePitch = pose?.pitch?.doubleValue ?? 0
        sample.faceRoll = flip * (pose?.roll?.doubleValue ?? 0)

        // The corner-anchored reads. Anchoring to the corner midpoint and
        // rotating the axes onto the corner line makes them roll-free and
        // lid-free by construction; a missing pupil leaves them 0, which the
        // fit drops as a dead column instead of mismeasuring.
        if let read = cornerOffset(leftEye, pupil: landmarks.leftPupil, flip: flip) {
            sample.eyeLX = read.x
            sample.eyeLY = read.y
        }
        if let read = cornerOffset(rightEye, pupil: landmarks.rightPupil, flip: flip) {
            sample.eyeRX = read.x
            sample.eyeRY = read.y
        }

        // The landmark observation's box, not the pose pass's, so the axes stay
        // measured even on a frame where the second detector found nothing.
        let box = face.boundingBox
        sample.faceX = flip * Double(box.midX - 0.5)
        sample.faceY = Double(0.5 - box.midY)
        sample.faceSize = Double(box.width)
        return sample
    }

    /// Pupil displacement from the midpoint of the eye's corners, in half
    /// inter-corner widths, with x running along the eye line and y
    /// perpendicular to it, positive downward like the rest of the sample.
    ///
    /// The corners are taken as the contour's horizontal extremes, which holds
    /// for Vision's eye regions across the poses a desk allows: the corners
    /// are the widest points of the eye opening unless the head rolls past
    /// ±45°, where tracking has already lost the plot for other reasons.
    private func cornerOffset(_ region: VNFaceLandmarkRegion2D,
                              pupil: VNFaceLandmarkRegion2D?,
                              flip: Double) -> (x: Double, y: Double)? {
        let points = region.normalizedPoints
        guard points.count >= 2,
              let inner = points.min(by: { $0.x < $1.x }),
              let outer = points.max(by: { $0.x < $1.x }),
              let point = pupil?.normalizedPoints.first
        else { return nil }

        let axisX = Double(outer.x - inner.x)
        let axisY = Double(outer.y - inner.y)
        let width = (axisX * axisX + axisY * axisY).squareRoot()
        guard width > 0.001 else { return nil }

        let dx = Double(point.x) - Double(inner.x + outer.x) / 2
        let dy = Double(point.y) - Double(inner.y + outer.y) / 2
        // Project onto the eye line and its perpendicular. Vision's y points
        // up, so the perpendicular component is positive upward; the sign
        // flips to make larger mean "looking further down".
        let along = (dx * axisX + dy * axisY) / width
        let across = (-dx * axisY + dy * axisX) / width
        return (x: flip * along / (width / 2), y: -across / (width / 2))
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
