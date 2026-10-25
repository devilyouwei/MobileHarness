import Foundation

@MainActor public struct ActionMaintenancePorts<Artifacts: Sendable> {
    public let artifacts: @MainActor () async throws -> Artifacts
    public let quiesce: @MainActor (String) async -> Void
    public let bindSpeech: @MainActor (Bool, Bool) async throws -> Void
    public let beginSettings: @MainActor () async -> Void
    public let endSettings: @MainActor () -> Void
    public let resourcesPresented: @MainActor () -> Void
    public init(
        artifacts: @escaping @MainActor () async throws -> Artifacts,
        quiesce: @escaping @MainActor (String) async -> Void,
        bindSpeech: @escaping @MainActor (Bool, Bool) async throws -> Void,
        beginSettings: @escaping @MainActor () async -> Void, endSettings: @escaping @MainActor () -> Void,
        resourcesPresented: @escaping @MainActor () -> Void
    ) {
        self.artifacts = artifacts
        self.quiesce = quiesce
        self.bindSpeech = bindSpeech
        self.beginSettings = beginSettings
        self.endSettings = endSettings
        self.resourcesPresented = resourcesPresented
    }
}
@MainActor
public struct ActionAssemblyRequest<
    Conversations: Sendable, Activity: Sendable, Failures: Sendable, Artifacts: Sendable, Conversation: Sendable
> {
    public let sessionID: String
    public let conversations: Conversations
    public let activity: Activity
    public let failures: Failures
    public let maintenance: ActionMaintenancePorts<Artifacts>
    public let summarizeTitle: @Sendable (Conversation) async throws -> String
    public let titlePositions: @Sendable (Int) -> [Int]
    public let resourcePolicies: [ResourcePolicy]
    public init(
        sessionID: String, conversations: Conversations, activity: Activity,
        failures: Failures, maintenance: ActionMaintenancePorts<Artifacts>,
        summarizeTitle: @escaping @Sendable (Conversation) async throws -> String,
        titlePositions: @escaping @Sendable (Int) -> [Int], resourcePolicies: [ResourcePolicy] = []
    ) {
        self.sessionID = sessionID
        self.conversations = conversations
        self.activity = activity
        self.failures = failures
        self.maintenance = maintenance
        self.summarizeTitle = summarizeTitle
        self.titlePositions = titlePositions
        self.resourcePolicies = resourcePolicies
    }
}
