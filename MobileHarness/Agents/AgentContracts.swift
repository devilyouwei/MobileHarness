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
                        name: WriterDelegationCompletion.contract, kind: .observation, maximumBytes: 131072,
                        startsNewWork: true,
                        validateMessage: { message in
                            guard let value = message.content(as: WriterDelegationCompletion.self) else {
                                throw CommunicationError.invalidPayload
                            }
                            try value.validate()
                        }),
                    CommunicationContract(
                        name: ReplyActivity.contract, kind: .observation, maximumBytes: 16384,
                        startsNewWork: true,
                        validateMessage: { message in
                            guard let value = message.content(as: ReplyActivity.self) else {
                                throw CommunicationError.invalidPayload
                            }
                            try value.validate()
                        }),
                    contract("speech.final"), contract("speech.partial"), contract("speech.phase"),
                    contract("sound.source"),
                    contract("vision.pose", maximumBytes: 262_144),
                ])
        }
    }
    private static func contract(
        _ name: String, maximumBytes: Int = 16_384, startsNewWork: Bool = false
    ) -> CommunicationContract {
        CommunicationContract(
            name: name, kind: .observation, maximumBytes: maximumBytes,
            startsNewWork: startsNewWork,
            validateMessage: { message in
                guard let value = message.perception, value.contract == name else {
                    throw CommunicationError.invalidPayload
                }
                try value.validate()
            })
    }
}
