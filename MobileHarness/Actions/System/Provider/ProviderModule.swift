import FunctionContracts

@ActionCatalog
public struct ProviderModule: CapabilityModule {
    private let provider: any ProviderDiscoveryCapability
    private let settings: any ProviderSettingsCapability
    public init(discovery: any ProviderDiscoveryCapability, settings: any ProviderSettingsCapability) {
        self.provider = discovery
        self.settings = settings
    }
    public var definitions: [ActionFunction] {
        [
            SystemActions.discoverModelsDefinition(completing: { [provider] in
                .value(try await SystemActions.discoverModels(invocation: $0, using: provider))
            }),
            SystemActions.readSettingsDefinition(completing: { [settings] in
                .value(try await SystemActions.readSettings(invocation: $0, using: settings))
            }),
            SystemActions.restoreSettingsDefinition(completing: { [settings] in
                .value(try await SystemActions.restoreSettings(invocation: $0, using: settings))
            }),
            SystemActions.saveSettingsDefinition(completing: { [settings] in
                .value(try await SystemActions.saveSettings(invocation: $0, using: settings))
            }),
        ]
    }
}
