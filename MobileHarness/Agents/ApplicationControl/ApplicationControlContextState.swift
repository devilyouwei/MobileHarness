import AgentCore
import Foundation
import StorageCore

public struct ApplicationControlContextState: AgentTaskContextState {
    public static let agentID = AgentID.applicationControl
    public static let configurationName = "ApplicationControl"

    public static func preprocess(_ input: AgentInput, state: Self) throws -> SignalDisposition {
        try ApplicationControlSignalPreprocessor().classify(input, state: state)
    }

    public var taskViews: [String: AgentTaskView]?

    public var pendingCallIDs: [String] = []
    public var environmentContracts: [String] = []
    public init() {}
    public func validateContextState() throws {
        try validateTaskState()
        guard pendingCallIDs.count <= 32, environmentContracts.count <= 32 else {
            throw CommunicationError.invalidPayload
        }
    }
    public mutating func recoverInterruptedWork() {
        recoverTaskState()
        pendingCallIDs.removeAll()
    }
}
