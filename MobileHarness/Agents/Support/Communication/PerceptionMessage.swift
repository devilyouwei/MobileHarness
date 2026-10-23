import AgentCore
import Foundation

public enum PerceptionMessage: Codable, Sendable, Equatable {
    case transcript(String, final: Bool)
    case speechPhase(SpeechPhase)
    case soundSource(SoundSourceObservation)
    case pose(PoseObservation)
    case speechSynthesis(SpeechSynthesisInput)
    case cancelSpeech(String)
    public var contract: String {
        switch self {
        case .transcript(_, true): "speech.final"
        case .transcript(_, false): "speech.partial"
        case .speechPhase: "speech.phase"
        case .soundSource: "sound.source"
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
        case .soundSource(let value):
            do { try value.validate() } catch { throw CommunicationError.invalidPayload }
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
    public static func soundSource(_ value: SoundSourceObservation) -> AgentMessage { wrap(.soundSource(value)) }
    public static func pose(_ pose: PoseObservation) -> AgentMessage { wrap(.pose(pose)) }
    public static func speechSynthesis(_ request: SpeechSynthesisInput) -> AgentMessage {
        wrap(.speechSynthesis(request))
    }
    public static func cancelSpeech(_ id: String) -> AgentMessage { wrap(.cancelSpeech(id)) }
    private static func wrap(_ value: PerceptionMessage) -> AgentMessage {
        AgentMessage(
            contract: value.contract, content: value,
            maximumBytes: value.contract == "vision.pose" ? 262_144 : 16_384,
            validate: { try $0.validate() })
    }
}

extension InputPayload {
    public var perception: PerceptionMessage? {
        guard case .observation(let message) = self else { return nil }
        return message.perception
    }
}
