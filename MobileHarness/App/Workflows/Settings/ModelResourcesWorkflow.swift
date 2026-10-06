import Foundation
import Storage
import UI

@MainActor public final class ModelResourcesWorkflow: ModelResourcesOperating {
    private let read: @MainActor () async throws -> [ModelResourceItem]
    private let validate: @MainActor (ModelResourceSourceDraft) throws -> ModelResourceSourceDraft
    private let downloadOperation: @MainActor (String, ModelResourceSourceDraft) async throws -> Void
    private let cancelOperation: @MainActor (String) async throws -> Void
    private let removeOperation: @MainActor (String) async throws -> Void
    private let makeStore: @MainActor () throws -> LocalDocumentStore<ModelResourceSourceDraft>
    private var cachedStore: LocalDocumentStore<ModelResourceSourceDraft>?
    private func persistence() throws -> LocalDocumentStore<ModelResourceSourceDraft> {
        if let cachedStore { return cachedStore }
        let value = try makeStore()
        cachedStore = value
        return value
    }
    private let apply: @MainActor (ModelResourceSourceDraft) async -> Void
    private var saved: ModelResourceSourceDraft?
    private var changing = false
    private var restoration: Task<ModelResourceSourceDraft, Error>?
    private var restoreWaiters = 0
    public init(
        store: @escaping @MainActor () throws -> LocalDocumentStore<ModelResourceSourceDraft>,
        read: @escaping @MainActor () async throws -> [ModelResourceItem],
        validate: @escaping @MainActor (ModelResourceSourceDraft) throws -> ModelResourceSourceDraft,
        download: @escaping @MainActor (String, ModelResourceSourceDraft) async throws -> Void,
        cancel: @escaping @MainActor (String) async throws -> Void,
        remove: @escaping @MainActor (String) async throws -> Void,
        apply: @escaping @MainActor (ModelResourceSourceDraft) async -> Void = { _ in }
    ) {
        self.apply = apply
        self.makeStore = store
        self.read = read
        self.validate = validate
        downloadOperation = download
        cancelOperation = cancel
        removeOperation = remove
    }
    public func refresh() async throws -> [ModelResourceItem] {
        let items = try await read()
        if let saved, !changing {
            let next = normalized(saved, items: items)
            if next.useCustomRecognition != saved.useCustomRecognition
                || next.useCustomSynthesis != saved.useCustomSynthesis
            {
                try await saveSource(next)
            }
        }
        return items
    }
    private func normalized(_ source: ModelResourceSourceDraft, items: [ModelResourceItem]) -> ModelResourceSourceDraft
    {
        var source = source
        if !ModelResourcePolicy.isInstalled(.recognition, in: items) { source.useCustomRecognition = false }
        if !ModelResourcePolicy.isInstalled(.synthesis, in: items) { source.useCustomSynthesis = false }
        return source
    }
    public func restoreSource() async throws -> ModelResourceSourceDraft {
        if let saved { return saved }
        guard restoreWaiters < 32 else { throw DocumentStorageError.conflict }
        restoreWaiters += 1
        defer { restoreWaiters -= 1 }
        if let restoration { return try await restoration.value }
        let task = Task { @MainActor in try await self.restoreInitialSource() }
        restoration = task
        defer { restoration = nil }
        return try await task.value
    }
    private func restoreInitialSource() async throws -> ModelResourceSourceDraft {
        let record = try await persistence().load()
        let value = record?.value ?? ModelResourceSourceDraft()
        if let saved { return saved }
        let validated = try validate(value)
        let valid = normalized(validated, items: try await read())
        if valid.allowsCellular != value.allowsCellular
            || valid.useCustomRecognition != value.useCustomRecognition
            || valid.useCustomSynthesis != value.useCustomSynthesis
        {
            try await persistence().save(valid, expecting: record?.revision)
        }
        await apply(valid)
        saved = valid
        return valid
    }
    public func saveSource(_ source: ModelResourceSourceDraft) async throws {
        guard !changing else { throw DocumentStorageError.conflict }
        changing = true
        defer { changing = false }
        let value = try validate(source)
        let items = try await read()
        if value.useCustomRecognition && !ModelResourcePolicy.isInstalled(.recognition, in: items) {
            throw ModelResourceSelectionError(group: .recognition)
        }
        if value.useCustomSynthesis && !ModelResourcePolicy.isInstalled(.synthesis, in: items) {
            throw ModelResourceSelectionError(group: .synthesis)
        }
        let current = try await persistence().load()
        try await persistence().save(value, expecting: current?.revision)
        await apply(value)
        saved = value
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

@MainActor public protocol ModelResourcesOperating: AnyObject {
    func refresh() async throws -> [ModelResourceItem]
    func restoreSource() async throws -> ModelResourceSourceDraft
    func saveSource(_ source: ModelResourceSourceDraft) async throws
    func download(_ id: String) async throws
    func cancel(_ id: String) async throws
    func remove(_ id: String) async throws
}

public struct ModelResourceSelectionError: LocalizedError, Sendable {
    public let group: ModelResourceGroup
    public init(group: ModelResourceGroup) { self.group = group }
    public var errorDescription: String? { group.installationMessage }
}

/// Installation requirements are business policy, independent of page presentation.
public enum ModelResourcePolicy {
    public static func isInstalled(_ group: ModelResourceGroup, in items: [ModelResourceItem]) -> Bool {
        let required: Set<String>
        switch group {
        case .recognition: required = ["nemotron"]
        case .synthesis: required = ["moss-tts-nano"]
        case .language: required = ["gemma4-e2b"]
        case .vision: required = ["yolo26n-pose"]
        }
        return required.allSatisfy { id in items.contains { $0.id == id && $0.installed && !$0.active } }
    }
}
