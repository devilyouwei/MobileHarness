import AgentCore

/// Code-owned permissions, independent of model-callable JSON catalogs.
enum ApplicationControlFunctions {
    static let loadingExpression = InternalTool(path: "UI.Expression.setLoading", required: ["enabled", "revision"])
    static let bluetoothHome = InternalTool(
        path: "UI.BluetoothStatus.showBluetoothHome", required: ["phase", "revision"])
    static let bluetoothSettings = InternalTool(
        path: "UI.BluetoothStatus.showBluetoothSettings", required: ["phase", "revision"])
    static let runtimeFailure = InternalTool(
        path: "UI.RuntimeDiagnostics.recordFailure",
        required: ["id", "title", "source", "message", "time", "workerID"],
        optional: ["failureCode", "sessionID", "inputID", "roundID", "callID", "category", "userMessage"])
    // Application interaction.
    static let deviceControl = InternalTool(
        path: "System.Device.control", required: ["operation"], optional: ["id", "value", "action", "fence"])
    static let navigation = InternalTool(path: "UI.Navigation.open", required: ["destination"])
    // Model resources.
    static let download = InternalTool(
        path: "System.ModelResources.download", required: ["id", "endpoint", "allowsCellular"])
    static let cancellation = InternalTool(path: "System.ModelResources.cancel", required: ["id"])
    static let removal = InternalTool(path: "System.ModelResources.remove", required: ["id"])

    // Provider configuration and presentation.
    static let providerRestoration = InternalTool(
        path: "System.Provider.restoreSettings", required: ["requestID"])
    static let providerSaving = InternalTool(path: "System.Provider.saveSettings", required: ["requestID"])
    static let providerPresentation = InternalTool(
        path: "UI.ResourcePresentation.showProviderResult", required: ["requestID"], optional: ["failureCode"])
    static let providerDiscovery = InternalTool(path: "System.Provider.discoverModels", required: ["requestID"])
    // Resource inventory, presentation and preferences.
    static let inventory = InternalTool(path: "System.ModelResources.snapshotResources")
    static let presentation = InternalTool(
        path: "UI.ResourcePresentation.showResources", required: ["generation"])
    static let failurePresentation = InternalTool(
        path: "UI.ResourcePresentation.showResourceFailure", required: ["generation", "message"])
    static let operationFailurePresentation = InternalTool(
        path: "UI.ResourcePresentation.showResourceOperationFailure", required: ["message"])
    static let preferenceFailurePresentation = InternalTool(
        path: "UI.ResourcePresentation.showResourcePreferenceFailure", required: ["reason", "message"])
    static let restoration = InternalTool(path: "System.ModelResources.restoreSource")
    static let saving = InternalTool(
        path: "System.ModelResources.saveSource", required: ["endpoint", "allowsCellular", "recognition", "synthesis"])
    static let speechBinding = InternalTool(
        path: "System.ModelResources.configureSpeech", required: ["recognition", "synthesis"])

}
