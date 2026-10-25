import Foundation
import FunctionContracts
import PlatformKit
import UI

/// View facade; injected Agent operations own preference validation, persistence and model effects.
@MainActor public final class ModelResourcesClient: ModelResourcesOperating {
    private let read: @MainActor (UInt64?) async throws -> ModelResourceViewSnapshot
    private let restoreOperation: @MainActor () async throws -> ModelResourceSourceDraft
    private let saveOperation: @MainActor (ModelResourceSourceDraft) async throws -> ModelResourceSourceDraft
    private let downloadOperation: @MainActor (String, ModelResourceSourceDraft) async throws -> Void
    private let cancelOperation: @MainActor (String) async throws -> Void
    private let removeOperation: @MainActor (String) async throws -> Void
    private var saved: ModelResourceSourceDraft?
    private var changing = false
    private var restoration: Task<ModelResourceSourceDraft, Error>?
    private var restoreWaiters = 0
    private var stopped = false
    public init(
        read: @escaping @MainActor (UInt64?) async throws -> ModelResourceViewSnapshot,
        restore: @escaping @MainActor () async throws -> ModelResourceSourceDraft,
        save: @escaping @MainActor (ModelResourceSourceDraft) async throws -> ModelResourceSourceDraft,
        download: @escaping @MainActor (String, ModelResourceSourceDraft) async throws -> Void,
        cancel: @escaping @MainActor (String) async throws -> Void,
        remove: @escaping @MainActor (String) async throws -> Void
    ) {
        self.read = read
        restoreOperation = restore
        saveOperation = save
        downloadOperation = download
        cancelOperation = cancel
        removeOperation = remove
    }
    public func refresh(generation: UInt64? = nil) async throws -> ModelResourceViewSnapshot {
        let items = try await read(generation)
        if saved != nil, !changing {
            saved = nil
            _ = try await restoreSource()
        }
        return items
    }
    public func shutdown() async {
        stopped = true
        restoration?.cancel()
        _ = await restoration?.result
    }
    public func restoreSource() async throws -> ModelResourceSourceDraft {
        guard !stopped else { throw CancellationError() }
        if let saved { return saved }
        guard !stopped, !changing, restoreWaiters < 32 else {
            throw ResourceClientFailure("资源配置正在读取或保存，请稍后重试")
        }
        restoreWaiters += 1
        defer { restoreWaiters -= 1 }
        if let restoration { return try await restoration.value }
        let task = Task { @MainActor in try await self.restoreOperation() }
        restoration = task
        defer { restoration = nil }
        let value = try await task.value
        saved = value
        return value
    }
    public func saveSource(_ source: ModelResourceSourceDraft) async throws {
        guard !stopped, !changing, restoration == nil else {
            throw ResourceClientFailure("资源配置正在读取或保存，请稍后重试")
        }
        changing = true
        defer { changing = false }
        saved = nil
        saved = try await saveOperation(source)
    }
    public func download(_ id: String) async throws {
        let source = try await restoreSource()
        try await downloadOperation(id, source)
    }
    public func cancel(_ id: String) async throws { try await cancelOperation(id) }
    public func remove(_ id: String) async throws {
        try await removeOperation(id)
        _ = try await refresh()
    }
}

private struct ResourceClientFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
