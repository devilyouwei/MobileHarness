import AgentCore
import Foundation
import StorageCore

public struct CameraTransactionContextState: AgentTaskContextState {
    public static let agentID = AgentID.visionPerception
    public static let configurationName = "VisionPerception"

    public static func preprocess(_ input: AgentInput, state: Self) throws -> SignalDisposition {
        try CameraTransactionSignalPreprocessor().classify(input, state: state)
    }

    public var taskViews: [String: AgentTaskView]?

    public var photoOwners: [String: String]?
    public var cameraState: CameraStateObservation?
    public var cameraRequestID: String?
    public var trackingSessionID: String?
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

extension CameraTransactionContextState {
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
