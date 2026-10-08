import FunctionContracts

public protocol ModelResourceCapability: Sendable {
    func configureSpeech(recognition: Bool, synthesis: Bool) async throws
    func download(_ id: String, endpoint: String, allowsCellular: Bool) async throws
    func cancel(_ id: String) async throws
    func remove(_ id: String) async throws
}

public struct ModelResourcesModule: CapabilityModule {
    private let resources: any ModelResourceCapability
    private let preferences: any ModelResourcePreferencesCapability
    private let inventory: any ModelResourceInventoryCapability
    public init(
        resources: any ModelResourceCapability, preferences: any ModelResourcePreferencesCapability,
        inventory: any ModelResourceInventoryCapability
    ) {
        self.resources = resources
        self.preferences = preferences
        self.inventory = inventory
    }
    public var definitions: [ActionFunction] {
        [
            SystemActions.snapshotResourcesDefinition(completing: { [inventory] in
                .value(try await SystemActions.snapshotResources(invocation: $0, using: inventory))
            }),
            SystemActions.restoreSourceDefinition(completing: { [preferences] in
                .value(try await SystemActions.restoreSource(invocation: $0, using: preferences))
            }),
            SystemActions.saveSourceDefinition(completing: { [preferences] in
                .value(try await SystemActions.saveSource(invocation: $0, using: preferences))
            }),
            SystemActions.configureSpeechDefinition(completing: { [resources] in
                .value(try await SystemActions.configureSpeech(invocation: $0, using: resources))
            }),
            SystemActions.downloadDefinition(completing: { [resources] in
                .value(try await SystemActions.download(invocation: $0, using: resources))
            }),
            SystemActions.cancelDefinition(completing: { [resources] in
                .value(try await SystemActions.cancel(invocation: $0, using: resources))
            }),
            SystemActions.removeDefinition(completing: { [resources] in
                .value(try await SystemActions.remove(invocation: $0, using: resources))
            }),
        ]
    }
}
