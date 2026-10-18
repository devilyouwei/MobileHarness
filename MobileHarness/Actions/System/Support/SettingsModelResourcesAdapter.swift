import Actions
import Foundation
import FunctionContracts
import ModelKitRuntime
import StorageCore
import UI

public enum SettingsModelResourcesAdapter {
    nonisolated static let invalidSourceMessage = "请填写 HTTPS 域名，不包含路径、查询参数或账号密码"
    public static func validatePreferences(_ draft: ModelResourcePreferences) throws -> ModelResourcePreferences {
        do {
            let source = try ModelDownloadSource(endpoint: draft.endpoint, allowsCellular: true)
            return ModelResourcePreferences(
                endpoint: source.endpoint, allowsCellular: source.allowsCellular,
                useCustomRecognition: draft.useCustomRecognition, useCustomSynthesis: draft.useCustomSynthesis)
        } catch { throw ModelResourcePreferenceError.invalidSource }
    }
    public static func preferenceFailure(_ message: String) -> any Error {
        if message.contains("resource.selection.recognition") {
            return ModelResourceSelectionError(group: .recognition)
        }
        if message.contains("resource.selection.synthesis") { return ModelResourceSelectionError(group: .synthesis) }
        if message.contains("resource.source.invalid") { return SourceError() }
        return ResourcePreferencePresentationFailure(message: message)
    }
    private struct SourceError: LocalizedError {
        var errorDescription: String? { SettingsModelResourcesAdapter.invalidSourceMessage }
    }
    public static func items(_ raw: String) throws -> ModelResourceViewSnapshot {
        let inventory = try ModelResourceInventory.decode(raw)
        let items = inventory.items.map { snapshot in
            let status: String
            switch snapshot.phase {
            case .notInstalled: status = "未下载"
            case .queued: status = "等待下载"
            case .downloading: status = "正在下载"
            case .verifying: status = "校验并安装"
            case .installed: status = "已安装"
            case .deleting: status = "正在删除"
            case .failed: status = "失败，可重试或删除修复"
            }
            return ModelResourceItem(
                id: snapshot.id, name: snapshot.name, status: status,
                bytes: snapshot.bytes,
                progress: snapshot.progress,
                installed: snapshot.phase == .installed,
                active: [.queued, .downloading, .verifying, .deleting].contains(snapshot.phase),
                failure: snapshot.failure.map {
                    switch $0 {
                    case "incompatible": return "模型版本已变更，请删除旧资源后重新下载"
                    case "integrity": return "文件校验失败，请检查下载来源后重试"
                    case "removal": return "删除未完成，模型文件仍保留，请重试删除"
                    case "transferIndex":
                        return snapshot.phase == .installed
                            ? "模型已安装，下载任务记录未能保存；无需重新下载"
                            : "下载任务记录未能保存，请确认设备已解锁并重试"
                    default:
                        if $0.hasPrefix("network:") {
                            return "网络传输中断，已保留完成的文件；可继续下载（\($0.dropFirst(8))）"
                        }
                        return "下载未完成，可继续下载或删除修复。错误：\($0.prefix(160))"
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
    private let manager: @MainActor () async throws -> ModelManager
    private var speechPreference: [Bool]?
    private let bindSpeech: @MainActor (Bool, Bool) async throws -> Void
    private let quiesce: @MainActor (String) async -> Void
    public init(
        manager: @escaping @MainActor () async throws -> ModelManager,
        quiesce: @escaping @MainActor (String) async -> Void,
        bindSpeech: @escaping @MainActor (Bool, Bool) async throws -> Void
    ) {
        self.manager = manager
        self.quiesce = quiesce
        self.bindSpeech = bindSpeech
    }
    public func snapshotResources() async throws -> [ModelResourceFact] {
        let manager = try await manager()
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
    public func observationFingerprint() async throws -> String {
        try Task.checkCancellation()
        let facts = try await snapshotResources()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(facts)
        guard data.count <= 65_536 else { throw ResourceInventoryError.capacityExceeded }
        try Task.checkCancellation()
        return String(decoding: data, as: UTF8.self)
    }
    public func configureSpeech(recognition: Bool, synthesis: Bool) async throws {
        let preference = [recognition, synthesis]
        guard speechPreference != preference else { return }
        try await bindSpeech(recognition, synthesis)
        speechPreference = preference
    }
    public func download(_ id: String, endpoint: String, allowsCellular: Bool) async throws {
        let manager = try await manager()
        try await manager.downloadArtifact(
            id, source: ModelDownloadSource(endpoint: endpoint, allowsCellular: allowsCellular))
    }
    public func cancel(_ id: String) async throws {
        let manager = try await manager()
        try await manager.cancelArtifact(id)
    }
    public func remove(_ id: String) async throws {
        let manager = try await manager()
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
        guard ["applicationControl", "assistant"].contains(context.source),
            context.sessionID == sessionID
                || (context.taskID != nil && context.taskExecutor == context.source)
        else { throw ResourcePresentationError.staleGeneration }
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
        guard invocation.context.sessionID == sessionID, generation == state.refreshGeneration else {
            throw ResourcePresentationError.staleGeneration
        }
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
        guard invocation.context.sessionID == sessionID, state.applyRefreshFailure(message, generation: generation)
        else {
            throw ResourcePresentationError.staleGeneration
        }
    }
}

private struct ResourcePreferencePresentationFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
