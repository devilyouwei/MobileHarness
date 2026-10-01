#if os(iOS)
    import AVFoundation
    import Foundation

    public enum CameraFacing: Sendable, Equatable { case front, back }
    public enum CameraEvent: Sendable { case interrupted, interruptionEnded, failed }
    public enum CameraError: Error, Equatable { case permissionDenied, unavailable, configurationFailed, startFailed }

    /// The only cross-isolation session bridge. The capture actor exclusively mutates the
    /// session graph; MainActor only binds that session to Apple's preview layer.
    public final class CameraPreviewSource: @unchecked Sendable {
        fileprivate let session: AVCaptureSession
        fileprivate let receiver: CameraFrameReceiver
        fileprivate init(session: AVCaptureSession, receiver: CameraFrameReceiver) {
            self.session = session
            self.receiver = receiver
        }
        @MainActor
        public func setCaptureRotation(_ angle: CGFloat) {
            receiver.setRotation(Self.quarterTurns(angle))
        }
        @MainActor
        public static func quarterTurns(_ angle: CGFloat) -> Int {
            ((Int((angle / 90).rounded()) % 4) + 4) % 4
        }

        @MainActor
        public func connect(_ layer: AVCaptureVideoPreviewLayer) {
            layer.session = session
        }

        @MainActor
        public func rotationCoordinator(
            facing: CameraFacing, layer: AVCaptureVideoPreviewLayer
        ) -> AVCaptureDevice.RotationCoordinator? {
            guard
                let device = AVCaptureDevice.default(
                    .builtInWideAngleCamera, for: .video, position: facing == .front ? .front : .back)
            else { return nil }
            return AVCaptureDevice.RotationCoordinator(device: device, previewLayer: layer)
        }
    }

    /// Camera preview and bounded RGB capture; no audio input, recording or model/business logic.
    public actor AppleCamera {
        public nonisolated let preview: CameraPreviewSource
        public nonisolated let events: AsyncStream<CameraEvent>
        private let continuation: AsyncStream<CameraEvent>.Continuation
        private let session: AVCaptureSession
        private var input: AVCaptureDeviceInput?
        private let videoOutput = AVCaptureVideoDataOutput()
        private let receiver: CameraFrameReceiver
        private let frameQueue = DispatchQueue(label: "dev.mobileharness.camera.frames", qos: .userInitiated)
        private var outputInstalled = false
        private var observers: [CameraObservation] = []

        public init() {
            let session = AVCaptureSession()
            session.automaticallyConfiguresApplicationAudioSession = false
            self.session = session
            let receiver = CameraFrameReceiver()
            self.receiver = receiver
            preview = CameraPreviewSource(session: session, receiver: receiver)
            let stream = AsyncStream<CameraEvent>.makeStream(bufferingPolicy: .bufferingNewest(1))
            events = stream.stream
            continuation = stream.continuation
        }

        deinit {
            continuation.finish()
        }

        public nonisolated static func requestPermission() async -> Bool {
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: return true
            case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
            default: return false
            }
        }

        /// No suspension inside graph mutation/start/stop; all operations are actor serialized.
        public func start(facing: CameraFacing) throws -> AsyncThrowingStream<CameraFrame, Error> {
            guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
                throw CameraError.permissionDenied
            }
            stop()
            frameQueue.sync {}  // Drain old-lens callbacks before opening another capture stream.
            installObservers()
            let position: AVCaptureDevice.Position = facing == .front ? .front : .back
            if input?.device.position != position {
                guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
                else { throw CameraError.unavailable }
                let replacement = try AVCaptureDeviceInput(device: device)
                session.beginConfiguration()
                if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }
                let previous = input
                if let previous { session.removeInput(previous) }
                guard session.canAddInput(replacement) else {
                    if let previous, session.canAddInput(previous) { session.addInput(previous) }
                    session.commitConfiguration()
                    throw CameraError.configurationFailed
                }
                session.addInput(replacement)
                input = replacement
                session.commitConfiguration()
            }
            if !outputInstalled {
                session.beginConfiguration()
                videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                videoOutput.alwaysDiscardsLateVideoFrames = true
                guard session.canAddOutput(videoOutput) else {
                    session.commitConfiguration()
                    throw CameraError.configurationFailed
                }
                session.addOutput(videoOutput)
                videoOutput.setSampleBufferDelegate(receiver, queue: frameQueue)
                session.commitConfiguration()
                outputInstalled = true
            }
            if let connection = videoOutput.connection(with: .video) {
                if connection.isVideoRotationAngleSupported(0) { connection.videoRotationAngle = 0 }
                if connection.isVideoMirroringSupported {
                    connection.automaticallyAdjustsVideoMirroring = false
                    connection.isVideoMirrored = false
                }
            }
            let frames = receiver.begin()
            if !session.isRunning { session.startRunning() }
            guard session.isRunning, !session.isInterrupted else {
                receiver.finish()
                throw CameraError.startFailed
            }
            return frames
        }

        public func stop() {
            receiver.finish()
            if session.isRunning { session.stopRunning() }
        }

        public func isRunning() -> Bool { session.isRunning && !session.isInterrupted }

        private func installObservers() {
            guard observers.isEmpty else { return }
            let continuation = continuation
            for (name, event) in [
                (AVCaptureSession.wasInterruptedNotification, CameraEvent.interrupted),
                (AVCaptureSession.interruptionEndedNotification, CameraEvent.interruptionEnded),
                (AVCaptureSession.runtimeErrorNotification, CameraEvent.failed),
            ] {
                observers.append(
                    CameraObservation(
                        NotificationCenter.default.addObserver(forName: name, object: session, queue: nil) { _ in
                            continuation.yield(event)
                        }))
            }
        }
    }
    /// Immutable token; NotificationCenter permits removal from any thread.
    private final class CameraObservation: @unchecked Sendable {
        let token: NSObjectProtocol
        init(_ token: NSObjectProtocol) { self.token = token }
        deinit { NotificationCenter.default.removeObserver(token) }
    }
#endif
