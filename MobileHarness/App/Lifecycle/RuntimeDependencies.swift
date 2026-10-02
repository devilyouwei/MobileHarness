import AgentCore
import Agents
import Foundation
import Gateway
import ModelKit
import StorageAudio
import StorageChat

/// Immutable service slices; session owners cannot reach unrelated application facilities.
@MainActor
struct VoiceRuntimeDependencies {
    let manager: AgentManager
    let input: InputGateway
    let output: OutputGateway
    let presentation: RuntimePresentation
    let conversations: ConversationHistoryStore
    let makeAssistant: (any ChatCapability, @escaping @Sendable () async throws -> String) throws -> AssistantAgent
    let makeSynthesis: (any SpeechSynthesisCapability, SpeechAudioStore) throws -> SpeechSynthesisAgent
    let makePerception:
        (any SpeechRecognitionCapability, any VoiceActivityCapability, UUID) throws -> SpeechPerceptionAgent
}
@MainActor
struct VisionRuntimeDependencies {
    let manager: AgentManager
    let input: InputGateway
    let output: OutputGateway
    let actions: ChannelScheduler
    let presentation: RuntimePresentation
}
@MainActor
struct CameraRuntimeDependencies {
    let resources: ResourceCoordinator
    let actions: ChannelScheduler
}
