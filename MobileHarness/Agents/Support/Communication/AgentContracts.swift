import AgentCore
import Foundation
import StorageCore

/// Application Agent names; the framework only defines the identity value type.
extension AgentID {
    public static let speechPerception = AgentID(rawValue: "speechPerception")
    public static let visionPerception = AgentID(rawValue: "visionPerception")
    public static let photographer = AgentID(rawValue: "photographer")
    public static let memory = AgentID(rawValue: "memory")
    public static let applicationControl = AgentID(rawValue: "applicationControl")
    public static let assistant = AgentID(rawValue: "assistant")
}
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

/// Business communication schemas and freshness policy, assembled into the generic registry.
public enum AgentContracts {
    public static var communication: CommunicationContracts {
        get throws {
            try CommunicationContracts(
                additional: AgentTaskSignal.contracts + [
                    CommunicationContract(
                        name: AgentTaskInputIntent.contract, kind: .observation, maximumBytes: 16_384,
                        startsNewWork: true,
                        validateMessage: { message in
                            guard let value = message.content(as: AgentTaskInputIntent.self) else {
                                throw CommunicationError.invalidPayload
                            }
                            _ = try AgentTaskInputIntent(
                                taskID: value.taskID, interactionID: value.interactionID, artifactID: value.artifactID,
                                text: value.text)
                        }),
                    CommunicationContract(
                        name: AppEnvironmentFact.contract, kind: .observation, maximumBytes: 65_536,
                        validateMessage: { message in
                            guard let fact = message.appEnvironment, message.contract == AppEnvironmentFact.contract
                            else {
                                throw CommunicationError.invalidPayload
                            }
                            try fact.validate()
                        }),
                    CommunicationContract(
                        name: AppInteractionIntent.contract, kind: .observation, maximumBytes: 2048,
                        startsNewWork: true,
                        validateMessage: { message in
                            guard let intent = message.appInteraction, message.contract == AppInteractionIntent.contract
                            else { throw CommunicationError.invalidPayload }
                            try intent.validate()
                        }),
                    CommunicationContract(
                        name: ListeningIntent.contract, kind: .observation, maximumBytes: 128,
                        startsNewWork: true,
                        validateMessage: { message in
                            guard message.content(as: ListeningIntent.self) != nil else {
                                throw CommunicationError.invalidPayload
                            }
                        }),
                    CommunicationContract(
                        name: SpeechCaptureEnded.contract, kind: .observation, maximumBytes: 128, startsNewWork: true,
                        validateMessage: { message in
                            guard let value = message.content(as: SpeechCaptureEnded.self), value.revision > 0 else {
                                throw CommunicationError.invalidPayload
                            }
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
                    contract("speech.synthesize", startsNewWork: true), contract("speech.cancel", startsNewWork: true),
                    CommunicationContract(
                        name: ProviderSettingsIntent.contract, kind: .observation, maximumBytes: 512,
                        startsNewWork: true,
                        validateMessage: { message in
                            guard message.contract == ProviderSettingsIntent.contract, message.providerSettings != nil
                            else {
                                throw CommunicationError.invalidPayload
                            }
                        }),
                    CommunicationContract(
                        name: ProviderDiscoveryIntent.contract, kind: .observation, maximumBytes: 512,
                        startsNewWork: true,
                        validateMessage: { message in
                            guard message.contract == ProviderDiscoveryIntent.contract, message.providerDiscovery != nil
                            else {
                                throw CommunicationError.invalidPayload
                            }
                        }),
                    CommunicationContract(
                        name: ModelResourceHostFailure.contract, kind: .observation, maximumBytes: 16_384,
                        startsNewWork: true,
                        validateMessage: { message in
                            guard message.contract == ModelResourceHostFailure.contract,
                                let failure = message.resourceHostFailure
                            else { throw CommunicationError.invalidPayload }
                            try failure.validate()
                        }),
                    CommunicationContract(
                        name: ModelResourceObservation.contract, kind: .observation, maximumBytes: 16_384,
                        validateMessage: { message in
                            guard message.contract == ModelResourceObservation.contract,
                                let observation = message.resourceObservation
                            else { throw CommunicationError.invalidPayload }
                            try observation.validate()
                        }),
                    CommunicationContract(
                        name: ModelResourceIntent.contract, kind: .observation, maximumBytes: 2048, startsNewWork: true,
                        validateMessage: { message in
                            guard message.contract == ModelResourceIntent.contract, let intent = message.resourceIntent
                            else { throw CommunicationError.invalidPayload }
                            try intent.validate()
                        }),
                    CommunicationContract(
                        name: AssistantControl.contract, kind: .observation,
                        maximumBytes: 512, startsNewWork: true,
                        validateMessage: { message in
                            guard message.contract == AssistantControl.contract, message.assistantControl != nil else {
                                throw CommunicationError.invalidPayload
                            }
                        }),
                    CommunicationContract(
                        name: CameraStateObservation.contract, kind: .observation, maximumBytes: 2048,
                        validateMessage: { message in
                            guard let value = message.content(as: CameraStateObservation.self) else {
                                throw CommunicationError.invalidPayload
                            }
                            try value.validate()
                        }),
                    CommunicationContract(
                        name: PhotographerCameraIntent.contract, kind: .observation, maximumBytes: 512,
                        startsNewWork: true,
                        validateMessage: { message in
                            guard message.contract == PhotographerCameraIntent.contract,
                                message.photographerCamera != nil
                            else {
                                throw CommunicationError.invalidPayload
                            }
                            _ = try message.validatedSize()
                        }),
                    CommunicationContract(
                        name: MemoryHistoryIntent.contract, kind: .observation,
                        maximumBytes: 512, startsNewWork: true,
                        validateMessage: { message in
                            guard message.contract == MemoryHistoryIntent.contract, message.historyIntent != nil else {
                                throw CommunicationError.invalidPayload
                            }
                        }),
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

extension InputPayload {
    public var perception: PerceptionMessage? {
        guard case .observation(let message) = self else { return nil }
        return message.perception
    }
}

/// Typed human/history host intent; never embedded in framework business enums.
public enum MemoryHistoryIntent: Codable, Sendable, Equatable {
    case query(String)
    case startNew
    case summarize(String)
    case refresh
    case delete(String)
    case cancel(String)
    public static let contract = "history.intent"
    public func input(sessionID: String) throws -> AgentInput {
        let requestID: String
        let source: String
        if case .query(let id) = self {
            requestID = id
            source = "user"
        } else if case .cancel(let id) = self {
            requestID = id
            source = "runtime"
        } else {
            requestID = UUID().uuidString
            source = "user"
        }
        let message = AgentMessage(contract: Self.contract, content: self, maximumBytes: 512, validate: { _ in })
        let payload = InputPayload.observation(message)
        return AgentInput(
            id: requestID, sessionID: sessionID, payload: payload,
            metadata: InputMetadata(payload: payload, source: source, rootID: requestID))
    }
}

extension AgentMessage {
    public var historyIntent: MemoryHistoryIntent? { content(as: MemoryHistoryIntent.self) }
}

/// Host lifecycle controls are domain messages, not model-callable functions or runtime feedback.
public enum AgentSessionControl: Codable, Sendable, Equatable {
    case cancelSession
    public static let contract = "assistant.control"
    public func input(sessionID: String) throws -> AgentInput {
        let id = UUID().uuidString
        let message = AgentMessage(contract: Self.contract, content: self, maximumBytes: 512, validate: { _ in })
        let payload = InputPayload.observation(message)
        return AgentInput(
            id: id, sessionID: sessionID, payload: payload,
            metadata: InputMetadata(payload: payload, source: "runtime", origin: .external, rootID: id))
    }
}

public typealias AssistantControl = AgentSessionControl

extension AgentMessage {
    public var assistantControl: AgentSessionControl? { content(as: AgentSessionControl.self) }
}
