import AgentCore
import Foundation
import StorageCore

/// Application Agent names; the framework only defines the identity value type.
extension AgentID {
    public static let speechPerception = AgentID(rawValue: "speechPerception")
    public static let visionPerception = AgentID(rawValue: "visionPerception")
    public static let photographer = AgentID(rawValue: "photographer")
    public static let writer = AgentID(rawValue: "writer")
    public static let memory = AgentID(rawValue: "memory")
    public static let applicationControl = AgentID(rawValue: "applicationControl")
    public static let assistant = AgentID(rawValue: "assistant")
}
/// Business communication schemas and freshness policy, assembled into the generic registry.
public enum AgentContracts {
    public static var communication: CommunicationContracts {
        get throws {
            try CommunicationContracts(
                additional: AgentTaskSignal.contracts + [
                    CommunicationContract(
                        name: AgentTaskRequest.contract, kind: .observation, maximumBytes: 32768, startsNewWork: true,
                        validateMessage: { message in
                            guard let value = message.content(as: AgentTaskRequest.self) else {
                                throw CommunicationError.invalidPayload
                            }
                            try value.validate()
                        }),
                    CommunicationContract(
                        name: AgentTaskResponse.contract, kind: .observation, maximumBytes: 131072, startsNewWork: true,
                        validateMessage: { message in
                            if let response = message.content(as: AgentTaskResponse.self) {
                                try response.validate()
                                return
                            }
                            guard let signal = message.content(as: AgentTaskSignal.self),
                                signal.kind == .progress || signal.kind == .result
                            else {
                                throw CommunicationError.invalidPayload
                            }
                            try signal.validate()
                        }),
                    contract(PerceptionMessage.asrPartialContract, topic: PerceptionMessage.userInputTopic),
                    contract(PerceptionMessage.asrFinalContract, topic: PerceptionMessage.userInputTopic),
                    contract("sound.source"),
                    contract("vision.pose", maximumBytes: 262_144),
                ])
        }
    }
    private static func contract(
        _ name: String, topic: String? = nil, maximumBytes: Int = 16_384, startsNewWork: Bool = false
    ) -> CommunicationContract {
        CommunicationContract(
            name: name, kind: .observation, topic: topic, maximumBytes: maximumBytes,
            startsNewWork: startsNewWork,
            validateMessage: { message in
                guard let value = message.perception, value.contract == name else {
                    throw CommunicationError.invalidPayload
                }
                try value.validate()
            })
    }
}
