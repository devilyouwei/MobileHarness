#if os(iOS)
    import PlatformKit
    import ActionBindings
    import AgentCore
    import Agents
    import Foundation
    import Gateway
    import ModelKit
    import StorageCore
    import StorageCache
    import StorageChat

    /// Immutable service slices; session owners cannot reach unrelated application facilities.
    @MainActor
    struct VoiceRuntimeDependencies {
        let cache: CacheContainer
        let manager: AgentManager
        let input: InputGateway
        let output: OutputGateway
        let presentation: RuntimePresentation
        let conversations: ConversationHistoryStore
        let interactionSessionID: String
        let startInteraction: @MainActor () async throws -> Void
        let cancelReply: @MainActor () async throws -> Void
        let stopInteraction: @MainActor () async -> Void
        let makeSynthesis: (any SpeechSynthesisCapability, AudioCache) throws -> SpeechSynthesisAgent
        let makePerception:
            (any SpeechRecognitionCapability, any VoiceActivityCapability, String) throws -> SpeechPerceptionAgent
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
#endif
