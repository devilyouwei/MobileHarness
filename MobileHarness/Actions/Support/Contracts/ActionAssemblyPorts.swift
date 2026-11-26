import Foundation

public struct ModelSettingsChange: Sendable {
    public enum Role: String, Sendable {
        case assistant, writer, decision, vision
        case recognition, synthesis, voiceActivity, enhancement, keywordSpotting, endpointConfirmation
    }
    public var roles: Set<Role>
    public var modelIDs: Set<String>
    public init(roles: Set<Role> = [], modelIDs: Set<String> = []) {
        self.roles = roles
        self.modelIDs = modelIDs
    }
}

@MainActor public struct ActionMaintenancePorts<Artifacts: Sendable> {
    public let artifacts: @MainActor () async throws -> Artifacts
    public let quiesce: @MainActor (String) async -> Void
    public let bindSpeech: @MainActor (Bool, Bool) async throws -> Void
    public let bindSpeechModels: (@MainActor ([String: String], String?) async throws -> Void)?
    public let beginSettings: @MainActor () async -> Void
    public let endSettings: @MainActor () -> Void
    public let resourcesPresented: @MainActor () -> Void
    public let beginModelChange: @MainActor @Sendable (ModelSettingsChange) async throws -> Void
    public let endModelChange: @MainActor @Sendable () -> Void
    public init(
        artifacts: @escaping @MainActor () async throws -> Artifacts,
        quiesce: @escaping @MainActor (String) async -> Void,
        bindSpeech: @escaping @MainActor (Bool, Bool) async throws -> Void,
        bindSpeechModels: (@MainActor ([String: String], String?) async throws -> Void)? = nil,
        beginSettings: @escaping @MainActor () async -> Void, endSettings: @escaping @MainActor () -> Void,
        resourcesPresented: @escaping @MainActor () -> Void,
        beginModelChange: @escaping @MainActor @Sendable (ModelSettingsChange) async throws -> Void = { _ in },
        endModelChange: @escaping @MainActor @Sendable () -> Void = {}
    ) {
        self.artifacts = artifacts
        self.quiesce = quiesce
        self.bindSpeech = bindSpeech
        self.bindSpeechModels = bindSpeechModels
        self.beginSettings = beginSettings
        self.endSettings = endSettings
        self.resourcesPresented = resourcesPresented
        self.beginModelChange = beginModelChange
        self.endModelChange = endModelChange
    }
}
@MainActor
public struct ActionAssemblyRequest<
    Conversations: Sendable, Failures: Sendable, Artifacts: Sendable, Conversation: Sendable
> {
    public let sessionID: String
    public let conversations: Conversations
    public let failures: Failures
    public let maintenance: ActionMaintenancePorts<Artifacts>
    public let summarizeTitle: @Sendable (Conversation) async throws -> String
    public let titlePositions: @Sendable (Int) -> [Int]
    public let resourcePolicies: [ResourcePolicy]
    public init(
        sessionID: String, conversations: Conversations,
        failures: Failures, maintenance: ActionMaintenancePorts<Artifacts>,
        summarizeTitle: @escaping @Sendable (Conversation) async throws -> String,
        titlePositions: @escaping @Sendable (Int) -> [Int], resourcePolicies: [ResourcePolicy] = []
    ) {
        self.sessionID = sessionID
        self.conversations = conversations
        self.failures = failures
        self.maintenance = maintenance
        self.summarizeTitle = summarizeTitle
        self.titlePositions = titlePositions
        self.resourcePolicies = resourcePolicies
    }
}
