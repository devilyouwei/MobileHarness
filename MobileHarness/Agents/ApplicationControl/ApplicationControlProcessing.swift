import AgentCore
import Foundation

// MARK: - State

public struct ApplicationControlContextState: AgentTaskContextState {
    public static let agentID = AgentID.applicationControl
    public static let configurationName = "ApplicationControl"

    public static func preprocess(_ input: AgentInput, state: Self) throws -> SignalDisposition {
        try ApplicationControlSignalPreprocessor().classify(input, state: state)
    }

    public var taskViews: [UUID: AgentTaskView]?

    public var pendingCallIDs: [UUID] = []
    public var environmentContracts: [String] = []
    public init() {}
    public func validateContextState() throws {
        try validateTaskState()
        guard pendingCallIDs.count <= 32, environmentContracts.count <= 32 else {
            throw CommunicationError.invalidPayload
        }
    }
    public mutating func recoverInterruptedWork() {
        recoverTaskState()
        pendingCallIDs.removeAll()
    }
}

// MARK: - Signal preprocessing

public struct ApplicationControlSignalPreprocessor: SignalPreprocessor {
    public static let inputCapacity = 32
    public static let outputCapacity = 256
    static let evidenceCapacity = 4096

    public init() {}
    public func classify(_ input: AgentInput, state: ApplicationControlContextState) throws -> SignalDisposition {
        guard !input.metadata.expired else { throw CommunicationError.expired }
        switch input.payload {
        case .communicationReceipt, .actionResult, .toolResult, .roundResult: return .feedback
        case .text: return .enqueue(priority: 0)
        case .observation(let message):
            return message.contract == "app.environment" ? .updateState : .enqueue(priority: 0)
        default: throw CommunicationError.invalidPayload
        }
    }
}

// MARK: - Context building

public struct ApplicationControlContextBuilder: ContextBuilder {
    public struct Request: Sendable {
        public let input: AgentInput
        public let state: ApplicationControlContextState
        public let batch: SignalBatch
    }
    public init() {}
    public func build(state: AgentDecisionContext<ApplicationControlContextState>, batch: SignalBatch) throws -> Request
    {
        let input = try state.selected(by: batch)
        return Request(input: input, state: state.snapshot.state, batch: batch)
    }
}

// MARK: - Permissions and result policy

/// Code-owned permissions, independent of model-callable JSON catalogs.
enum ApplicationControlFunctions {
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

/// Pure resource-result validation and error projection; no runtime or native effects.
enum ApplicationControlResourcePolicy {
    static func preferenceFailureReason(_ code: String?) -> String {
        switch code {
        case "resource.selection.recognition": "recognitionRequired"
        case "resource.selection.synthesis": "synthesisRequired"
        case "resource.source.invalid": "invalidSource"
        default: "execution"
        }
    }
    static func isResourceCommand(_ intent: ModelResourceIntent) -> Bool {
        switch intent {
        case .download, .cancel, .remove: true
        default: false
        }
    }
    static func failureMessage(_ raw: String) -> String {
        var bytes = Array(raw.utf8.prefix(2048))
        while String(bytes: bytes, encoding: .utf8) == nil { bytes.removeLast() }
        return String(decoding: bytes, as: UTF8.self)
    }
    struct PreferenceValue: Decodable {
        let endpoint: String
        let allowsCellular: Bool
        let useCustomRecognition: Bool
        let useCustomSynthesis: Bool
    }
    static func preferenceValue(_ raw: String) throws -> PreferenceValue {
        guard raw.utf8.count <= 2048,
            let keys = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
            Set(keys.keys) == ["endpoint", "allowsCellular", "useCustomRecognition", "useCustomSynthesis"]
        else { throw CommunicationError.invalidPayload }
        let value = try JSONDecoder().decode(PreferenceValue.self, from: Data(raw.utf8))
        guard !value.endpoint.isEmpty, value.endpoint.utf8.count <= 1024 else {
            throw CommunicationError.invalidPayload
        }
        return value
    }
}
