#if os(iOS)
    import AVFAudio
    import AVFoundation
    import CoreMedia
    import Foundation
    import OSLog
    import Synchronization

    /// Audio-only hardware backend. Session graph and shutdown are actor serialized.
    actor SpatialAudioCapture {
        private let admission: PlatformAdmission?
        init(admission: PlatformAdmission? = nil) { self.admission = admission }
        private let session = AVCaptureSession()
        private let callbackQueue = DispatchQueue(label: "dev.mobileharness.audio.spatial")
        private var receiver: SpatialAudioReceiver?
        private var observation: SpatialAudioObservation?
        private(set) var supportsSpatialCapture: Bool?
        private let log = Logger(subsystem: "dev.mobileharness", category: "AudioCapture")
        private let captureTiming = OSSignposter(subsystem: "dev.mobileharness", category: .pointsOfInterest)

        /// Nil means the built-in route cannot supply FOA, before any hardware is started.
        func start() async throws -> MicrophoneCapture? {
            let configuration = captureTiming.beginInterval("Spatial.Start", id: captureTiming.makeSignpostID())
            defer { captureTiming.endInterval("Spatial.Start", configuration) }
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
                throw AudioIOError.startFailed
            }
            input.multichannelAudioMode = .firstOrderAmbisonics
            output.spatialAudioChannelLayoutTag = kAudioChannelLayoutTag_HOA_ACN_SN3D | 4
            session.addInput(input)
            session.addOutput(output)
            let source = MicrophoneCapture()
            let readiness = AudioCaptureReadiness()
            let receiver = SpatialAudioReceiver(
                source: source, readiness: readiness, admission: admission)
            self.receiver = receiver
            output.setSampleBufferDelegate(receiver, queue: callbackQueue)
            self.observation = SpatialAudioObservation(
                session: session, source: source, readiness: readiness,
                admission: admission)
            session.commitConfiguration()
            session.startRunning()
            guard session.isRunning, !session.isInterrupted else {
                log.error(
                    "Spatial capture startup: running=\(self.session.isRunning, privacy: .public), interrupted=\(self.session.isInterrupted, privacy: .public)"
                )
                let error =
                    observation?.failure
                    ?? (session.isInterrupted ? AudioIOError.interrupted : AudioIOError.startFailed)
                source.finish(throwing: error)
                stop()
                throw error
            }
            do {
                try await readiness.wait()
                if let error = observation?.failure { throw error }
            } catch {
                stop()
                throw error
            }
            return source
        }
        func stop() {
            observation?.invalidate()
            receiver?.readiness.resolve(.failure(CancellationError()))
            receiver?.source.finish()
            session.stopRunning()
            callbackQueue.sync {}  // Join callbacks before allowing a replacement capture backend.
            receiver = nil
            observation = nil
        }
    }

    /// Immutable bridge plus mutex-protected sequence. Never touches App/MainActor state.
    private final class SpatialAudioReceiver: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, Sendable {
        let source: MicrophoneCapture
        let readiness: AudioCaptureReadiness
        private let admission: PlatformAdmission?
        private let sequence = Mutex<UInt64>(0)
        private let timeline = Mutex(AudioPCMContinuity())
        private let reported = Mutex((format: false, failure: false))
        private let log = Logger(subsystem: "dev.mobileharness", category: "AudioCapture")
        init(
            source: MicrophoneCapture, readiness: AudioCaptureReadiness,
            admission: PlatformAdmission?
        ) {
            self.source = source
            self.readiness = readiness
            self.admission = admission
        }
        func captureOutput(
            _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection
        ) {
            guard source.isActive else { return }
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
                        if try source.send(frame) { readiness.resolve(.success(())) }
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
                admission?.report("audio.spatial", "callback", error)
                source.finish(throwing: error)
            }
        }
    }
#endif

#if os(iOS) || os(macOS)
    import AVFoundation
    import Foundation
    import OSLog
    import Synchronization

    /// One capture generation. Native errors remain identical in startup, PCM and diagnostics.
    final class SpatialAudioObservation: @unchecked Sendable {
        private struct State {
            var active = true
            var failure: (any Error)?
        }
        private static let log = Logger(subsystem: "dev.mobileharness", category: "AudioCapture")
        private let state = Mutex(State())
        private var tokens: [NSObjectProtocol] = []
        private let center: NotificationCenter
        private let source: MicrophoneCapture
        private let readiness: AudioCaptureReadiness
        private let admission: PlatformAdmission?
        var failure: (any Error)? { state.withLock { $0.failure } }

        init(
            session: AVCaptureSession, source: MicrophoneCapture,
            readiness: AudioCaptureReadiness, admission: PlatformAdmission?,
            center: NotificationCenter = .default
        ) {
            self.center = center
            self.source = source
            self.readiness = readiness
            self.admission = admission
            tokens = [
                center.addObserver(
                    forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil
                ) { [weak self] notification in
                    let error: any Error =
                        notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
                        ?? AudioIOError.runtimeFailed
                    self?.fail(error)
                },
                center.addObserver(
                    forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil
                ) { [weak self] notification in
                    #if os(iOS)
                        let reason = notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as? NSNumber
                        Self.log.error("Spatial capture interrupted: reason=\(reason?.intValue ?? 0, privacy: .public)")
                    #endif
                    self?.fail(AudioIOError.interrupted)
                },
            ]
        }

        private func fail(_ error: any Error) {
            let accepted = state.withLock {
                guard $0.active, source.isActive else { return false }
                $0.active = false
                $0.failure = error
                readiness.resolve(.failure(error))
                source.finish(throwing: error)
                return true
            }
            guard accepted else { return }
            let native = error as NSError
            Self.log.error(
                "Spatial capture native failure: domain=\(native.domain, privacy: .public), code=\(native.code, privacy: .public)"
            )
            admission?.report("audio.spatial", "nativeEvent", error)
        }

        func invalidate() { state.withLock { $0.active = false } }
        deinit { for token in tokens { center.removeObserver(token) } }
    }
#endif
