import AgentCore
import Foundation

// MARK: - State

public struct PhotographerContextState: AgentTaskContextState {
    public static let agentID = AgentID.photographer
    public static let configurationName = "Photographer"

    public static func preprocess(_ input: AgentInput, state: Self) throws -> SignalDisposition {
        try PhotographerSignalPreprocessor().classify(input, state: state)
    }

    public var taskViews: [UUID: AgentTaskView]?

    public var photoOwners: [UUID: UUID]?
    public var cameraState: CameraStateObservation?
    public var cameraRequestID: UUID?
    public var trackingSessionID: UUID?
    public init() {}
    public func validateContextState() throws {
        try validateTaskState()
        try cameraState?.validate()
        guard (photoOwners?.count ?? 0) <= 32 else { throw CommunicationError.capacityExceeded }
    }

    public mutating func recoverInterruptedWork() {
        recoverTaskState()
        cameraState = nil
        cameraRequestID = nil
        trackingSessionID = nil
    }
}

extension PhotographerContextState {
    public enum Phase: String, Codable, Sendable {
        case preparing, awaitingFeedback, reviewingPhoto, waitingUser, cancelling, completed, failed, cancelled,
            interrupted
    }
    public static func phase(_ context: AgentContext<Self>, input: AgentInput) -> Phase {
        if let task = input.taskScope, let record = context.tasks.task(task.id) {
            switch record.state {
            case .succeeded: return .completed
            case .failed: return .failed
            case .cancelling: return .cancelling
            case .cancelled: return .cancelled
            case .interrupted: return .interrupted
            default: break
            }
            if context.state.taskViews?[task.id]?.stage == .waitingUser { return .waitingUser }
        }
        switch context.work[input.id]?.state {
        case .awaitingFeedback: return .awaitingFeedback
        case .completed: return .completed
        case .failed: return .failed
        case .cancelled: return .cancelled
        case .interrupted: return .interrupted
        default: break
        }
        let signals = Set(
            context.records.filter { $0.taskID == (input.taskScope?.id ?? input.id) }.compactMap {
                try? JSONDecoder().decode(SignalEvidence.self, from: $0.data).signalID
            })
        if (context.state.photoOwners ?? [:]).values.contains(where: { signals.contains($0) }) {
            return .reviewingPhoto
        }
        return .preparing
    }

}

// MARK: - Signal preprocessing

public struct PhotographerSignalPreprocessor: SignalPreprocessor {
    public static let outputCapacity = 256
    static let evidenceCapacity = 4096

    public init() {}
    public func classify(_ input: AgentInput, state: PhotographerContextState) throws -> SignalDisposition {
        guard !input.metadata.expired else { throw CommunicationError.expired }
        switch input.payload {
        case .communicationReceipt, .actionResult, .toolResult, .roundResult: return .feedback
        case .text: return .enqueue(priority: 0)
        case .observation(let message):
            if message.contract == CameraStateObservation.contract { return .replaceLatest(key: "camera") }
            return message.contract == "vision.pose" ? .replaceLatest(key: "pose") : .enqueue(priority: 0)
        default: throw HarnessError.unsupportedInput
        }
    }
}

// MARK: - Context building

public struct PhotographerContextBuilder: ContextBuilder {
    public struct Request: Sendable {
        public let input: AgentInput
        public let state: PhotographerContextState
        public let batch: SignalBatch
    }
    public init() {}
    public func build(state: AgentDecisionContext<PhotographerContextState>, batch: SignalBatch) throws -> Request {
        let input = try state.selected(by: batch)
        return Request(input: input, state: state.snapshot.state, batch: batch)
    }
}
