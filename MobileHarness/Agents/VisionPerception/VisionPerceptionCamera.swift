import AgentCore
import Foundation
import PlatformKit

extension VisionPerceptionAgent {
    /// The capture owner supplies one generation; inference never controls the camera.
    func consumeCamera(_ frames: AsyncThrowingStream<CameraFrame, any Error>, generation: String) async throws {
        for try await frame in frames {
            try Task.checkCancellation()
            do { try await receive(frame, generation: generation) } catch CommunicationError.expired { continue }
        }
        try Task.checkCancellation()
    }
    public func receive(_ frame: CameraFrame, generation: String) async throws {
        ContainerInputMetrics.record("Camera.Admit", since: frame.capturedAt)
        try handleCamera(
            frame,
            context: ProcessingContext(
                sessionID: generation, generation: generation, source: "phone.camera", sequence: frame.sequence,
                deadline: frame.capturedAt.advanced(by: .milliseconds(750))))
    }
    func handleCamera(_ frame: CameraFrame, context: ProcessingContext) throws {
        let image = try ImageInput(
            width: frame.width, height: frame.height, attachment: frame,
            sequence: frame.sequence, timestamp: frame.timestamp, rotation: frame.rotation, capturedAt: frame.capturedAt
        )
        try admitCamera(context.input(.image(image)))
    }
}
