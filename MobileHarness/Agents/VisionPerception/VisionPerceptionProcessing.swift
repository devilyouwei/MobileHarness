import AgentCore
import Foundation
import ModelKit
import PlatformKit
import Storage

// MARK: - State

public struct VisionPerceptionContextState: AgentContextState {
    public var latestFrameSequence: UInt64?
    public var perceptionSessionID: String?
    public init() {}
    public mutating func recoverInterruptedWork() {
        perceptionSessionID = nil
    }
}

// MARK: - Signal preprocessing

public struct VisionPerceptionSignalPreprocessor: SignalPreprocessor {
    public static let evidenceCapacity = 256
    public static let outputCapacity = 18

    public init() {}
    public func classify(_ input: AgentInput, state: VisionPerceptionContextState) throws -> SignalDisposition {
        guard !input.metadata.expired else { throw CommunicationError.expired }
        switch input.payload {
        case .actionResult, .toolResult, .roundResult: return .feedback
        case .image: return .replaceLatest(key: "frame")
        default: throw HarnessError.unsupportedInput
        }
    }
}

// MARK: - Context building

public struct VisionPerceptionContextBuilder: ContextBuilder {
    public struct Request: Sendable {
        public let input: AgentInput
        public let state: VisionPerceptionContextState
        public let batch: SignalBatch
        public func inferenceRequest() throws -> PoseRequest {
            guard case .image(let image) = input.payload else { throw HarnessError.unsupportedInput }
            let resolved = try VisionPerceptionContextBuilder.resolveImage(image)
            guard resolved.width == image.width, resolved.height == image.height else {
                throw ImageInputError.invalidFrame
            }
            return PoseRequest(
                image: resolved,
                context: InferenceContext(requestID: input.id, scopeID: input.sessionID))
        }
    }
    public init() {}
    public func build(state: AgentDecisionContext<VisionPerceptionContextState>, batch: SignalBatch) throws -> Request {
        let input = try state.selected(by: batch)
        return Request(input: input, state: state.snapshot.state, batch: batch)
    }
    private static func resolveImage(_ input: ImageInput) throws -> ImageFrame {
        switch input.content {
        case .rgb(let rgb): return try ImageFrame(width: input.width, height: input.height, rgb: rgb)
        case .attachment(let attachment):
            guard let sample = attachment as? SampledImageAttachment,
                let camera = sample.source as? CameraImageAttachment,
                camera.frame.width == input.width, camera.frame.height == input.height,
                camera.frame.rotation == input.rotation,
                camera.frame.sequence == input.sequence, camera.frame.timestamp == input.timestamp,
                camera.frame.capturedAt == input.capturedAt, camera.frame.gray64 == sample.gray64
            else { throw ImageInputError.invalidFrame }
            return try camera.frame.withPixelBuffer { try ImageFrame(pixelBuffer: $0, rotation: input.rotation) }
        }
    }
}
