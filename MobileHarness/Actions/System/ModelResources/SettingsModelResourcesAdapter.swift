import Foundation
import FunctionContracts
import ModelKitDefaults
import ModelKitRuntime
import StorageCore
import UI

public enum SettingsModelResourcesAdapter {
    nonisolated static let invalidSourceMessage = "Enter an HTTPS domain without a path, query, or credentials."
    public static func validatePreferences(_ draft: ModelResourcePreferences) throws -> ModelResourcePreferences {
        do {
            let source = try ModelDownloadSource(endpoint: draft.endpoint, allowsCellular: true)
            return ModelResourcePreferences(
                endpoint: source.endpoint, allowsCellular: source.allowsCellular,
                useCustomRecognition: draft.useCustomRecognition, useCustomSynthesis: draft.useCustomSynthesis,
                useLocalDecision: draft.useLocalDecision)
        } catch { throw ModelResourcePreferenceError.invalidSource }
    }
    public static func items(_ raw: String) throws -> ModelResourceViewSnapshot {
        let inventory = try ModelResourceInventory.decode(raw)
        let items = inventory.items.map { snapshot in
            let status: String
            switch snapshot.phase {
            case .notInstalled: status = "Not installed"
            case .queued: status = "Waiting to download"
            case .downloading: status = "Downloading"
            case .verifying: status = "Verifying and installing"
            case .installed: status = "Installed"
            case .deleting: status = "Deleting"
            case .failed: status = "Failed. Retry or remove to repair."
            }
            return ModelResourceItem(
                id: snapshot.id, name: snapshot.name, status: status,
                bytes: snapshot.bytes,
                progress: snapshot.progress,
                installed: snapshot.phase == .installed,
                active: [.queued, .downloading, .verifying, .deleting].contains(snapshot.phase),
                failure: snapshot.failure.map {
                    switch $0 {
                    case "incompatible": return "The model version changed. Remove the old files and download again."
                    case "integrity": return "File verification failed. Check the source and try again."
                    case "removal": return "Deletion did not finish. The model files remain. Try again."
                    case "transferIndex":
                        return snapshot.phase == .installed
                            ? "The model is installed. The download record could not be saved."
                            : "Could not save the download record. Unlock the device and try again."
                    default:
                        if $0.hasPrefix("network:") {
                            return "Download interrupted. You can resume it."
                        }
                        return "Download did not finish. Resume or remove the files."
                    }
                },
                revision: snapshot.revision,
                installedBytes: snapshot.installedBytes,
                license: snapshot.license,
                activity: {
                    switch snapshot.phase {
                    case .queued: return .queued
                    case .downloading: return .downloading
                    case .verifying: return .installing
                    case .deleting: return .deleting
                    default: return nil
                    }
                }())
        }
        let groups = try inventory.installedGroups.map { group in
            guard let value = ModelResourceGroup(rawValue: group.rawValue) else {
                throw ResourceInventoryError.invalidSnapshot
            }
            return value
        }
        return ModelResourceViewSnapshot(items: items, installedGroups: Set(groups))
    }
}

/// Native SDK adaptation only; Agent/functions select commands and source inputs.
@MainActor public final class ModelResourceCapabilityAdapter: ModelResourceCapability, ModelResourceInventoryCapability
{
    private let artifacts: @MainActor () async throws -> any ModelArtifactsManaging
    private var speechPreference: [Bool]?
    private let bindSpeech: @MainActor (Bool, Bool) async throws -> Void
    private let quiesce: @MainActor (String) async -> Void
    public init(
        artifacts: @escaping @MainActor () async throws -> any ModelArtifactsManaging,
        quiesce: @escaping @MainActor (String) async -> Void,
        bindSpeech: @escaping @MainActor (Bool, Bool) async throws -> Void
    ) {
        self.artifacts = artifacts
        self.quiesce = quiesce
        self.bindSpeech = bindSpeech
    }
    public func snapshotResources() async throws -> [ModelResourceFact] {
        let manager = try await artifacts()
        let snapshots = try await manager.artifactSnapshots()
        guard snapshots.count <= 64 else { throw ResourceInventoryError.capacityExceeded }
        return try snapshots.map { snapshot in
            guard let phase = ModelResourceFact.Phase(rawValue: snapshot.phase.rawValue) else {
                throw ResourceInventoryError.invalidSnapshot
            }
            return ModelResourceFact(
                id: snapshot.artifact.id, name: snapshot.artifact.name, revision: snapshot.artifact.revision,
                license: snapshot.artifact.license, bytes: snapshot.artifact.downloadBytes,
                installedBytes: snapshot.installedBytes ?? snapshot.artifact.installedBytes,
                completedBytes: snapshot.completedBytes, phase: phase, failure: snapshot.failure)
        }
    }
    public func configureSpeech(recognition: Bool, synthesis: Bool) async throws {
        let preference = [recognition, synthesis]
        guard speechPreference != preference else { return }
        try await bindSpeech(recognition, synthesis)
        speechPreference = preference
    }
    public func download(_ id: String, endpoint: String, allowsCellular: Bool) async throws {
        let manager = try await artifacts()
        try await manager.downloadArtifact(
            id, source: ModelDownloadSource(endpoint: endpoint, allowsCellular: allowsCellular))
    }
    public func cancel(_ id: String) async throws {
        let manager = try await artifacts()
        try await manager.cancelArtifact(id)
    }
    public func remove(_ id: String) async throws {
        let manager = try await artifacts()
        try await manager.removeArtifact(id) { [quiesce] in await quiesce(id) }
    }
}

/// Root-scoped presentation adaptation; every production call is dispatched by OutputGateway.
@MainActor public final class ResourcePresentationAdapter: ResourcePresentationCapability {
    private let state: any ModelResourcesPresenting
    private let sessionID: String
    private let acknowledge: @MainActor () -> Void
    private let provider: ProviderPresentationAdapter
    private let navigation: any NavigationPresenting
    public init(
        state: any ModelResourcesPresenting, sessionID: String, provider: ProviderPresentationAdapter,
        navigation: any NavigationPresenting,
        acknowledge: @escaping @MainActor () -> Void
    ) {
        self.state = state
        self.sessionID = sessionID
        self.acknowledge = acknowledge
        self.provider = provider
        self.navigation = navigation
    }
    public func navigate(_ destination: String, invocation: any FunctionInput) async throws {
        let context = invocation.context
        guard context.sessionID == sessionID else { throw ResourcePresentationError.staleGeneration }
        guard destination == "home" || AppDestination(rawValue: destination) != nil else {
            throw ResourcePresentationError.invalidGeneration
        }
        try navigation.requirePresentation()
        navigation.show(AppDestination(rawValue: destination))
    }
    public func presentProviderResult(requestID: String, failureCode: String?, invocation: any FunctionInput)
        async throws
    {
        try await provider.present(requestID, failureCode: failureCode, invocation: invocation)
    }
    public func presentResources(
        _ inventory: ModelResourceInventory, generation: UInt64, invocation: any FunctionInput
    ) async throws {
        try Task.checkCancellation()
        try state.requirePresentation()
        guard invocation.context.sessionID == sessionID else { throw ResourcePresentationError.staleGeneration }
        // A newer refresh already owns the UI; completing this read must not overwrite it or report a failure.
        if generation > 0, generation < state.refreshGeneration { return }
        guard generation == state.refreshGeneration else { throw ResourcePresentationError.staleGeneration }
        let value = try SettingsModelResourcesAdapter.items(inventory.encoded())
        guard state.applySnapshot(value, generation: generation) else {
            throw ResourcePresentationError.staleGeneration
        }
        acknowledge()
    }
    public func presentResourcePreferenceFailure(
        _ reason: ResourcePreferenceFailureReason, message: String, invocation: any FunctionInput
    ) async throws {
        try Task.checkCancellation()
        try state.requirePresentation()
        guard invocation.context.sessionID == sessionID else { throw ResourcePresentationError.staleGeneration }
        switch reason {
        case .recognitionRequired, .synthesisRequired:
            state.presentInstallationNotice(
                (reason == .recognitionRequired ? ModelResourceGroup.recognition : .synthesis).installationMessage)
        case .invalidSource: state.presentOperationFailure(SettingsModelResourcesAdapter.invalidSourceMessage)
        case .execution: state.presentOperationFailure(message)
        }
    }
    public func presentResourceOperationFailure(_ message: String, invocation: any FunctionInput) async throws {
        try Task.checkCancellation()
        try state.requirePresentation()
        guard invocation.context.sessionID == sessionID else { throw ResourcePresentationError.staleGeneration }
        state.presentOperationFailure(message)
    }
    public func presentResourceFailure(_ message: String, generation: UInt64, invocation: any FunctionInput)
        async throws
    {
        try Task.checkCancellation()
        try state.requirePresentation()
        guard invocation.context.sessionID == sessionID else { throw ResourcePresentationError.staleGeneration }
        // Failure presentation follows the same replacement boundary as successful snapshots.
        if generation > 0, generation < state.refreshGeneration { return }
        guard state.applyRefreshFailure(message, generation: generation) else {
            throw ResourcePresentationError.staleGeneration
        }
    }
}
