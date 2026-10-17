#if os(iOS)
    import AVFAudio
    import AVFoundation
    import CoreMedia
    import Foundation
    import OSLog
    import Synchronization

    /// Audio-only hardware backend. Session graph and shutdown are actor serialized.
    actor SpatialAudioCapture {
        private let session = AVCaptureSession()
        private let callbackQueue = DispatchQueue(label: "dev.mobileharness.audio.spatial")
        private var receiver: SpatialAudioReceiver?
        private var observation: SpatialAudioObservation?
        private(set) var supportsSpatialCapture: Bool?
        private let log = Logger(subsystem: "dev.mobileharness", category: "AudioCapture")

        /// Nil means the built-in route cannot supply FOA, before any hardware is started.
        func start(observation: NativeInputSession<MicrophoneFrame>) async throws -> AsyncThrowingStream<
            MicrophoneFrame, Error
        >? {
            guard let device = AVCaptureDevice.default(for: .audio) else { return nil }
            let input = try AVCaptureDeviceInput(device: device)
            supportsSpatialCapture = input.isMultichannelAudioModeSupported(.firstOrderAmbisonics)
            guard supportsSpatialCapture == true else { return nil }
            // FOA needs capture-specific microphone configuration, unlike the mono engine backend.
            session.automaticallyConfiguresApplicationAudioSession = true
            session.beginConfiguration()
            let output = AVCaptureAudioDataOutput()
            guard session.canAddInput(input), session.canAddOutput(output) else {
                log.error("Spatial capture rejected input/output graph")
                session.commitConfiguration()
                throw AudioIOError.invalidFormat
            }
            input.multichannelAudioMode = .firstOrderAmbisonics
            output.spatialAudioChannelLayoutTag = kAudioChannelLayoutTag_HOA_ACN_SN3D | 4
            session.addInput(input)
            session.addOutput(output)
            let pair = AsyncThrowingStream<MicrophoneFrame, Error>.makeStream(bufferingPolicy: .bufferingOldest(64))
            let readiness = AudioCaptureReadiness()
            let receiver = SpatialAudioReceiver(
                continuation: pair.continuation, readiness: readiness, observation: observation)
            self.receiver = receiver
            output.setSampleBufferDelegate(receiver, queue: callbackQueue)
            self.observation = SpatialAudioObservation(
                session: session, continuation: pair.continuation, readiness: readiness, observation: observation)
            session.commitConfiguration()
            session.startRunning()
            guard session.isRunning, !session.isInterrupted else {
                log.error(
                    "Spatial capture startup: running=\(self.session.isRunning, privacy: .public), interrupted=\(self.session.isInterrupted, privacy: .public)"
                )
                pair.continuation.finish(throwing: AudioIOError.invalidFormat)
                stop()
                throw AudioIOError.invalidFormat
            }
            do {
                try await readiness.wait()
            } catch {
                stop()
                throw error
            }
            return pair.stream
        }
        func stop() {
            session.stopRunning()
            callbackQueue.sync {}  // Join callbacks before allowing a replacement capture backend.
            receiver?.readiness.resolve(.failure(CancellationError()))
            receiver?.continuation.finish()
            receiver = nil
            observation = nil
        }
    }

    private final class SpatialAudioObservation: @unchecked Sendable {
        private let tokens: [NSObjectProtocol]
        private static let log = Logger(subsystem: "dev.mobileharness", category: "AudioCapture")
        init(
            session: AVCaptureSession, continuation: AsyncThrowingStream<MicrophoneFrame, Error>.Continuation,
            readiness: AudioCaptureReadiness, observation: NativeInputSession<MicrophoneFrame>
        ) {
            tokens = [
                NotificationCenter.default.addObserver(
                    forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil
                ) { notification in
                    let error = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
                    Self.log.error(
                        "Spatial capture runtime error: domain=\(error?.domain ?? "unknown", privacy: .public), code=\(error?.code ?? 0, privacy: .public)"
                    )
                    readiness.resolve(.failure(AudioIOError.invalidFormat))
                    observation.finish(throwing: AudioIOError.invalidFormat)
                    continuation.finish(throwing: AudioIOError.invalidFormat)
                },
                NotificationCenter.default.addObserver(
                    forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil
                ) { notification in
                    let reason = notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as? NSNumber
                    Self.log.error("Spatial capture interrupted: reason=\(reason?.intValue ?? 0, privacy: .public)")
                    readiness.resolve(.failure(AudioIOError.invalidFormat))
                    observation.finish(throwing: AudioIOError.invalidFormat)
                    continuation.finish(throwing: AudioIOError.invalidFormat)
                },
            ]
        }
        deinit { for token in tokens { NotificationCenter.default.removeObserver(token) } }
    }

    /// Immutable bridge plus mutex-protected sequence. Never touches App/MainActor state.
    private final class SpatialAudioReceiver: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, Sendable {
        let continuation: AsyncThrowingStream<MicrophoneFrame, Error>.Continuation
        let readiness: AudioCaptureReadiness
        private let observation: NativeInputSession<MicrophoneFrame>
        private let sequence = Mutex<UInt64>(0)
        private let timeline = Mutex(AudioPCMContinuity())
        private let reported = Mutex((format: false, failure: false))
        private let log = Logger(subsystem: "dev.mobileharness", category: "AudioCapture")
        init(
            continuation: AsyncThrowingStream<MicrophoneFrame, Error>.Continuation,
            readiness: AudioCaptureReadiness, observation: NativeInputSession<MicrophoneFrame>
        ) {
            self.continuation = continuation
            self.readiness = readiness
            self.observation = observation
        }
        func captureOutput(
            _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection
        ) {
            var stage = "format description"
            do {
                if reported.withLock({ value in
                    defer { value.format = true }
                    return !value.format
                }) {
                    if let description = CMSampleBufferGetFormatDescription(sampleBuffer),
                        let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee
                    {
                        let tag =
                            CMAudioFormatDescriptionGetChannelLayout(description, sizeOut: nil)?.pointee
                            .mChannelLayoutTag ?? 0
                        log.notice(
                            "Spatial first PCM: rate=\(asbd.mSampleRate, privacy: .public), channels=\(asbd.mChannelsPerFrame, privacy: .public), format=\(asbd.mFormatID, privacy: .public), flags=\(asbd.mFormatFlags, privacy: .public), bits=\(asbd.mBitsPerChannel, privacy: .public), bytesPerFrame=\(asbd.mBytesPerFrame, privacy: .public), framesPerPacket=\(asbd.mFramesPerPacket, privacy: .public), layout=\(tag, privacy: .public)"
                        )
                    }
                }
                guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
                    let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
                    let layout = CMAudioFormatDescriptionGetChannelLayout(description, sizeOut: nil)?.pointee,
                    layout.mChannelLayoutTag == (kAudioChannelLayoutTag_HOA_ACN_SN3D | 4),
                    asbd.mFormatID == kAudioFormatLinearPCM, asbd.mChannelsPerFrame == 4,
                    asbd.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
                    (8_000...192_000).contains(asbd.mSampleRate)
                else { throw AudioIOError.invalidFormat }
                stage = "sample count"
                let count = CMSampleBufferGetNumSamples(sampleBuffer)
                guard count > 0, count <= 8192 else { throw AudioIOError.invalidFormat }
                stage = "audio buffer list"
                try AudioSampleBufferReader.withAudioBuffers(from: sampleBuffer) { list in
                    guard list.count == 1 || list.count == 4 else { throw AudioIOError.invalidFormat }
                    stage = "PCM representation"
                    let bytesPerSample = Int(asbd.mBitsPerChannel / 8)
                    let floating = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
                    guard
                        (floating && bytesPerSample == 4)
                            || (!floating && asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0
                                && (bytesPerSample == 2 || bytesPerSample == 4))
                    else { throw AudioIOError.invalidFormat }
                    stage = "buffer channels/size"
                    for buffer in list {
                        guard buffer.mData != nil,
                            buffer.mNumberChannels == (list.count == 1 ? 4 : 1),
                            Int(buffer.mDataByteSize) >= count * bytesPerSample * Int(buffer.mNumberChannels)
                        else { throw AudioIOError.invalidFormat }
                    }
                    stage = "frame packing"
                    guard asbd.mBytesPerFrame == UInt32(bytesPerSample * (list.count == 1 ? 4 : 1)),
                        asbd.mFramesPerPacket == 1
                    else { throw AudioIOError.invalidFormat }
                    stage = "capture timestamp"
                    let timestamp = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
                    let hostTime = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
                    guard timestamp.isFinite, timestamp >= 0 else { throw AudioIOError.invalidFormat }
                    stage = "PCM continuity"
                    try timeline.withLock {
                        try $0.accept(timestamp: timestamp, frameCount: count, sampleRate: asbd.mSampleRate)
                    }
                    stage = "PCM samples/stream admission"
                    let capturedAt = ContinuousClock.now.advanced(by: .seconds(min(0, timestamp - hostTime)))
                    // Split large native callbacks into transport packets of at most 16,000 scalar samples.
                    for offset in stride(from: 0, to: count, by: 4000) {
                        let frames = min(4000, count - offset)
                        var samples: [Float] = []
                        samples.reserveCapacity(frames * 4)
                        for frame in offset..<offset + frames {
                            for channel in 0..<4 {
                                let buffer = list[list.count == 1 ? 0 : channel]
                                guard let pointer = buffer.mData else { throw AudioIOError.invalidFormat }
                                let position = list.count == 1 ? frame * 4 + channel : frame
                                let value: Float
                                if floating {
                                    value = pointer.loadUnaligned(fromByteOffset: position * 4, as: Float.self)
                                } else if bytesPerSample == 2 {
                                    value =
                                        Float(pointer.loadUnaligned(fromByteOffset: position * 2, as: Int16.self))
                                        / 32768
                                } else {
                                    value =
                                        Float(pointer.loadUnaligned(fromByteOffset: position * 4, as: Int32.self))
                                        / 2_147_483_648
                                }
                                guard value.isFinite else { throw AudioIOError.invalidFormat }
                                samples.append(value)
                            }
                        }
                        let number = sequence.withLock { value in
                            defer { value += 1 }
                            return value
                        }
                        let delta = Double(offset) / asbd.mSampleRate
                        let frame = MicrophoneFrame(
                            samples: samples, sampleRate: Int(asbd.mSampleRate), sequence: number,
                            layout: .firstOrderAmbisonicsACNSN3D, timestamp: timestamp + delta,
                            capturedAt: capturedAt.advanced(by: .seconds(delta)))
                        observation.send(frame)
                        switch continuation.yield(frame) {
                        case .enqueued:
                            readiness.resolve(.success(()))
                        case .dropped: throw AudioIOError.overflow
                        case .terminated: return
                        @unknown default: throw AudioIOError.invalidFormat
                        }
                    }
                }
            } catch {
                if reported.withLock({ value in
                    defer { value.failure = true }
                    return !value.failure
                }) {
                    log.error(
                        "Spatial PCM rejected at \(stage, privacy: .public): \(String(describing: error), privacy: .public)"
                    )
                }
                readiness.resolve(.failure(error))
                observation.finish(throwing: error)
                continuation.finish(throwing: error)
            }
        }
    }
#endif
