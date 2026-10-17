#if os(iOS)
    import AVFoundation
    import Synchronization
    import Foundation

    /// Callback-owned state; only terminal capture resumes the caller once.
    private final class PhotoReceiver: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Data, Error>?
        private var data: Data?
        private var failed = false
        func begin(_ continuation: CheckedContinuation<Data, Error>) {
            lock.withLock { self.continuation = continuation }
        }
        func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?)
        {
            lock.withLock {
                failed = error != nil
                data = photo.fileDataRepresentation()
            }
        }
        func photoOutput(
            _ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
            error: Error?
        ) {
            let result: (CheckedContinuation<Data, Error>?, Data?, Bool) = lock.withLock {
                let result = (continuation, data, failed || error != nil)
                continuation = nil
                data = nil
                return result
            }
            guard let continuation = result.0 else { return }
            if !result.2, let data = result.1 {
                continuation.resume(returning: data)
            } else {
                continuation.resume(throwing: CameraError.photoFailed)
            }
        }
    }

    /// Read-only capture geometry, independent of any preview layer or page.
    public final class CameraCaptureOrientation: Sendable {
        private let state = Mutex((angle: CGFloat(0), generation: UUID().uuidString))
        private let receiver: CameraFrameReceiver
        fileprivate init(receiver: CameraFrameReceiver) { self.receiver = receiver }
        public var captureRotation: CGFloat { state.withLock { $0.angle } }
        fileprivate func bind() -> String {
            state.withLock {
                $0.generation = UUID().uuidString
                return $0.generation
            }
        }
        fileprivate func invalidate() { _ = bind() }
        fileprivate func update(_ value: CGFloat, generation: String) {
            state.withLock {
                guard $0.generation == generation else { return }
                $0.angle = value
                receiver.setRotation(((Int((value / 90).rounded()) % 4) + 4) % 4)
            }
        }
    }

    /// Camera preview and bounded RGB capture; no audio input, recording or model/business logic.
    public actor AppleCamera: CameraCapturing {
        public nonisolated var captureRotation: CGFloat { orientation.captureRotation }
        public nonisolated func requestPermission() async -> Bool { await Self.requestPermission() }
        public nonisolated let orientation: CameraCaptureOrientation
        public nonisolated let events: AsyncStream<CameraEvent>
        private let continuation: AsyncStream<CameraEvent>.Continuation
        private let session: AVCaptureSession
        private var input: AVCaptureDeviceInput?
        private let videoOutput = AVCaptureVideoDataOutput()
        private let photoOutput = AVCapturePhotoOutput()
        private var photoOutputInstalled = false
        private var photoTask: Task<Data, Error>?
        private var mediaID: String?
        private var photoTimedOut = false
        private let receiver: CameraFrameReceiver
        private let frameQueue = DispatchQueue(label: "dev.mobileharness.camera.frames", qos: .userInitiated)
        private var outputInstalled = false
        private var observers: [CameraObservation] = []
        private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
        private var rotationObservation: NSKeyValueObservation?

        private let admission: PlatformAdmission?
        public init(admission: PlatformAdmission? = nil) {
            self.admission = admission
            let session = AVCaptureSession()
            session.automaticallyConfiguresApplicationAudioSession = false
            self.session = session
            let receiver = CameraFrameReceiver()
            self.receiver = receiver
            orientation = CameraCaptureOrientation(receiver: receiver)
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
        public func subscribeFrames() throws -> AsyncThrowingStream<CameraFrame, Error> {
            try admission?.check()
            return try receiver.subscribe()
        }
        public func start(facing: CameraFacing) throws -> AsyncThrowingStream<CameraFrame, Error> {
            try admission?.check()
            guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
                throw CameraError.permissionDenied
            }
            guard photoTask == nil else { throw CameraError.photoBusy }
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
            if !photoOutputInstalled {
                session.beginConfiguration()
                guard session.canAddOutput(photoOutput) else {
                    session.commitConfiguration()
                    throw CameraError.configurationFailed
                }
                session.addOutput(photoOutput)
                session.commitConfiguration()
                photoOutputInstalled = true
            }
            frameQueue.sync {}
            configureFrameConnection()
            let frames = receiver.begin()
            if !session.isRunning { session.startRunning() }
            guard session.isRunning, !session.isInterrupted else {
                receiver.finish()
                throw CameraError.startFailed
            }
            return frames
        }

        /// Keep a healthy session/output graph running; only replace its video input.
        public func switchCamera(facing: CameraFacing) throws -> AsyncThrowingStream<CameraFrame, Error> {
            try admission?.check()
            try Task.checkCancellation()
            guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
                throw CameraError.permissionDenied
            }
            guard photoTask == nil else { throw CameraError.photoBusy }
            guard session.isRunning, !session.isInterrupted, outputInstalled, photoOutputInstalled else {
                throw CameraError.unavailable
            }
            let position: AVCaptureDevice.Position = facing == .front ? .front : .back
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) else {
                throw CameraError.unavailable
            }
            let replacement = try AVCaptureDeviceInput(device: device)
            receiver.finish()
            frameQueue.sync {}
            session.beginConfiguration()
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
            configureFrameConnection()
            frameQueue.sync {}
            guard session.isRunning, !session.isInterrupted else { throw CameraError.startFailed }
            return receiver.begin()
        }

        private func configureFrameConnection() {
            rotationObservation = nil
            if let device = input?.device {
                let rotation = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
                rotationCoordinator = rotation
                let orientation = orientation
                let generation = orientation.bind()
                orientation.update(rotation.videoRotationAngleForHorizonLevelCapture, generation: generation)
                rotationObservation = rotation.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.new]) {
                    value, _ in
                    orientation.update(value.videoRotationAngleForHorizonLevelCapture, generation: generation)
                }
            }
            if let connection = videoOutput.connection(with: .video) {
                if connection.isVideoRotationAngleSupported(0) { connection.videoRotationAngle = 0 }
                if connection.isVideoMirroringSupported {
                    connection.automaticallyAdjustsVideoMirroring = false
                    connection.isVideoMirrored = false
                }
            }
        }

        /// One joined native capture; cancellation/timeout stop the graph and retain the delegate until terminal callback.
        public func capturePhoto(rotation: CGFloat) async throws -> Data {
            try admission?.check()
            try Task.checkCancellation()
            guard photoTask == nil else { throw CameraError.photoBusy }
            guard photoOutputInstalled, session.isRunning, !session.isInterrupted else { throw CameraError.unavailable }
            let id = UUID().uuidString
            mediaID = id
            photoTimedOut = false
            if let connection = photoOutput.connection(with: .video) {
                if connection.isVideoRotationAngleSupported(rotation) { connection.videoRotationAngle = rotation }
                if connection.isVideoMirroringSupported {
                    connection.automaticallyAdjustsVideoMirroring = false
                    connection.isVideoMirrored = input?.device.position == .front
                }
            }
            let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
            settings.flashMode = .off
            let receiver = PhotoReceiver()
            let task = Task<Data, Error> {
                try Task.checkCancellation()
                guard session.isRunning, !session.isInterrupted else { throw CameraError.unavailable }
                defer { withExtendedLifetime(receiver) {} }
                return try await withCheckedThrowingContinuation { continuation in
                    receiver.begin(continuation)
                    self.photoOutput.capturePhoto(with: settings, delegate: receiver)
                }
            }
            photoTask = task
            let deadline = Task {
                do {
                    try await Task.sleep(for: .seconds(10))
                    guard mediaID == id else { return }
                    photoTimedOut = true
                    stop()
                } catch {}
            }
            defer {
                deadline.cancel()
                photoTask = nil
                mediaID = nil
            }
            return try await withTaskCancellationHandler {
                let data = try await task.value
                try Task.checkCancellation()
                guard !photoTimedOut else { throw CameraError.photoTimedOut }
                guard !data.isEmpty, data.count <= 4 * 1024 * 1024 else { throw CameraError.photoFailed }
                return data
            } onCancel: {
                task.cancel()
                Task { await self.cancelPhoto(id) }
            }
        }
        private func cancelPhoto(_ id: String) {
            guard mediaID == id else { return }
            stop()
        }

        public func stop() {
            orientation.invalidate()
            rotationObservation = nil
            rotationCoordinator = nil
            receiver.finish()
            if session.isRunning { session.stopRunning() }
        }

        public func stopAndWait() async {
            let pending = photoTask
            pending?.cancel()
            stop()
            _ = await pending?.result
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
