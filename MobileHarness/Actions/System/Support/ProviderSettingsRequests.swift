import Foundation
import FunctionContracts

public protocol ProviderSettingsCapability: Sendable {
    func readSettings() async throws -> String
    func restoreSettings(requestID: UUID, sessionID: UUID) async throws
    func saveSettings(requestID: UUID, sessionID: UUID) async throws
}
@MainActor
public final class ProviderSettingsRequests: ProviderSettingsCapability {
    private enum Operation {
        case restore
        case save(ProviderSettings)
    }
    private enum Phase { case staged, executing, completed }
    private struct Entry {
        let sessionID: UUID
        let deadline: ContinuousClock.Instant
        let operation: Operation
        var phase = Phase.staged
        var result: ProviderSettings?
    }
    private let service: ProviderSettingsService
    private let clock: @Sendable () -> ContinuousClock.Instant
    private var entries: [UUID: Entry] = [:]
    public init(service: ProviderSettingsService, clock: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) {
        self.service = service
        self.clock = clock
    }
    public func readSettings() throws -> String { try service.summary() }
    public func stageRestore(sessionID: UUID) throws -> UUID { try stage(.restore, sessionID: sessionID) }
    public func stageSave(_ value: ProviderSettings, sessionID: UUID) throws -> UUID {
        guard value.url.utf8.count <= 2048, value.key.utf8.count <= 4096, value.model.utf8.count <= 512 else {
            throw ProviderSettingsError.invalidConfiguration
        }
        return try stage(.save(value), sessionID: sessionID)
    }
    private func stage(_ operation: Operation, sessionID: UUID) throws -> UUID {
        try Task.checkCancellation()
        entries = entries.filter { $0.value.phase != .staged || $0.value.deadline > clock() }
        guard entries.count < 32 else { throw ProviderSettingsError.busy }
        let id = UUID()
        entries[id] = Entry(sessionID: sessionID, deadline: clock().advanced(by: .seconds(10)), operation: operation)
        return id
    }
    public func discard(_ requestID: UUID, sessionID: UUID) {
        guard entries[requestID]?.sessionID == sessionID, entries[requestID]?.phase != .executing else { return }
        entries[requestID] = nil
    }
    public func result(_ requestID: UUID, sessionID: UUID) throws -> ProviderSettings {
        guard let entry = entries[requestID], entry.sessionID == sessionID,
            entry.phase == .completed, let value = entry.result
        else { throw ProviderSettingsError.busy }
        return value
    }
    public func take(_ requestID: UUID, sessionID: UUID) throws -> ProviderSettings {
        guard let entry = entries[requestID], entry.sessionID == sessionID, entry.phase == .completed,
            let result = entry.result
        else { throw ProviderSettingsError.invalidConfiguration }
        entries[requestID] = nil
        return result
    }
    public func restoreSettings(requestID: UUID, sessionID: UUID) async throws {
        try await execute(requestID, sessionID: sessionID, saving: false)
    }
    public func saveSettings(requestID: UUID, sessionID: UUID) async throws {
        try await execute(requestID, sessionID: sessionID, saving: true)
    }
    private func execute(_ id: UUID, sessionID: UUID, saving: Bool) async throws {
        try Task.checkCancellation()
        guard let entry = entries[id], entry.sessionID == sessionID, entry.phase == .staged,
            entry.deadline > clock()
        else { throw ProviderSettingsError.invalidConfiguration }
        switch (entry.operation, saving) {
        case (.restore, false), (.save, true): break
        default: throw ProviderSettingsError.invalidConfiguration
        }
        entries[id]?.phase = .executing
        do {
            let value: ProviderSettings
            switch entry.operation {
            case .restore: value = try await service.restore()
            case .save(let settings): value = try await service.save(settings)
            }
            entries[id]?.result = value
            entries[id]?.phase = .completed
        } catch {
            entries[id] = nil
            throw ProviderSettingsError.safe(error)
        }
    }
}

extension ProviderSettingsCapability {
    public func readSettings() async throws -> String { throw ProviderSettingsError.busy }
}
