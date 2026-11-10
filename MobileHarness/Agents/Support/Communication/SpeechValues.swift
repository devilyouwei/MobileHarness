import AgentCore
import Foundation
import StorageCore

public enum SpeechPhase: String, Codable, Sendable { case listening, speaking, processing, empty }

/// Complete reply occupancy and the most recent final-speech acknowledgement.
public struct ReplyActivity: Codable, Sendable {
    public static let contract = "interaction.replyActivity"
    public let revision: UInt64
    public let inputs: [String]
    public let tasks: [String]
    public let acknowledgedRoot: String
    public init(
        revision: UInt64, inputs: [String], tasks: [String], acknowledgedRoot: String
    ) {
        self.revision = revision
        self.inputs = inputs
        self.tasks = tasks
        self.acknowledgedRoot = acknowledgedRoot
    }
    public func validate() throws {
        guard revision > 0, inputs.count <= 128, tasks.count <= 128,
            Set(inputs).count == inputs.count, Set(tasks).count == tasks.count
        else { throw CommunicationError.invalidPayload }
    }
    public var message: AgentMessage {
        AgentMessage(contract: Self.contract, content: self, maximumBytes: 16384, validate: { try $0.validate() })
    }
}
