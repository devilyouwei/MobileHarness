import Foundation
import FunctionContracts
import StorageCore

/// Bounded one-use staging; active native work belongs to the invoking execution.
public actor ProviderDiscoveryRequests: ProviderDiscoveryCapability, ProviderDiscoveryStaging {
    private struct Entry {
        let configuration: ProviderDiscoveryConfiguration
        let sessionID: String
        let deadline: ContinuousClock.Instant
    }
    private var entries: [String: Entry] = [:]
    private var completed: [String: (String, [String])] = [:]
    private let clock: @Sendable () -> ContinuousClock.Instant
    private let discover: @Sendable (ProviderDiscoveryConfiguration) async throws -> [String]
    public init(
        clock: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
        discover: @escaping @Sendable (ProviderDiscoveryConfiguration) async throws -> [String]
    ) {
        self.clock = clock
        self.discover = discover
    }
    public func stage(_ configuration: ProviderDiscoveryConfiguration, sessionID: String) throws -> String {
        try Task.checkCancellation()
        let now = clock()
        entries = entries.filter { $0.value.deadline > now }
        guard entries.count + completed.count < 32 else { throw ProviderDiscoveryError.capacityExceeded }
        guard configuration.url.utf8.count <= 2048, configuration.key.utf8.count <= 4096 else {
            throw ProviderDiscoveryError.invalidConfiguration
        }
        let id = UUID().uuidString
        entries[id] = Entry(
            configuration: configuration, sessionID: sessionID, deadline: now.advanced(by: .seconds(10)))
        return id
    }
    public func discard(_ requestID: String, sessionID: String) {
        if completed[requestID]?.0 == sessionID { completed[requestID] = nil }
        guard entries[requestID]?.sessionID == sessionID else { return }
        entries[requestID] = nil
    }
    public func result(_ requestID: String, sessionID: String) throws -> [String] {
        guard let value = completed[requestID], value.0 == sessionID else {
            throw ProviderDiscoveryError.invalidRequest
        }
        return value.1
    }
    public func discoverModels(requestID: String, sessionID: String) async throws -> [String] {
        try Task.checkCancellation()
        guard let entry = entries[requestID], entry.sessionID == sessionID else {
            throw ProviderDiscoveryError.invalidRequest
        }
        entries[requestID] = nil
        guard entry.deadline > clock() else { throw ProviderDiscoveryError.expired }
        do {
            let raw = try await discover(entry.configuration)
            guard Set(raw).count == raw.count else { throw ProviderDiscoveryError.invalidModels }
            let models = try ProviderModelList.eligible(raw)
            _ = try ProviderModelList.encoded(models)
            completed[requestID] = (sessionID, models)
            return models
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ProviderDiscoveryError { throw error } catch { throw ProviderDiscoveryError.unavailable }
    }
}
