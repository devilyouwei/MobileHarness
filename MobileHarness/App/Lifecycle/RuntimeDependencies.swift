import AgentCore
import Agents
import AppWorkflows
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
    let interactionSessionID: UUID
    let startInteraction: @MainActor () async throws -> Void
    let cancelReply: @MainActor () async throws -> Void
    let stopInteraction: @MainActor () async -> Void
    let makeSynthesis: (any SpeechSynthesisCapability, SpeechAudioStore) throws -> SpeechSynthesisAgent
    let makePerception:
        (any SpeechRecognitionCapability, any VoiceActivityCapability, UUID) throws -> SpeechPerceptionAgent
}
@MainActor
struct VisionRuntimeDependencies {
    let photographer: PhotographerIntentRuntime
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
