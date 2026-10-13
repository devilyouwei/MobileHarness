import FunctionContracts

/// One production catalog organized by business domain, independent of invocation protocol.
public enum CapabilityModules {
    /// Module composition only; each module derives members from its own factory registrations.
    public static var declarations: [ActionDeclaration] {
        let modules: [[ActionDeclaration]] = [
            UIModule.declarations,
            NavigationModule.declarations,
            ResourcePresentationModule.declarations,
            SpeechModule.declarations,
            CameraModule.declarations,
            HistoryModule.declarations,
            SystemModule.declarations,
            ModelResourcesModule.declarations,
            ProviderModule.declarations,
            DeviceModule.declarations,
            NexArmModule.declarations,
            TaskControlModule.declarations,
        ]
        return modules.flatMap { $0 }
    }
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
        var modules: [any CapabilityModule] = [
            UIModule(
                expression: presentation, pose: pose, updates: presentation, history: historyPresentation,
                feedback: presentation as? any UIFeedbackCapability, effects: presentation as? any UIEffectCapability),
            ResourcePresentationModule(inventory: resourceInventory, presentation: resourcePresentation),
            SpeechModule(playback: playback, listening: playback as? any SpeechListeningCapability),
            CameraModule(camera: camera),
            HistoryModule(history: history, mutations: historyMutations), SystemModule(),
            ModelResourcesModule(
                resources: modelResources, preferences: resourcePreferences, inventory: resourceInventory),
            ProviderModule(discovery: providerDiscovery, settings: providerSettings), DeviceModule(device: device),
            NavigationModule(presentation: resourcePresentation),
            NexArmModule(perform: gesture, move: shakeBase, aim: aim),
        ]
        if let controls = presentation as? any TaskControlCapability {
            modules.append(TaskControlModule(capability: controls))
        }
        return modules
    }
}
