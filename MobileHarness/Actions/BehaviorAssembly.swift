import CallRuntime
import ExecutionRuntime
import FunctionContracts

/// Pure behavior assembly. Device creation and runtime lifetime stay with the host.
public struct BehaviorAssembly: Sendable {
    public let bindings: [ActionBinding]
    public let functions: FunctionRegistry
    public let actions: ActionRegistry
    public let tools: ToolRegistry
    public let toolPaths: Set<String>

    public init(
        presentation: any UIPresentationCapability & UIUpdateCapability,
        playback: any SpeechPlaybackCapability,
        pose: any PosePresentationCapability,
        historyPresentation: any HistoryPresentationCapability, camera: any CameraControlCapability,
        history: any HistoryQueryCapability, historyMutations: any HistoryMutationCapability,
        fullHistory: (any HistoryFullReadCapability)? = nil,
        album: (any PhotoAlbumCapability)? = nil,
        windows: (any WindowControlCapability)? = nil,
        island: (any IslandControlCapability)? = nil,
        modelResources: any ModelResourceCapability, resourcePreferences: any ModelResourcePreferencesCapability,
        resourceInventory: any ModelResourceInventoryCapability,
        resourcePresentation: any ResourcePresentationCapability,
        providerDiscovery: any ProviderDiscoveryCapability,
        providerSettings: any ProviderSettingsCapability, device: any DeviceControlCapability,
        feedback: (any UIFeedbackCapability)? = nil, effects: (any UIEffectCapability)? = nil,
        listening: (any SpeechListeningCapability)? = nil,
        listeningGesture: (any SpeechListeningGestureCapability)? = nil,
        detection: (any AudioDetectionCapability)? = nil,
        taskControl: (any TaskControlCapability)? = nil,
        loading: (any LoadingExpressionPresentationCapability)? = nil,
        runtimeFailures: (any RuntimeFailurePresentationCapability)? = nil,
        bluetoothStatus: (any BluetoothStatusPresentationCapability)? = nil,
        gesture: @escaping @Sendable (NexArmActions.GestureRequest, any FunctionInput) async throws -> Void,
        shakeBase: @escaping @Sendable (Int, any FunctionInput) async throws -> Void,
        aim: @escaping @Sendable (Double, Double, any FunctionInput) async throws -> Void
    ) throws {
        let modules = CapabilityModules.builtIn(
            presentation: presentation, playback: playback, pose: pose,
            historyPresentation: historyPresentation, camera: camera,
            history: history, historyMutations: historyMutations, fullHistory: fullHistory, album: album,
            windows: windows, island: island,
            modelResources: modelResources,
            resourcePreferences: resourcePreferences, resourceInventory: resourceInventory,
            resourcePresentation: resourcePresentation, providerDiscovery: providerDiscovery,
            providerSettings: providerSettings, device: device,
            feedback: feedback, effects: effects, listening: listening, listeningGesture: listeningGesture,
            detection: detection, taskControl: taskControl, loading: loading, runtimeFailures: runtimeFailures,
            bluetoothStatus: bluetoothStatus, gesture: gesture,
            shakeBase: shakeBase, aim: aim)
        try self.init(capabilityModules: modules)
    }

    public init(capabilityModules: [any CapabilityModule]) throws {
        let catalog = try CapabilityCatalog(modules: capabilityModules)
        let bindings = try ActionBindingCatalog(definitions: catalog.definitions.map(BehaviorProtocolBindings.bind))
        try self.init(
            actionModules: [bindings.actions], toolModules: [bindings.tools],
            functions: FunctionRegistry(definitions: catalog.definitions))
    }

    /// Explicit catalog injection for isolated tests or other hosts; never runtime discovery.
    public init(
        actionModules: [any ActionModule], toolModules: [any ToolModule], functions: FunctionRegistry? = nil
    ) throws {
        let store =
            try functions
            ?? FunctionRegistry(
                definitions: (actionModules.flatMap(\.definitions) + toolModules.flatMap(\.definitions)).map(\.function)
            )
        let actions = try ActionRegistry(modules: actionModules, functions: store)
        let tools = try ToolRegistry(modules: toolModules, functions: store)
        self.bindings =
            try actionModules.flatMap(\.definitions).map {
                ActionBinding(
                    function: try store.definition(for: $0.path), protocols: [.action],
                    executionPolicy: $0.executionPolicy, directResultPolicy: $0.directResultPolicy)
            }
            + toolModules.flatMap(\.definitions).map {
                ActionBinding(
                    function: try store.definition(for: $0.path), protocols: [.tool],
                    executionPolicy: $0.executionPolicy, directResultPolicy: $0.directResultPolicy)
            }
        self.functions = store
        self.actions = actions
        self.tools = tools
        toolPaths = Set(toolModules.flatMap { $0.definitions.map { $0.path.description } })
    }
}
