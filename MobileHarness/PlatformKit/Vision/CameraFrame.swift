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
    init(
        width: Int, height: Int, pixels: CVPixelBuffer, gray64: Data, sequence: UInt64,
        timestamp: TimeInterval, capturedAt: ContinuousClock.Instant, rotation: Int
    ) {
        self.width = width
        self.height = height
        self.pixels = pixels
        self.gray64 = gray64
        self.sequence = sequence
        self.timestamp = timestamp
        self.capturedAt = capturedAt
        self.rotation = rotation
    }
}

#if os(iOS)
    import AVFoundation
    import Synchronization

    final class CameraFrameReceiver: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, Sendable {
        private struct State {
            var output: AsyncThrowingStream<CameraFrame, Error>.Continuation?
            var generation = UUID().uuidString
            var sequence: UInt64 = 0
            var timestamp: Double = -1
            var rotation = 1
        }
        private let state = Mutex(State())

        func setRotation(_ rotation: Int) { state.withLock { $0.rotation = rotation } }
        func begin() -> AsyncThrowingStream<CameraFrame, Error> {
            let stream = AsyncThrowingStream<CameraFrame, Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
            let generation = UUID().uuidString
            stream.continuation.onTermination = { [weak self] _ in
                self?.state.withLock { value in
                    if value.generation == generation { value.output = nil }
                }
            }
            let previous = state.withLock { value in
                let previous = value.output
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
                return output
            }
            output?.finish()
        }
        func captureOutput(
            _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection
        ) {
            let capturedAt = ContinuousClock.now
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
            let snapshot = state.withLock {
                value -> (AsyncThrowingStream<CameraFrame, Error>.Continuation, UInt64, Int)? in
                guard let output = value.output, timestamp.isFinite, timestamp >= 0,
                    timestamp > value.timestamp, value.sequence < UInt64.max
                else { return nil }
                value.timestamp = timestamp
                value.sequence += 1
                return (output, value.sequence, value.rotation)
            }
            guard let (continuation, sequence, rotation) = snapshot else { return }
            guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer),
                CVPixelBufferGetPixelFormatType(pixels) == kCVPixelFormatType_32BGRA,
                CVPixelBufferLockBaseAddress(pixels, .readOnly) == kCVReturnSuccess
            else {
                continuation.finish(throwing: CameraError.configurationFailed)
                return
            }
            defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
            let sourceWidth = CVPixelBufferGetWidth(pixels)
            let sourceHeight = CVPixelBufferGetHeight(pixels)
            guard sourceWidth > 0, sourceHeight > 0, let base = CVPixelBufferGetBaseAddress(pixels) else {
                continuation.finish(throwing: CameraError.configurationFailed)
                return
            }
            let width = rotation % 2 == 0 ? sourceWidth : sourceHeight
            let height = rotation % 2 == 0 ? sourceHeight : sourceWidth
            guard width <= 4096, height <= 4096, width * height <= 4_194_304 else {
                continuation.finish(throwing: CameraError.configurationFailed)
                return
            }
            let gray: Data
            do {
                gray = try CameraGraySampler.sample(
                    base: base, sourceWidth: sourceWidth, sourceHeight: sourceHeight,
                    stride: CVPixelBufferGetBytesPerRow(pixels), rotation: rotation)
            } catch {
                continuation.finish(throwing: error)
                return
            }
            // Retain the immutable capture buffer; AVFoundation cannot recycle it until all owners release it.
            continuation.yield(
                CameraFrame(
                    width: width, height: height, pixels: pixels, gray64: gray,
                    sequence: sequence, timestamp: timestamp, capturedAt: capturedAt, rotation: rotation))
        }
    }
#endif
