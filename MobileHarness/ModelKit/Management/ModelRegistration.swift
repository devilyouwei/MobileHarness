import ModelKit

/// Assembly-only identity. Never pass this type to a capability consumer.
public struct ModelID: Hashable, Sendable {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
}

public enum ProvidedCapability: String, CaseIterable, Hashable, Sendable {
    case chat, recognition, synthesis, judge, voiceActivity, pose
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
    public let judge: (any JudgeCapability)?
    public let pose: (any PoseCapability)?
    public let voiceActivity: (any VoiceActivityCapability)?

    public init(
        warmup: (@Sendable () async throws -> Void)? = nil,
        chat: (any ChatCapability)? = nil, recognition: (any SpeechRecognitionCapability)? = nil,
        synthesis: (any SpeechSynthesisCapability)? = nil, judge: (any JudgeCapability)? = nil,
        voiceActivity: (any VoiceActivityCapability)? = nil, pose: (any PoseCapability)? = nil
    ) {
        self.warmup = warmup
        self.chat = chat
        self.recognition = recognition
        self.synthesis = synthesis
        self.judge = judge
        self.voiceActivity = voiceActivity
        self.pose = pose
    }
    func availability(for kind: ProvidedCapability) async -> CapabilityAvailability {
        switch kind {
        case .pose: return await pose?.availability ?? .unavailable(reason: "Capability is not registered")
        case .chat: return await chat?.availability ?? .unavailable(reason: "Capability is not registered")
        case .recognition:
            return await recognition?.availability ?? .unavailable(reason: "Capability is not registered")
        case .synthesis: return await synthesis?.availability ?? .unavailable(reason: "Capability is not registered")
        case .judge: return await judge?.availability ?? .unavailable(reason: "Capability is not registered")
        case .voiceActivity:
            return await voiceActivity?.availability ?? .unavailable(reason: "Capability is not registered")
        }
    }
    public var supported: Set<ProvidedCapability> {
        var result: Set<ProvidedCapability> = []
        if pose != nil { result.insert(.pose) }
        if chat != nil { result.insert(.chat) }
        if recognition != nil { result.insert(.recognition) }
        if synthesis != nil { result.insert(.synthesis) }
        if judge != nil { result.insert(.judge) }
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
    public let memoryPolicy: ModelMemoryPolicy
    let factory: @Sendable (ModelContext) async throws -> ProvidedCapabilities

    public init(
        id: ModelID, capabilities: Set<ProvidedCapability>, memoryPolicy: ModelMemoryPolicy = .retain,
        factory: @escaping @Sendable (ModelContext) async throws -> ProvidedCapabilities
    ) throws {
        guard !id.rawValue.isEmpty, !capabilities.isEmpty else { throw ModelRegistrationError.invalidRegistration }
        self.id = id
        self.capabilities = capabilities
        self.memoryPolicy = memoryPolicy
        self.factory = factory
    }
}
