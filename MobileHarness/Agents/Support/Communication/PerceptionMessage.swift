import AgentCore
import Foundation

public enum PerceptionMessage: Codable, Sendable, Equatable {
    case transcript(String, final: Bool)
    case soundSource(SoundSourceObservation)
    case pose(PoseObservation)
    public static let userInputTopic = "user.input"
    public static let asrPartialContract = "user.input.asr.partial"
    public static let asrFinalContract = "user.input.asr.final"

    public var contract: String {
        switch self {
        case .transcript(_, true): Self.asrFinalContract
        case .transcript(_, false): Self.asrPartialContract
        case .soundSource: "sound.source"
        case .pose: "vision.pose"
        }
    }
    public func validate() throws {
        switch self {
        case .transcript(let text, let final):
            guard text.utf8.count <= (final ? 4096 : 16300), !final || !text.isEmpty else {
                throw CommunicationError.invalidPayload
            }
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
    public static func soundSource(_ value: SoundSourceObservation) -> AgentMessage { wrap(.soundSource(value)) }
    public static func pose(_ pose: PoseObservation) -> AgentMessage { wrap(.pose(pose)) }
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
