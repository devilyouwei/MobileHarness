import Foundation
import ModelKit

/// Manager snapshot includes registration/construction, independently of Core resource residency.
public enum ModelState: String, CaseIterable, Sendable, Equatable {
    case registered, constructing, unmanaged, unloaded, loading, ready, unloading, closed

    init(resourceState: ModelResourceState) {
        switch resourceState {
        case .unmanaged: self = .unmanaged
        case .unloaded: self = .unloaded
        case .loading: self = .loading
        case .ready: self = .ready
        case .unloading: self = .unloading
        case .closed: self = .closed
        }
    }
}

/// Assembly-only identity. Never pass this type to a capability consumer.
public struct ModelID: Hashable, Sendable {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
}

public enum ProvidedCapability: String, CaseIterable, Hashable, Sendable {
    case chat, recognition, synthesis, decision, voiceActivity, enhancement, keywordSpotting, endpointConfirmation, pose
}

public enum ModelRegistrationError: Error, Equatable, Sendable {
    case missingDefault(ProvidedCapability)
    case duplicateDefault(ProvidedCapability)
    case invalidRegistration
    case duplicateModel(ModelID)
    case unknownModel(ModelID)
    case unsupportedCapability(ProvidedCapability)
    case factoryContractMismatch
}

/// One instance may implement several interfaces; factories may also compose independent implementations.
public struct ProvidedCapabilities: Sendable {
    let warmup: (@Sendable () async throws -> Void)?
    public let chat: (any ChatCapability)?
    public let recognition: (any SpeechRecognitionCapability)?
    public let synthesis: (any SpeechSynthesisCapability)?
    public let decision: (any DecisionCapability)?
    public let pose: (any PoseCapability)?
    public let keywordSpotting: (any KeywordSpottingCapability)?
    public let enhancement: (any SpeechEnhancementCapability)?
    public let endpointConfirmation: (any SpeechEndpointCapability)?
    public let voiceActivity: (any VoiceActivityCapability)?

    public init(
        warmup: (@Sendable () async throws -> Void)? = nil,
        chat: (any ChatCapability)? = nil, recognition: (any SpeechRecognitionCapability)? = nil,
        synthesis: (any SpeechSynthesisCapability)? = nil, decision: (any DecisionCapability)? = nil,
        enhancement: (any SpeechEnhancementCapability)? = nil,
        keywordSpotting: (any KeywordSpottingCapability)? = nil,
        voiceActivity: (any VoiceActivityCapability)? = nil,
        endpointConfirmation: (any SpeechEndpointCapability)? = nil, pose: (any PoseCapability)? = nil
    ) {
        self.keywordSpotting = keywordSpotting
        self.enhancement = enhancement
        self.warmup = warmup
        self.chat = chat
        self.recognition = recognition
        self.synthesis = synthesis
        self.decision = decision
        self.voiceActivity = voiceActivity
        self.endpointConfirmation = endpointConfirmation
        self.pose = pose
    }
    func availability(for kind: ProvidedCapability) async -> CapabilityAvailability {
        switch kind {
        case .keywordSpotting:
            return await keywordSpotting?.availability ?? .unavailable(reason: "Keyword spotter is not registered")
        case .enhancement:
            return await enhancement?.availability ?? .unavailable(reason: "Capability is not registered")
        case .pose: return await pose?.availability ?? .unavailable(reason: "Capability is not registered")
        case .chat: return await chat?.availability ?? .unavailable(reason: "Capability is not registered")
        case .recognition:
            return await recognition?.availability ?? .unavailable(reason: "Capability is not registered")
        case .synthesis: return await synthesis?.availability ?? .unavailable(reason: "Capability is not registered")
        case .decision: return await decision?.availability ?? .unavailable(reason: "Capability is not registered")
        case .endpointConfirmation:
            return await endpointConfirmation?.availability ?? .unavailable(reason: "Capability is not registered")
        case .voiceActivity:
            return await voiceActivity?.availability ?? .unavailable(reason: "Capability is not registered")
        }
    }
    public var supported: Set<ProvidedCapability> {
        var result: Set<ProvidedCapability> = []
        if keywordSpotting != nil { result.insert(.keywordSpotting) }
        if enhancement != nil { result.insert(.enhancement) }
        if pose != nil { result.insert(.pose) }
        if chat != nil { result.insert(.chat) }
        if recognition != nil { result.insert(.recognition) }
        if synthesis != nil { result.insert(.synthesis) }
        if decision != nil { result.insert(.decision) }
        if endpointConfirmation != nil { result.insert(.endpointConfirmation) }
        if voiceActivity != nil { result.insert(.voiceActivity) }
        return result
    }
}

public enum ModelMemoryPolicy: Sendable {
    case retain
    case releaseWhenIdle
}

public struct ModelRegistration: Sendable {
    public let id: ModelID
    public let capabilities: Set<ProvidedCapability>
    public let artifactID: String?
    public let memoryPolicy: ModelMemoryPolicy
    public let selectableModel: InferenceModelIdentity?
    public let supportsToolCalls: Bool
    public let supportsChatDecision: Bool
    let factory: @Sendable (ModelContext) async throws -> ProvidedCapabilities

    public init(
        id: ModelID, capabilities: Set<ProvidedCapability>, memoryPolicy: ModelMemoryPolicy = .retain,
        artifactID: String? = nil, selectableModel: InferenceModelIdentity? = nil,
        supportsToolCalls: Bool = false, supportsChatDecision: Bool = false,
        factory: @escaping @Sendable (ModelContext) async throws -> ProvidedCapabilities
    ) throws {
        guard !id.rawValue.isEmpty, !capabilities.isEmpty,
            selectableModel.map({ !$0.modelID.isEmpty && $0.modelID.utf8.count <= 512 }) ?? true,
            !(supportsToolCalls || supportsChatDecision) || capabilities.contains(.chat)
        else { throw ModelRegistrationError.invalidRegistration }
        self.id = id
        self.capabilities = capabilities
        self.memoryPolicy = memoryPolicy
        self.artifactID = artifactID
        self.selectableModel = selectableModel
        self.supportsToolCalls = supportsToolCalls
        self.supportsChatDecision = supportsChatDecision
        self.factory = factory
    }
}
