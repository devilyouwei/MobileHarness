import AgentCore
import Foundation

public enum PerceptionMessage: Codable, Sendable, Equatable {
    case transcript(String, final: Bool)
    case soundSource(SoundSourceObservation)
    case pose(PoseObservation)
    public static let userInputTopic = "user.input.speech"
    public static let speechProtocol = "user.input.speech.v1"

    public var contract: String {
        switch self {
        case .transcript: Self.speechProtocol
        case .soundSource: "perception.audio.source.v1"
        case .pose: "perception.vision.pose.v1"
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
            maximumBytes: value.contract == "perception.vision.pose.v1" ? 262_144 : 16_384,
            event: {
                if case .transcript(_, let final) = value { return final ? "final" : "partial" }
                return nil
            }(),
            validate: { try $0.validate() })
    }
}

extension InputPayload {
    public var perception: PerceptionMessage? {
        guard case .observation(let message) = self else { return nil }
        return message.perception
    }
}
