import CoreVideo
import Foundation

/// Retained immutable native capture buffer plus an upright grayscale sample.
/// Producer must not mutate pixels while retained; the app only lends them to read-only model operations.
public struct CameraFrame: @unchecked Sendable {
    public let width: Int
    public let height: Int
    fileprivate let pixels: CVPixelBuffer
    public let gray64: Data
    public func withPixelBuffer<T>(_ body: (CVPixelBuffer) throws -> T) rethrows -> T { try body(pixels) }
    public let sequence: UInt64
    public let timestamp: TimeInterval
    /// Monotonic callback arrival, independent of the media presentation clock.
    public let capturedAt: ContinuousClock.Instant
    public let rotation: Int
    /// Static sensor-to-portrait reference; independent of the gravity-upright capture rotation.
    public let portraitRotation: Int?
    init(
        width: Int, height: Int, pixels: CVPixelBuffer, gray64: Data, sequence: UInt64,
        timestamp: TimeInterval, capturedAt: ContinuousClock.Instant, rotation: Int, portraitRotation: Int? = nil
    ) {
        self.width = width
        self.height = height
        self.pixels = pixels
        self.gray64 = gray64
        self.sequence = sequence
        self.timestamp = timestamp
        self.capturedAt = capturedAt
        self.rotation = rotation
        self.portraitRotation = portraitRotation
    }
}

#if os(iOS)
    import AVFoundation
    import Synchronization

    final class CameraFrameReceiver: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, Sendable {
        private struct State {
            var active = false
            var output: AsyncThrowingStream<CameraFrame, Error>.Continuation?
            var generation = UUID().uuidString
            var sequence: UInt64 = 0
            var timestamp: Double = -1
            var rotation = 1
            var portraitRotation: Int?
        }

        private let state = Mutex(State())
        private let observations = NativeInputBroadcast<CameraFrame>()
        func subscribe() throws -> AsyncThrowingStream<CameraFrame, Error> { try observations.subscribe(.latest) }

        func setPortraitRotation(_ rotation: Int?) { state.withLock { $0.portraitRotation = rotation } }
        func setRotation(_ rotation: Int) { state.withLock { $0.rotation = rotation } }
        func begin() -> AsyncThrowingStream<CameraFrame, Error> {
            if state.withLock({ $0.active }) { observations.finish() }
            let stream = AsyncThrowingStream<CameraFrame, Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
            let generation = UUID().uuidString
            stream.continuation.onTermination = { [weak self] _ in
                self?.state.withLock { value in
                    if value.generation == generation { value.output = nil }
                }
            }
            let previous = state.withLock { value in
                let previous = value.output
                value.active = true
                value.output = stream.continuation
                value.generation = generation
                value.sequence = 0
                value.timestamp = -1
                return previous
            }
            previous?.finish()
            return stream.stream
        }
        func finish() {
            let output = state.withLock { value in
                let output = value.output
                value.output = nil
                value.active = false
                value.generation = UUID().uuidString
                return output
            }
            observations.finish()
            output?.finish()
        }
        private func fail(_ error: any Error, generation: String) {
            let result = state.withLock { value -> (Bool, AsyncThrowingStream<CameraFrame, Error>.Continuation?) in
                guard value.active, value.generation == generation else { return (false, nil) }
                value.active = false
                let output = value.output
                value.output = nil
                return (true, output)
            }
            if result.0 {
                result.1?.finish(throwing: error)
                observations.finish(throwing: error)
            }
        }
        func captureOutput(
            _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection
        ) {
            let capturedAt = ContinuousClock.now
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
            let snapshot = state.withLock {
                value -> (AsyncThrowingStream<CameraFrame, Error>.Continuation?, UInt64, Int, Int?, String)? in
                guard value.active, timestamp.isFinite, timestamp >= 0,
                    timestamp > value.timestamp, value.sequence < UInt64.max
                else { return nil }
                value.timestamp = timestamp
                value.sequence += 1
                return (value.output, value.sequence, value.rotation, value.portraitRotation, value.generation)
            }
            guard let (continuation, sequence, rotation, portraitRotation, generation) = snapshot else { return }

            guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer),
                CVPixelBufferGetPixelFormatType(pixels) == kCVPixelFormatType_32BGRA,
                CVPixelBufferLockBaseAddress(pixels, .readOnly) == kCVReturnSuccess
            else {
                fail(CameraError.configurationFailed, generation: generation)
                return
            }
            defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
            let sourceWidth = CVPixelBufferGetWidth(pixels)
            let sourceHeight = CVPixelBufferGetHeight(pixels)
            guard sourceWidth > 0, sourceHeight > 0, let base = CVPixelBufferGetBaseAddress(pixels) else {
                fail(CameraError.configurationFailed, generation: generation)
                return
            }
            let width = rotation % 2 == 0 ? sourceWidth : sourceHeight
            let height = rotation % 2 == 0 ? sourceHeight : sourceWidth
            guard width <= 4096, height <= 4096, width * height <= 4_194_304 else {
                fail(CameraError.configurationFailed, generation: generation)
                return
            }
            let gray: Data
            do {
                gray = try CameraGraySampler.sample(
                    base: base, sourceWidth: sourceWidth, sourceHeight: sourceHeight,
                    stride: CVPixelBufferGetBytesPerRow(pixels), rotation: rotation)
            } catch {
                fail(error, generation: generation)
                return
            }
            // Retain immutable native storage, shared by all independent subscriptions.
            let frame = CameraFrame(
                width: width, height: height, pixels: pixels, gray64: gray,
                sequence: sequence, timestamp: timestamp, capturedAt: capturedAt, rotation: rotation,
                portraitRotation: portraitRotation)
            let accepted = state.withLock { value in
                guard value.active, value.generation == generation else { return false }
                observations.send(frame)
                return true
            }
            if accepted { continuation?.yield(frame) }
        }
    }
#endif
