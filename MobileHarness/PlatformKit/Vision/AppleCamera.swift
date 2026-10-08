#if os(iOS)
    import AVFoundation
    import Foundation

    public enum CameraFacing: Sendable, Equatable { case front, back }
    public enum CameraEvent: Sendable { case interrupted, interruptionEnded, failed }
    public enum CameraError: Error, Equatable {
        case permissionDenied, unavailable, configurationFailed, startFailed, photoBusy, photoFailed, photoTimedOut
    }

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

    /// The only cross-isolation session bridge. The capture actor exclusively mutates the
    /// session graph; MainActor only binds that session to Apple's preview layer.
    public final class CameraPreviewSource: @unchecked Sendable {
        fileprivate let session: AVCaptureSession
        fileprivate let receiver: CameraFrameReceiver
        @MainActor public private(set) var captureRotation: CGFloat = 0
        fileprivate init(session: AVCaptureSession, receiver: CameraFrameReceiver) {
            self.session = session
            self.receiver = receiver
        }
        @MainActor
        public func setCaptureRotation(_ angle: CGFloat) {
            captureRotation = angle
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
        private let photoOutput = AVCapturePhotoOutput()
        private var photoOutputInstalled = false
        private var photoTask: Task<Data, Error>?
        private var photoID: UUID?
        private var photoTimedOut = false
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
            try Task.checkCancellation()
            guard photoTask == nil else { throw CameraError.photoBusy }
            guard photoOutputInstalled, session.isRunning, !session.isInterrupted else { throw CameraError.unavailable }
            let id = UUID()
            photoID = id
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
                    guard photoID == id else { return }
                    photoTimedOut = true
                    stop()
                } catch {}
            }
            defer {
                deadline.cancel()
                photoTask = nil
                photoID = nil
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
        private func cancelPhoto(_ id: UUID) {
            guard photoID == id else { return }
            stop()
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
