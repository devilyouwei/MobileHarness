import Foundation

/// Upright, unmirrored RGB8 camera sample. Application maps this into Gateway's input contract.
public struct CameraFrame: Sendable {
    public let width: Int
    public let height: Int
    public let rgb: Data
    public let sequence: UInt64
    public let timestamp: TimeInterval
    public let rotation: Int
}

#if os(iOS)
    import AVFoundation
    import Synchronization

    final class CameraFrameReceiver: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, Sendable {
        private struct State {
            var output: AsyncThrowingStream<CameraFrame, Error>.Continuation?
            var generation = UUID()
            var sequence: UInt64 = 0
            var timestamp: Double = -1
            var rotation = 1
        }
        private let state = Mutex(State())

        func setRotation(_ rotation: Int) { state.withLock { $0.rotation = rotation } }
        func begin() -> AsyncThrowingStream<CameraFrame, Error> {
            let stream = AsyncThrowingStream<CameraFrame, Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
            let generation = UUID()
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
            let scale = min(1, 640.0 / Double(max(sourceWidth, sourceHeight)))
            let width = max(1, Int(Double(sourceWidth) * scale))
            let height = max(1, Int(Double(sourceHeight) * scale))
            let rotatedWidth = rotation % 2 == 0 ? width : height
            let rotatedHeight = rotation % 2 == 0 ? height : width
            let row = CVPixelBufferGetBytesPerRow(pixels)
            let source = base.assumingMemoryBound(to: UInt8.self)
            var rgb = [UInt8](repeating: 0, count: width * height * 3)
            for y in 0..<height {
                let sy = min(sourceHeight - 1, (2 * y + 1) * sourceHeight / (2 * height))
                for x in 0..<width {
                    let sx = min(sourceWidth - 1, (2 * x + 1) * sourceWidth / (2 * width))
                    let dx: Int
                    let dy: Int
                    switch rotation {
                    case 1:
                        dx = height - 1 - y
                        dy = x
                    case 2:
                        dx = width - 1 - x
                        dy = height - 1 - y
                    case 3:
                        dx = y
                        dy = width - 1 - x
                    default:
                        dx = x
                        dy = y
                    }
                    let i = sy * row + sx * 4
                    let j = (dy * rotatedWidth + dx) * 3
                    rgb[j] = source[i + 2]
                    rgb[j + 1] = source[i + 1]
                    rgb[j + 2] = source[i]
                }
            }
            // Newest-frame overflow is intentional; no Actions or Tool results use this stream.
            continuation.yield(
                CameraFrame(
                    width: rotatedWidth, height: rotatedHeight, rgb: Data(rgb),
                    sequence: sequence, timestamp: timestamp, rotation: rotation))
        }
    }
#endif
