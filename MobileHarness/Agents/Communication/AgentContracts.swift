import AgentCore
import Foundation
import Types

/// Application Agent names; the framework only defines the identity value type.
extension AgentID {
    public static let speechPerception = AgentID(rawValue: "speechPerception")
    public static let visionPerception = AgentID(rawValue: "visionPerception")
    public static let photographer = AgentID(rawValue: "photographer")
    public static let assistant = AgentID(rawValue: "assistant")
}
public enum PerceptionMessage: Codable, Sendable, Equatable {
    case transcript(String, final: Bool)
    case speechPhase(SpeechPhase)
    case pose(PoseObservation)
    case speechSynthesis(SpeechSynthesisInput)
    case cancelSpeech(UUID)
    public var contract: String {
        switch self {
        case .transcript(_, true): "speech.final"
        case .transcript(_, false): "speech.partial"
        case .speechPhase: "speech.phase"
        case .pose: "vision.pose"
        case .speechSynthesis: "speech.synthesize"
        case .cancelSpeech: "speech.cancel"
        }
    }
    public func validate() throws {
        switch self {
        case .transcript(let text, let final):
            guard text.utf8.count <= (final ? 4096 : 16300), !final || !text.isEmpty else {
                throw CommunicationError.invalidPayload
            }
        case .speechSynthesis(let request):
            do { try request.validate() } catch { throw CommunicationError.invalidPayload }
        case .cancelSpeech, .speechPhase: break
        case .pose(let pose):
            do { try pose.validate() } catch { throw CommunicationError.invalidPayload }
        }
    }
}

/// Typed domain access and creation remain outside the framework transport.
extension AgentMessage {
    public var perception: PerceptionMessage? { content(as: PerceptionMessage.self) }
    public static func transcript(_ text: String, final: Bool) -> AgentMessage { wrap(.transcript(text, final: final)) }
    public static func speechPhase(_ phase: SpeechPhase) -> AgentMessage { wrap(.speechPhase(phase)) }
    public static func pose(_ pose: PoseObservation) -> AgentMessage { wrap(.pose(pose)) }
    public static func speechSynthesis(_ request: SpeechSynthesisInput) -> AgentMessage {
        wrap(.speechSynthesis(request))
    }
    public static func cancelSpeech(_ id: UUID) -> AgentMessage { wrap(.cancelSpeech(id)) }
    private static func wrap(_ value: PerceptionMessage) -> AgentMessage {
        AgentMessage(
            contract: value.contract, content: value,
            maximumBytes: value.contract == "vision.pose" ? 262_144 : 16_384,
            validate: { try $0.validate() })
    }
}

/// Business communication schemas and freshness policy, assembled into the generic registry.
public enum AgentContracts {
    public static var communication: CommunicationContracts {
        get throws {
            try CommunicationContracts(additional: [
                contract("speech.final"), contract("speech.partial", lifetime: 2), contract("speech.phase"),
                contract("vision.pose", lifetime: 1, maximumBytes: 262_144),
                contract("speech.synthesize", startsNewWork: true), contract("speech.cancel", startsNewWork: true),
            ])
        }
    }
    private static func contract(
        _ name: String, lifetime: TimeInterval = 10, maximumBytes: Int = 16_384, startsNewWork: Bool = false
    ) -> CommunicationContract {
        CommunicationContract(
            name: name, kind: .observation, lifetime: lifetime, maximumBytes: maximumBytes,
            startsNewWork: startsNewWork,
            validateMessage: { message in
                guard let value = message.perception, value.contract == name else {
                    throw CommunicationError.invalidPayload
                }
                try value.validate()
            })
    }
}

extension InputPayload {
    public var perception: PerceptionMessage? {
        guard case .observation(let message) = self else { return nil }
        return message.perception
    }
}
