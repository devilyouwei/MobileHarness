#if os(iOS)
    import AVFAudio
    import AVFoundation
    import CoreMedia
    import Foundation
    import Synchronization

    /// Audio-only hardware backend. Session graph and shutdown are actor serialized.
    actor SpatialAudioCapture {
        private let session = AVCaptureSession()
        private let callbackQueue = DispatchQueue(label: "dev.mobileharness.audio.spatial")
        private var receiver: SpatialAudioReceiver?
        private var observation: SpatialAudioObservation?

        /// Nil means the built-in route cannot supply FOA, before any hardware is started.
        func start() throws -> AsyncThrowingStream<MicrophoneFrame, Error>? {
            guard let device = AVCaptureDevice.default(for: .audio) else { return nil }
            let input = try AVCaptureDeviceInput(device: device)
            guard input.isMultichannelAudioModeSupported(.firstOrderAmbisonics) else { return nil }
            session.automaticallyConfiguresApplicationAudioSession = false
            session.beginConfiguration()
            let output = AVCaptureAudioDataOutput()
            guard session.canAddInput(input), session.canAddOutput(output) else {
                session.commitConfiguration()
                return nil
            }
            input.multichannelAudioMode = .firstOrderAmbisonics
            output.spatialAudioChannelLayoutTag = kAudioChannelLayoutTag_HOA_ACN_SN3D | 4
            session.addInput(input)
            session.addOutput(output)
            let pair = AsyncThrowingStream<MicrophoneFrame, Error>.makeStream(bufferingPolicy: .bufferingOldest(64))
            let receiver = SpatialAudioReceiver(continuation: pair.continuation)
            self.receiver = receiver
            output.setSampleBufferDelegate(receiver, queue: callbackQueue)
            observation = SpatialAudioObservation(session: session, continuation: pair.continuation)
            session.commitConfiguration()
            session.startRunning()
            guard session.isRunning else {
                pair.continuation.finish(throwing: AudioIOError.invalidFormat)
                stop()
                throw AudioIOError.invalidFormat
            }
            return pair.stream
        }
        func stop() {
            session.stopRunning()
            callbackQueue.sync {}  // Join callbacks before allowing a replacement capture backend.
            receiver?.continuation.finish()
            receiver = nil
            observation = nil
        }
    }

    private final class SpatialAudioObservation: @unchecked Sendable {
        private let tokens: [NSObjectProtocol]
        init(session: AVCaptureSession, continuation: AsyncThrowingStream<MicrophoneFrame, Error>.Continuation) {
            tokens = [
                NotificationCenter.default.addObserver(
                    forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil
                ) { _ in continuation.finish(throwing: AudioIOError.invalidFormat) },
                NotificationCenter.default.addObserver(
                    forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil
                ) { _ in continuation.finish(throwing: AudioIOError.invalidFormat) },
            ]
        }
        deinit { for token in tokens { NotificationCenter.default.removeObserver(token) } }
    }

    /// Immutable bridge plus mutex-protected sequence. Never touches App/MainActor state.
    private final class SpatialAudioReceiver: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, Sendable {
        let continuation: AsyncThrowingStream<MicrophoneFrame, Error>.Continuation
        private let sequence = Mutex<UInt64>(0)
        private let timeline = Mutex<(end: Double?, rate: Double?)>((nil, nil))
        init(continuation: AsyncThrowingStream<MicrophoneFrame, Error>.Continuation) {
            self.continuation = continuation
        }
        func captureOutput(
            _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection
        ) {
            do {
                guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
                    let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
                    let layout = CMAudioFormatDescriptionGetChannelLayout(description, sizeOut: nil)?.pointee,
                    layout.mChannelLayoutTag == (kAudioChannelLayoutTag_HOA_ACN_SN3D | 4),
                    asbd.mFormatID == kAudioFormatLinearPCM, asbd.mChannelsPerFrame == 4,
                    asbd.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
                    (8_000...192_000).contains(asbd.mSampleRate)
                else { throw AudioIOError.invalidFormat }
                let count = CMSampleBufferGetNumSamples(sampleBuffer)
                guard count > 0, count <= 8192 else { throw AudioIOError.invalidFormat }
                let list = AudioBufferList.allocate(maximumBuffers: 4)
                defer { list.unsafeMutablePointer.deallocate() }
                var block: CMBlockBuffer?
                let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                    sampleBuffer, bufferListSizeNeededOut: nil,
                    bufferListOut: list.unsafeMutablePointer,
                    bufferListSize: MemoryLayout<AudioBufferList>.size + 3 * MemoryLayout<AudioBuffer>.size,
                    blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault,
                    flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &block)
                guard status == noErr, list.count == 1 || list.count == 4 else { throw AudioIOError.invalidFormat }
                let bytesPerSample = Int(asbd.mBitsPerChannel / 8)
                let floating = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
                guard
                    (floating && bytesPerSample == 4)
                        || (!floating && asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0
                            && (bytesPerSample == 2 || bytesPerSample == 4))
                else { throw AudioIOError.invalidFormat }
                for buffer in list {
                    guard buffer.mData != nil,
                        buffer.mNumberChannels == (list.count == 1 ? 4 : 1),
                        Int(buffer.mDataByteSize) >= count * bytesPerSample * Int(buffer.mNumberChannels)
                    else { throw AudioIOError.invalidFormat }
                }
                guard asbd.mBytesPerFrame == UInt32(bytesPerSample * (list.count == 1 ? 4 : 1)),
                    asbd.mFramesPerPacket == 1
                else { throw AudioIOError.invalidFormat }
                let timestamp = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
                let hostTime = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
                guard timestamp.isFinite, timestamp >= 0 else { throw AudioIOError.invalidFormat }
                let contiguous = timeline.withLock { value in
                    defer { value = (timestamp + Double(count) / asbd.mSampleRate, asbd.mSampleRate) }
                    guard let end = value.end else { return true }
                    return value.rate == asbd.mSampleRate && abs(timestamp - end) <= 2 / asbd.mSampleRate
                }
                // AVFoundation may discard sufficiently late callbacks; never hide a PCM gap.
                guard contiguous else { throw AudioIOError.overflow }
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
                                    Float(pointer.loadUnaligned(fromByteOffset: position * 2, as: Int16.self)) / 32768
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
                    if case .dropped = continuation.yield(frame) { throw AudioIOError.overflow }
                }
                withExtendedLifetime(block) {}
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }
#endif
