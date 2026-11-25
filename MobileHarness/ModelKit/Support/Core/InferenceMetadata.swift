import Foundation
import Synchronization

/// Stable identity for one bound model. Provider credentials and resource IDs are private.
public struct InferenceModelIdentity: Sendable, Equatable {
    public let modelID: String
    public let displayName: String?
    public init(modelID: String, displayName: String? = nil) {
        self.modelID = modelID
        self.displayName = displayName
    }
}

public struct InferenceMetadata: Sendable, Equatable {
    public let model: InferenceModelIdentity?
    public let providerModelID: String?
    public let startedAt: Date?
    public let firstOutputAt: Date?
    public let firstOutputLatency: Double?
    public let completedAt: Date?
    public let tokenUsage: InferenceTokenUsage?
    public let finishReason: InferenceFinishReason?
}

/// Request-local adapter state. Wrappers share it with the actual provider.
@_spi(InferenceAdapter) public final class InferenceMetadataRecorder: Sendable {
    private struct State {
        var model: InferenceModelIdentity?
        var providerModelID: String?
        var completedAt: Date?
        var usage: InferenceTokenUsage?
        var finishReason: InferenceFinishReason?
    }
    private let state = Mutex(State())
    let timing: InferenceTiming

    public init(model: InferenceModelIdentity? = nil, timing: InferenceTiming? = nil) {
        self.timing = timing ?? InferenceTiming()
        bind(model)
    }
    public func bind(_ model: InferenceModelIdentity?) {
        state.withLock { if $0.model == nil { $0.model = model } }
    }
    public func start() { timing.start() }
    public func recordProviderModel(_ id: String?) {
        guard let id, !id.isEmpty, id.utf8.count <= 512 else { return }
        state.withLock { $0.providerModelID = id }
    }
    func recordUsage(_ usage: InferenceTokenUsage) { state.withLock { $0.usage = usage } }
    func recordFinishReason(_ reason: InferenceFinishReason) { state.withLock { $0.finishReason = reason } }
    func complete() {
        guard timing.snapshot != nil else { return }
        state.withLock { if $0.completedAt == nil { $0.completedAt = Date() } }
    }
    public var snapshot: InferenceMetadata {
        state.withLock {
            let times = timing.snapshot
            return InferenceMetadata(
                model: $0.model, providerModelID: $0.providerModelID, startedAt: times?.startedAt,
                firstOutputAt: times?.firstTokenAt, firstOutputLatency: times?.firstTokenLatency,
                completedAt: $0.completedAt, tokenUsage: $0.usage, finishReason: $0.finishReason)
        }
    }
}

public enum InferenceFinishReason: String, Sendable { case stop, lengthLimit, toolCalls }

public struct InferenceTokenUsage: Equatable, Sendable {
    public let input: Int?
    public let generated: Int?
    public let total: Int?
    public let cachedInput: Int?
    public let cacheWriteInput: Int?
    public init(
        input: Int?, generated: Int?, total: Int?, cachedInput: Int? = nil, cacheWriteInput: Int? = nil
    ) throws {
        let counts = [input, generated, total, cachedInput, cacheWriteInput]
        guard counts.compactMap({ $0 }).allSatisfy({ $0 >= 0 }) else {
            throw CapabilityError.invalidRequest("Invalid token usage")
        }
        if let input, (cacheWriteInput ?? 0) > input || (cachedInput ?? 0) > input - (cacheWriteInput ?? 0) {
            throw CapabilityError.invalidRequest("Invalid token usage")
        }
        self.input = input
        self.generated = generated
        self.total = total
        self.cachedInput = cachedInput
        self.cacheWriteInput = cacheWriteInput
    }
}

/// Per-request provider timing. Sampling never waits for the consumer or persistence.
public final class InferenceTiming: Sendable {
    public struct Snapshot: Sendable, Equatable {
        public let startedAt: Date
        public let firstTokenAt: Date?
        public let firstTokenLatency: Double?
    }
    private struct State {
        var startedAt: Date?
        var started: ContinuousClock.Instant?
        var firstTokenAt: Date?
        var latency: Double?
    }
    private let state = Mutex(State())
    public init() {}
    public func start() {
        state.withLock {
            guard $0.started == nil else { return }
            $0.startedAt = Date()
            $0.started = .now
        }
    }
    func recordFirstOutput() {
        state.withLock {
            guard let start = $0.started, $0.firstTokenAt == nil else { return }
            let elapsed = start.duration(to: .now).components
            $0.firstTokenAt = Date()
            $0.latency = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        }
    }
    public var snapshot: Snapshot? {
        state.withLock {
            guard let start = $0.startedAt else { return nil }
            return Snapshot(startedAt: start, firstTokenAt: $0.firstTokenAt, firstTokenLatency: $0.latency)
        }
    }
}
