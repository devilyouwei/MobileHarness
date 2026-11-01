#if os(iOS)
    import AVFoundation
    import Foundation
    import Synchronization

    /// Two native receipts, retained until terminal recording completion; no polling or synthetic completion.
    private final class MovieReceiver: NSObject, AVCaptureFileOutputRecordingDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var started = false
        private var terminal: Result<CameraMovie, any Error>?
        private var startWaiter: CheckedContinuation<Void, any Error>?
        private var finishWaiter: CheckedContinuation<CameraMovie, any Error>?
        func waitForStart() async throws {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock {
                    if started {
                        continuation.resume()
                    } else if let terminal {
                        continuation.resume(throwing: terminal.failure ?? CameraError.startFailed)
                    } else {
                        startWaiter = continuation
                    }
                }
            }
        }
        func waitForFinish() async throws -> CameraMovie {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock {
                    if let terminal { continuation.resume(with: terminal) } else { finishWaiter = continuation }
                }
            }
        }
        func fileOutput(
            _ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]
        ) {
            lock.withLock {
                guard terminal == nil else { return }
                started = true
                startWaiter?.resume()
                startWaiter = nil
            }
        }
        func fileOutput(
            _ output: AVCaptureFileOutput, didFinishRecordingTo fileURL: URL, from connections: [AVCaptureConnection],
            error: (any Error)?
        ) {
            let native = error as NSError?
            let usable = native?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool == true
            let result: Result<CameraMovie, any Error>
            if let error, !usable {
                result = .failure(error)
            } else {
                let reason: String
                if native?.code == AVError.maximumDurationReached.rawValue {
                    reason = "durationLimit"
                } else if native?.code == AVError.maximumFileSizeReached.rawValue {
                    reason = "sizeLimit"
                } else {
                    reason = native == nil ? "stopped" : "interrupted"
                }
                result = .success(CameraMovie(file: fileURL, stopReason: reason))
            }
            lock.withLock {
                guard terminal == nil else { return }
                terminal = result
                startWaiter?.resume(throwing: result.failure ?? CameraError.startFailed)
                startWaiter = nil
                finishWaiter?.resume(with: result)
                finishWaiter = nil
            }
        }
    }
    extension Result where Failure == any Error {
        fileprivate var failure: (any Error)? { if case .failure(let error) = self { error } else { nil } }
    }

    /// Callback-owned state; only terminal capture resumes the caller once.
    private final class PhotoReceiver: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Data, Error>?
        private var data: Data?
        private var failure: Error?
        func begin(_ continuation: CheckedContinuation<Data, Error>) {
            lock.withLock { self.continuation = continuation }
        }
        func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?)
        {
            lock.withLock {
                if failure == nil { failure = error }
                data = photo.fileDataRepresentation()
                if ProcessInfo.processInfo.arguments.contains("-direct-input-diagnostics") {
                    let native = error as NSError?
                    let underlying = native?.userInfo[NSUnderlyingErrorKey] as? NSError
                    print(
                        "DIRECT_CAMERA_PHOTO processing bytes=\(data?.count ?? 0) dimensions=\(photo.resolvedSettings.photoDimensions) error=\(native?.domain ?? "none")/\(native?.code ?? 0) underlying=\(underlying?.domain ?? "none")/\(underlying?.code ?? 0)"
                    )
                }
            }
        }
        func photoOutput(
            _ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
            error: Error?
        ) {
            let result: (CheckedContinuation<Data, Error>?, Data?, Error?) = lock.withLock {
                let result = (continuation, data, failure ?? error)
                continuation = nil
                data = nil
                return result
            }
            guard let continuation = result.0 else { return }
            if ProcessInfo.processInfo.arguments.contains("-direct-input-diagnostics") {
                let native = result.2 as NSError?
                print("DIRECT_CAMERA_PHOTO finished error=\(native?.domain ?? "none")/\(native?.code ?? 0)")
            }
            if let error = result.2 {
                continuation.resume(throwing: error)
            } else if let data = result.1 {
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

    private final class CameraNativeFacts: Sendable {
        let storage = Mutex(CameraHardwareSnapshot())
    }

    /// Shared native preview, bounded photos and audio/video files; no business or UI ownership.
    public actor AppleCamera: CameraCapturing {
        public nonisolated var captureRotation: CGFloat { orientation.captureRotation }
        public nonisolated func requestPermission() async -> Bool { await Self.requestPermission() }
        public nonisolated let orientation: CameraCaptureOrientation
        public nonisolated let events: AsyncStream<CameraEvent>
        private let continuation: AsyncStream<CameraEvent>.Continuation
        private nonisolated let facts = CameraNativeFacts()
        public nonisolated var hardwareSnapshot: CameraHardwareSnapshot { facts.storage.withLock { $0 } }
        private func record(_ phase: CameraHardwareSnapshot.Phase) {
            facts.storage.withLock {
                $0.phase = phase
                $0.running = session.isRunning && !session.isInterrupted
                $0.facing = input.map { $0.device.position == .front ? .front : .back }
                $0.zoom = input.map { Double($0.device.videoZoomFactor) }
                $0.recording = movieOutput.isRecording
                if photoOutputInstalled {
                    $0.photoWidth = Int(photoOutput.maxPhotoDimensions.width)
                    $0.photoHeight = Int(photoOutput.maxPhotoDimensions.height)
                } else {
                    $0.photoWidth = nil
                    $0.photoHeight = nil
                }
            }
        }
        private let session: AVCaptureSession
        private var input: AVCaptureDeviceInput?
        private let videoOutput = AVCaptureVideoDataOutput()
        private let photoOutput = AVCapturePhotoOutput()
        private var photoOutputInstalled = false
        private var photoTask: Task<Data, Error>?
        private var mediaID: String?
        private var photoTimedOut = false
        private var photoNativeFinished = false
        private var photoFlash: CameraFlash = .off
        private let movieOutput = AVCaptureMovieFileOutput()
        private var movieOutputInstalled = false
        private var audioInput: AVCaptureDeviceInput?
        private var movieID: String?
        private var movieTask: Task<CameraMovie, any Error>?
        private var preparingMovie = false
        private var movieEpoch: UInt64 = 0
        private let receiver: CameraFrameReceiver
        private let frameQueue = DispatchQueue(label: "dev.mobileharness.camera.frames", qos: .userInitiated)
        private var outputInstalled = false
        private var observers: [CameraObservation] = []
        private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
        private var rotationObservation: NSKeyValueObservation?

        private let admission: PlatformAdmission?
        private let acquireAudio: @MainActor @Sendable () throws -> Void
        private let releaseAudio: @MainActor @Sendable () -> Void
        private var audioReserved = false
        public init(
            admission: PlatformAdmission? = nil,
            acquireAudio: @escaping @MainActor @Sendable () throws -> Void = {},
            releaseAudio: @escaping @MainActor @Sendable () -> Void = {}
        ) {
            self.acquireAudio = acquireAudio
            self.releaseAudio = releaseAudio
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
            case .notDetermined:
                let granted = await AVCaptureDevice.requestAccess(for: .video)
                await MainActor.run {
                    NotificationCenter.default.post(name: NativeStateCollection.permissionsDidChange, object: nil)
                }
                return granted
            default: return false
            }
        }

        /// No suspension inside graph mutation/start/stop; all operations are actor serialized.
        public func subscribeFrames() throws -> AsyncThrowingStream<CameraFrame, Error> {
            do {
                try admission?.check()
                return try receiver.subscribe()
            } catch {
                admission?.report("vision.camera", "subscribeFrames", error)
                throw error
            }
        }
        public func start(facing: CameraFacing) throws -> AsyncThrowingStream<CameraFrame, Error> {
            do {
                try admission?.check()
                guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
                    throw CameraError.permissionDenied
                }
                guard photoTask == nil, movieTask == nil, !preparingMovie else { throw CameraError.photoBusy }
                stop()
                record(.starting)
                frameQueue.sync {}  // Drain old-lens callbacks before opening another capture stream.
                installObservers()
                let position: AVCaptureDevice.Position = facing == .front ? .front : .back
                if input?.device.position != position {
                    guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
                    else { throw CameraError.unavailable }
                    let replacement = try AVCaptureDeviceInput(device: device)
                    session.beginConfiguration()
                    let preset: AVCaptureSession.Preset = movieOutputInstalled ? .hd1920x1080 : .photo
                    guard session.canSetSessionPreset(preset) else {
                        session.commitConfiguration()
                        throw CameraError.configurationFailed
                    }
                    session.sessionPreset = preset
                    let previous = input
                    if let previous { session.removeInput(previous) }
                    guard session.canAddInput(replacement) else {
                        if let previous, session.canAddInput(previous) { session.addInput(previous) }
                        session.commitConfiguration()
                        throw CameraError.configurationFailed
                    }
                    session.addInput(replacement)
                    input = replacement
                    photoFlash = .off
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
                if !photoOutputInstalled && !movieOutputInstalled {
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
                try configurePhotoGeometry()
                let frames = receiver.begin()
                if !session.isRunning { session.startRunning() }
                guard session.isRunning, !session.isInterrupted else {
                    receiver.finish()
                    throw CameraError.startFailed
                }
                record(.running)
                return frames
            } catch {
                record(.failed)
                admission?.report("vision.camera", "start", error)
                throw error
            }
        }

        /// Keep a healthy session/output graph running; only replace its video input.
        public func switchCamera(facing: CameraFacing) throws -> AsyncThrowingStream<CameraFrame, Error> {
            do {
                try admission?.check()
                try Task.checkCancellation()
                guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
                    throw CameraError.permissionDenied
                }
                guard photoTask == nil, movieTask == nil, !preparingMovie else { throw CameraError.photoBusy }
                guard session.isRunning, !session.isInterrupted, outputInstalled,
                    photoOutputInstalled || movieOutputInstalled
                else {
                    throw CameraError.unavailable
                }
                let position: AVCaptureDevice.Position = facing == .front ? .front : .back
                guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
                else {
                    throw CameraError.unavailable
                }
                let replacement = try AVCaptureDeviceInput(device: device)
                record(.switching)
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
                photoFlash = .off
                session.commitConfiguration()
                configureFrameConnection()
                try configurePhotoGeometry()
                frameQueue.sync {}
                guard session.isRunning, !session.isInterrupted else { throw CameraError.startFailed }
                record(.running)
                return receiver.begin()
            } catch {
                record(.failed)
                admission?.report("vision.camera", "switchCamera", error)
                throw error
            }
        }

        private func configurePhotoGeometry() throws {
            // AVFoundation owns preview downscaling and its orientation/aspect constraints.
            // Custom width/height can raise an Objective-C exception, which Swift catch cannot handle.
            videoOutput.automaticallyConfiguresOutputBufferDimensions = false
            videoOutput.deliversPreviewSizedOutputBuffers = true
            videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            guard let device = input?.device else { throw CameraError.configurationFailed }
            let format = device.activeFormat
            var dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            if #available(iOS 26, *), !format.supportedDynamicAspectRatios.isEmpty {
                dimensions = device.dynamicDimensions
            }
            if ProcessInfo.processInfo.arguments.contains("-direct-input-diagnostics") {
                print(
                    "camera geometry: source=\(dimensions), preview=\(videoOutput.videoSettings), photos=\(format.supportedMaxPhotoDimensions)"
                )
            }
            guard
                let width = videoOutput.videoSettings[kCVPixelBufferWidthKey as String] as? NSNumber,
                let height = videoOutput.videoSettings[kCVPixelBufferHeightKey as String] as? NSNumber,
                let previewWidth = Int32(exactly: width.int64Value),
                let previewHeight = Int32(exactly: height.int64Value)
            else { throw CameraError.configurationFailed }
            let photo = try CameraOutputDimensions.photo(
                preview: .init(width: previewWidth, height: previewHeight),
                source: .init(width: dimensions.width, height: dimensions.height),
                supported: photoOutputInstalled
                    ? format.supportedMaxPhotoDimensions.map { .init(width: $0.width, height: $0.height) }
                    : [.init(width: dimensions.width, height: dimensions.height)])
            if photoOutputInstalled {
                photoOutput.maxPhotoDimensions = CMVideoDimensions(width: photo.width, height: photo.height)
            }
            // Keep preview and still field of view aligned; avoid video-only stabilization cropping.
            if let connection = videoOutput.connection(with: .video), connection.isVideoStabilizationSupported {
                connection.preferredVideoStabilizationMode = .off
            }
        }
        private func configureFrameConnection() {
            rotationObservation = nil
            if let device = input?.device {
                let rotation = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
                rotationCoordinator = rotation
                if #available(iOS 27, *) {
                    let portraitAngle = rotation.videoRotationAngleRelative(toDeviceOrientation: .portrait)
                    receiver.setPortraitRotation(((Int((portraitAngle / 90).rounded()) % 4) + 4) % 4)
                } else {
                    receiver.setPortraitRotation(nil)
                }
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
            do {
                try admission?.check()
                try Task.checkCancellation()
                guard photoTask == nil, movieTask == nil, !preparingMovie else { throw CameraError.photoBusy }
                guard photoOutputInstalled, session.isRunning, !session.isInterrupted else {
                    throw CameraError.unavailable
                }
                let id = UUID().uuidString
                mediaID = id
                photoTimedOut = false
                photoNativeFinished = false
                guard rotation.isFinite, let connection = photoOutput.connection(with: .video),
                    connection.isVideoRotationAngleSupported(rotation)
                else { throw CameraError.configurationFailed }
                do {
                    connection.videoRotationAngle = rotation
                    if connection.isVideoMirroringSupported {
                        connection.automaticallyAdjustsVideoMirroring = false
                        connection.isVideoMirrored = input?.device.position == .front
                    }
                }
                let settings = AVCapturePhotoSettings(format: [
                    AVVideoCodecKey: AVVideoCodecType.jpeg,
                    AVVideoCompressionPropertiesKey: [AVVideoQualityKey: 0.85],
                ])
                let flash = nativeFlash(photoFlash)
                guard photoOutput.supportedFlashModes.contains(flash) else { throw CameraError.configurationFailed }
                settings.flashMode = flash
                settings.maxPhotoDimensions = photoOutput.maxPhotoDimensions
                let receiver = PhotoReceiver()
                let task = Task<Data, Error> {
                    try Task.checkCancellation()
                    guard session.isRunning, !session.isInterrupted else { throw CameraError.unavailable }
                    defer { withExtendedLifetime(receiver) {} }
                    let data: Data = try await withCheckedThrowingContinuation { continuation in
                        receiver.begin(continuation)
                        self.photoOutput.capturePhoto(with: settings, delegate: receiver)
                    }
                    photoNativeFinished = true
                    try Task.checkCancellation()
                    guard !photoTimedOut else { throw CameraError.photoTimedOut }
                    return try await NativeImageCompression.cameraPhotoJPEG(from: data)
                }
                photoTask = task
                let deadline = Task {
                    do {
                        try await Task.sleep(for: .seconds(10))
                        guard mediaID == id, !photoNativeFinished else { return }
                        photoTimedOut = true
                        stop()
                    } catch {}
                }
                defer {
                    deadline.cancel()
                    photoTask = nil
                    mediaID = nil
                    photoNativeFinished = false
                }
                return try await withTaskCancellationHandler {
                    let data = try await task.value
                    try Task.checkCancellation()
                    guard !photoTimedOut else { throw CameraError.photoTimedOut }
                    if ProcessInfo.processInfo.arguments.contains("-direct-input-diagnostics") {
                        print("DIRECT_CAMERA_PHOTO prepared bytes=\(data.count) maximumBytes=\(4 * 1024 * 1024)")
                    }
                    guard !data.isEmpty, data.count <= 4 * 1024 * 1024 else { throw CameraError.photoFailed }
                    return data
                } onCancel: {
                    task.cancel()
                    Task { await self.cancelPhoto(id) }
                }
            } catch {
                admission?.report("vision.camera", "capturePhoto", error)
                throw error
            }
        }
        private func nativeFlash(_ value: CameraFlash) -> AVCaptureDevice.FlashMode {
            switch value {
            case .off: .off
            case .on: .on
            case .auto: .auto
            }
        }
        public func setVideoMode(_ enabled: Bool) throws {
            try admission?.check()
            try Task.checkCancellation()
            guard movieTask == nil, !preparingMovie, photoTask == nil else { throw CameraError.photoBusy }
            guard session.isRunning else { throw CameraError.unavailable }
            guard enabled != movieOutputInstalled else { return }
            let previousPreset = session.sessionPreset
            let previousFlash = photoFlash
            session.beginConfiguration()
            do {
                try installCaptureOutput(video: enabled)
                configureFrameConnection()
                try configurePhotoGeometry()
                guard session.hardwareCost <= 1 else { throw CameraError.configurationFailed }
                photoFlash = .off
                session.commitConfiguration()
                record(.running)
            } catch {
                let original = error
                do {
                    try installCaptureOutput(video: !enabled, preset: previousPreset)
                    configureFrameConnection()
                    try configurePhotoGeometry()
                    photoFlash = previousFlash
                    session.commitConfiguration()
                } catch {
                    session.commitConfiguration()
                    stop()
                    record(.failed)
                    admission?.report("vision.camera", "restoreCaptureMode", error)
                    throw error
                }
                throw original
            }
        }
        private func installCaptureOutput(video: Bool, preset: AVCaptureSession.Preset? = nil) throws {
            if photoOutputInstalled {
                session.removeOutput(photoOutput)
                photoOutputInstalled = false
            }
            if movieOutputInstalled {
                session.removeOutput(movieOutput)
                movieOutputInstalled = false
            }
            let target = preset ?? (video ? .hd1920x1080 : .photo)
            guard session.canSetSessionPreset(target) else { throw CameraError.configurationFailed }
            session.sessionPreset = target
            let output: AVCaptureOutput = video ? movieOutput : photoOutput
            guard session.canAddOutput(output) else { throw CameraError.configurationFailed }
            session.addOutput(output)
            movieOutputInstalled = video
            photoOutputInstalled = !video
        }
        public func beginRecording(durationSeconds: Int, rotation: CGFloat) async throws -> String {
            try admission?.check()
            try Task.checkCancellation()
            guard (1...600).contains(durationSeconds), movieOutputInstalled, session.isRunning, !session.isInterrupted
            else {
                throw CameraError.unavailable
            }
            guard movieTask == nil, !preparingMovie, photoTask == nil else { throw CameraError.photoBusy }
            preparingMovie = true
            let epoch = movieEpoch
            defer { preparingMovie = false }
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            await MainActor.run {
                NotificationCenter.default.post(name: NativeStateCollection.permissionsDidChange, object: nil)
            }
            try Task.checkCancellation()
            try admission?.check()
            guard granted else { throw CameraError.permissionDenied }
            guard epoch == movieEpoch, session.isRunning else { throw CancellationError() }
            try await acquireAudio()
            audioReserved = true
            do {
                try Task.checkCancellation()
                try admission?.check()
                guard epoch == movieEpoch, session.isRunning else { throw CancellationError() }
                guard let microphone = AVCaptureDevice.default(for: .audio) else { throw CameraError.unavailable }
                let microphoneInput = try AVCaptureDeviceInput(device: microphone)
                try configureNativeAudioSession()
                session.beginConfiguration()
                guard session.canAddInput(microphoneInput) else {
                    session.commitConfiguration()
                    throw CameraError.configurationFailed
                }
                session.addInput(microphoneInput)
                audioInput = microphoneInput
                session.commitConfiguration()
                guard let connection = movieOutput.connection(with: .video), movieOutput.connection(with: .audio) != nil
                else {
                    removeMovieAudio()
                    throw CameraError.configurationFailed
                }
                guard rotation.isFinite, connection.isVideoRotationAngleSupported(rotation) else {
                    throw CameraError.configurationFailed
                }
                connection.videoRotationAngle = rotation
                if connection.isVideoMirroringSupported {
                    connection.automaticallyAdjustsVideoMirroring = false
                    connection.isVideoMirrored = input?.device.position == .front
                }
                if connection.isVideoStabilizationSupported { connection.preferredVideoStabilizationMode = .off }
                movieOutput.maxRecordedDuration = CMTime(seconds: Double(durationSeconds), preferredTimescale: 600)
                movieOutput.maxRecordedFileSize = 512 * 1024 * 1024
                movieOutput.minFreeDiskSpaceLimit = 64 * 1024 * 1024
                let id = UUID().uuidString
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("capture-" + id + ".mov")
                let receiver = MovieReceiver()
                movieID = id
                let task = Task<CameraMovie, any Error> {
                    defer { withExtendedLifetime(receiver) {} }
                    do {
                        let movie = try await receiver.waitForFinish()
                        removeMovieAudio()
                        await releaseMovieAudio()
                        record(session.isInterrupted ? .interrupted : session.isRunning ? .running : .stopped)
                        return movie
                    } catch {
                        removeMovieAudio()
                        await releaseMovieAudio()
                        record(session.isInterrupted ? .interrupted : session.isRunning ? .running : .stopped)
                        do {
                            if FileManager.default.fileExists(atPath: url.path) {
                                try FileManager.default.removeItem(at: url)
                            }
                        } catch { admission?.report("vision.camera", "removeFailedMovie", error) }
                        throw error
                    }
                }
                movieTask = task
                movieOutput.startRecording(to: url, recordingDelegate: receiver)
                do {
                    try await withTaskCancellationHandler {
                        try await receiver.waitForStart()
                        try Task.checkCancellation()
                    } onCancel: {
                        Task { await self.requestMovieStop() }
                    }
                    record(.running)
                    return id
                } catch {
                    requestMovieStop()
                    let result = await task.result
                    if case .success(let movie) = result {
                        do { try FileManager.default.removeItem(at: movie.file) } catch {
                            admission?.report("vision.camera", "removeCancelledMovie", error)
                        }
                    }
                    movieTask = nil
                    movieID = nil
                    throw error
                }
            } catch {
                removeMovieAudio()
                await releaseMovieAudio()
                throw error
            }
        }
        private func releaseMovieAudio() async {
            guard audioReserved else { return }
            audioReserved = false
            await releaseAudio()
        }
        private func requestMovieStop() { if movieOutput.isRecording { movieOutput.stopRecording() } }
        private func removeMovieAudio() {
            if let audioInput {
                session.beginConfiguration()
                session.removeInput(audioInput)
                self.audioInput = nil
                session.commitConfiguration()
            }
        }
        public func waitForRecording(_ id: String) async throws -> CameraMovie {
            guard movieID == id, let task = movieTask else { throw CameraError.unavailable }
            defer {
                if movieID == id {
                    movieTask = nil
                    movieID = nil
                }
            }
            return try await task.value
        }
        public func stopRecording(_ id: String) async throws -> CameraMovie {
            guard movieID == id, let task = movieTask else { throw CameraError.unavailable }
            requestMovieStop()
            return try await task.value
        }
        public func photoConfiguration() throws -> CameraPhotoConfiguration {
            try admission?.check()
            guard let device = input?.device, session.isRunning else { throw CameraError.unavailable }
            return CameraPhotoConfiguration(
                flash: photoFlash, zoom: Double(device.videoZoomFactor),
                maximumZoom: min(6, Double(device.maxAvailableVideoZoomFactor)),
                supportedFlash: movieOutputInstalled
                    ? [.off]
                    : [CameraFlash.off, .on, .auto].filter { photoOutput.supportedFlashModes.contains(nativeFlash($0)) }
            )
        }
        public func configurePhoto(flash: CameraFlash, zoom: Double) throws -> CameraPhotoConfiguration {
            try admission?.check()
            try Task.checkCancellation()
            guard photoTask == nil, movieTask == nil, !preparingMovie else { throw CameraError.photoBusy }
            let current = try photoConfiguration()
            guard zoom.isFinite, zoom >= 1, zoom <= current.maximumZoom, current.supportedFlash.contains(flash),
                let device = input?.device
            else { throw CameraError.configurationFailed }
            try device.lockForConfiguration()
            device.videoZoomFactor = CGFloat(zoom)
            device.unlockForConfiguration()
            photoFlash = flash
            record(.running)
            return try photoConfiguration()
        }
        private func cancelPhoto(_ id: String) {
            guard mediaID == id, !photoNativeFinished else { return }
            stop()
        }

        public func stop() {
            movieEpoch &+= 1
            requestMovieStop()
            record(.stopping)
            orientation.invalidate()
            rotationObservation = nil
            rotationCoordinator = nil
            receiver.finish()
            if session.isRunning { session.stopRunning() }
            record(.stopped)
        }

        public func stopAndWait() async {
            let pending = photoTask
            let recording = movieTask
            pending?.cancel()
            stop()
            _ = await pending?.result
            _ = await recording?.result
        }

        public func isRunning() -> Bool { session.isRunning && !session.isInterrupted }

        private func installObservers() {
            guard observers.isEmpty else { return }
            let continuation = continuation
            let admission = admission
            let facts = facts
            for (name, event) in [
                (AVCaptureSession.wasInterruptedNotification, CameraEvent.interrupted),
                (AVCaptureSession.interruptionEndedNotification, CameraEvent.interruptionEnded),
                (AVCaptureSession.runtimeErrorNotification, CameraEvent.failed),
            ] {
                observers.append(
                    CameraObservation(
                        NotificationCenter.default.addObserver(forName: name, object: session, queue: nil) { value in
                            if event == .failed {
                                let error: any Error
                                if let native = value.userInfo?[AVCaptureSessionErrorKey] as? NSError {
                                    error = native
                                } else {
                                    error = CameraError.runtimeFailed
                                }
                                admission?.report("vision.camera", "nativeEvent", error)
                            } else if event == .interrupted, admission?.isOpen ?? true {
                                admission?.report("vision.camera", "nativeEvent", CameraError.interrupted)
                            }
                            facts.storage.withLock {
                                let native = value.object as? AVCaptureSession
                                $0.running = (native?.isRunning ?? false) && !(native?.isInterrupted ?? true)
                                switch event {
                                case .interrupted: $0.phase = .interrupted
                                case .failed: $0.phase = .failed
                                case .interruptionEnded: $0.phase = $0.running ? .running : .stopped
                                }
                            }
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
