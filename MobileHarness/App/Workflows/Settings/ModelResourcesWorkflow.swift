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
    private var saved: ModelResourceSourceDraft?
    private var changing = false
    public init(
        store: @escaping @MainActor () throws -> LocalDocumentStore<ModelResourceSourceDraft>,
        read: @escaping @MainActor () async throws -> [ModelResourceItem],
        validate: @escaping @MainActor (ModelResourceSourceDraft) throws -> ModelResourceSourceDraft,
        download: @escaping @MainActor (String, ModelResourceSourceDraft) async throws -> Void,
        cancel: @escaping @MainActor (String) async throws -> Void,
        remove: @escaping @MainActor (String) async throws -> Void
    ) {
        self.makeStore = store
        self.read = read
        self.validate = validate
        downloadOperation = download
        cancelOperation = cancel
        removeOperation = remove
    }
    public func refresh() async throws -> [ModelResourceItem] { try await read() }
    public func restoreSource() async throws -> ModelResourceSourceDraft {
        if let saved { return saved }
        let value = try await persistence().load()?.value ?? ModelResourceSourceDraft()
        if let saved { return saved }
        let valid = try validate(value)
        saved = valid
        return valid
    }
    public func saveSource(_ source: ModelResourceSourceDraft) async throws {
        guard !changing else { throw DocumentStorageError.conflict }
        changing = true
        defer { changing = false }
        let value = try validate(source)
        let current = try await persistence().load()
        try await persistence().save(value, expecting: current?.revision)
        saved = value
    }
    public func download(_ id: String) async throws {
        let source = try await restoreSource()
        try await downloadOperation(id, source)
    }
    public func cancel(_ id: String) async throws { try await cancelOperation(id) }
    public func remove(_ id: String) async throws { try await removeOperation(id) }
}
