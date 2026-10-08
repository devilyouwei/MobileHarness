import FunctionContracts

/// One production catalog organized by business domain, independent of invocation protocol.
public enum CapabilityModules {
    public static func builtIn(
        presentation: any UIPresentationCapability & UIUpdateCapability, playback: any SpeechPlaybackCapability,
        pose: any PosePresentationCapability, historyPresentation: any HistoryPresentationCapability,
        camera: any CameraControlCapability, history: any HistoryQueryCapability,
        historyMutations: any HistoryMutationCapability, modelResources: any ModelResourceCapability,
        resourcePreferences: any ModelResourcePreferencesCapability,
        resourceInventory: any ModelResourceInventoryCapability,
        resourcePresentation: any ResourcePresentationCapability,
        providerDiscovery: any ProviderDiscoveryCapability,
        providerSettings: any ProviderSettingsCapability, device: any DeviceControlCapability,
        gesture: @escaping @Sendable (NexArmActions.GestureRequest, any FunctionInput) async throws -> Void,
        shakeBase: @escaping @Sendable (Int, any FunctionInput) async throws -> Void,
        aim: @escaping @Sendable (Double, Double, any FunctionInput) async throws -> Void
    ) -> [any CapabilityModule] {
        [
            UIModule(expression: presentation, pose: pose, updates: presentation, history: historyPresentation),
            ResourcePresentationModule(inventory: resourceInventory, presentation: resourcePresentation),
            SpeechModule(playback: playback), CameraModule(camera: camera),
            HistoryModule(history: history, mutations: historyMutations), SystemModule(),
            ModelResourcesModule(
                resources: modelResources, preferences: resourcePreferences, inventory: resourceInventory),
            ProviderModule(discovery: providerDiscovery, settings: providerSettings), DeviceModule(device: device),
            NavigationModule(presentation: resourcePresentation),
            NexArmModule(perform: gesture, move: shakeBase, aim: aim),
        ]
    }
}
