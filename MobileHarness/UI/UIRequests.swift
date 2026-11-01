import Foundation

public enum UIRequestError: Error, Sendable, Equatable {
    case unavailable, duplicateConsumer, capacityExceeded, stale, consumerEnded
}

/// A request receipt belongs to one root generation. Acceptance is not completion.
@MainActor public struct UIRequest<Value: Sendable, Reply: Sendable>: Sendable {
    public let id: UUID
    public let generation: UUID
    public let submittedAt: ContinuousClock.Instant
    public let value: Value
    private let owner: UIRequests<Value, Reply>
    fileprivate init(id: UUID, generation: UUID, value: Value, owner: UIRequests<Value, Reply>) {
        submittedAt = .now
        self.id = id
        self.generation = generation
        self.value = value
        self.owner = owner
    }
    public func onCancellation(_ operation: @escaping @Sendable () -> Void) {
        owner.observeCancellation(id, generation: generation, operation: operation)
    }
    @discardableResult public func accept() -> Bool { owner.accept(id, generation: generation) }
    @discardableResult public func complete(_ result: Result<Reply, any Error>) -> Bool {
        owner.complete(id, generation: generation, result: result)
    }
}

/// Single-consumer local request/reply capability; no topics, routing or business authority.
@MainActor public final class UIRequests<Value: Sendable, Reply: Sendable> {
    private struct Pending {
        let continuation: CheckedContinuation<Reply, any Error>
        var accepted = false
        let control: Bool
        var cancel: (@Sendable () -> Void)?
    }
    private var pending: [UUID: Pending] = [:]
    private var consumer: AsyncThrowingStream<UIRequest<Value, Reply>, any Error>.Continuation?
    private var controlConsumer: AsyncThrowingStream<UIRequest<Value, Reply>, any Error>.Continuation?
    private var consumerID: UUID?
    public private(set) var generation = UUID()
    private var available = false
    private var stopped = false
    private let controlOnly: Bool
    public var outstanding: Int { pending.count }
    public var acceptedCount: Int { pending.values.filter(\.accepted).count }
    public init(controlOnly: Bool = false) { self.controlOnly = controlOnly }
    public func listen() throws -> AsyncThrowingStream<UIRequest<Value, Reply>, any Error> {
        guard !stopped else { throw UIRequestError.unavailable }
        guard consumer == nil else { throw UIRequestError.duplicateConsumer }
        let id = UUID()
        let pair = AsyncThrowingStream<UIRequest<Value, Reply>, any Error>.makeStream(
            bufferingPolicy: .bufferingOldest(64))
        consumerID = id
        consumer = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.disconnect(id) }
        }
        return pair.stream
    }
    public func listenControls() throws -> AsyncThrowingStream<UIRequest<Value, Reply>, any Error> {
        guard !stopped, let id = consumerID else { throw UIRequestError.unavailable }
        guard controlConsumer == nil else { throw UIRequestError.duplicateConsumer }
        let pair = AsyncThrowingStream<UIRequest<Value, Reply>, any Error>.makeStream(
            bufferingPolicy: .bufferingOldest(1))
        controlConsumer = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in Task { @MainActor in self?.disconnect(id) } }
        return pair.stream
    }
    public func stopListening() {
        guard let id = consumerID else { return }
        let continuation = consumer
        let controls = controlConsumer
        disconnect(id)
        continuation?.finish()
        controls?.finish()
    }
    public func listeningToken() throws -> UUID {
        guard let consumerID else { throw UIRequestError.unavailable }
        return consumerID
    }
    public func stopListening(token: UUID) {
        guard consumerID == token else { return }
        stopListening()
    }
    public func submit(_ value: Value) async throws -> Reply { try await enqueue(value, control: false) }
    public func submitControl(_ value: Value) async throws -> Reply { try await enqueue(value, control: true) }
    private func enqueue(_ value: Value, control: Bool) async throws -> Reply {
        try Task.checkCancellation()
        guard control || !controlOnly else { throw UIRequestError.unavailable }
        guard available, !stopped, let consumer = control ? controlConsumer : consumer else {
            throw UIRequestError.unavailable
        }
        guard pending.values.filter({ $0.control == control }).count < (control ? 1 : 64) else {
            throw UIRequestError.capacityExceeded
        }
        let id = UUID()
        let generation = generation
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pending[id] = Pending(continuation: continuation, control: control)
                let receipt = UIRequest(id: id, generation: generation, value: value, owner: self)
                guard case .enqueued = consumer.yield(receipt) else {
                    _ = complete(id, generation: generation, result: .failure(UIRequestError.capacityExceeded))
                    return
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                _ = self?.cancel(id, generation: generation)
            }
        }
    }
    fileprivate func accept(_ id: UUID, generation: UUID) -> Bool {
        guard self.generation == generation, available, pending[id]?.accepted == false else { return false }
        pending[id]?.accepted = true
        return true
    }
    fileprivate func complete(_ id: UUID, generation: UUID, result: Result<Reply, any Error>) -> Bool {
        guard self.generation == generation, let item = pending.removeValue(forKey: id) else { return false }
        item.continuation.resume(with: result)
        return true
    }
    fileprivate func observeCancellation(_ id: UUID, generation: UUID, operation: @escaping @Sendable () -> Void) {
        guard self.generation == generation, pending[id] != nil else {
            operation()
            return
        }
        pending[id]?.cancel = operation
    }
    private func cancel(_ id: UUID, generation: UUID) {
        guard self.generation == generation, let item = pending.removeValue(forKey: id) else { return }
        item.cancel?()
        item.continuation.resume(throwing: CancellationError())
    }
    private func disconnect(_ id: UUID) {
        guard consumerID == id else { return }
        consumer = nil
        controlConsumer?.finish()
        controlConsumer = nil
        consumerID = nil
        failPending(UIRequestError.consumerEnded)
    }
    private func failPending(_ error: any Error) {
        let values = pending.values
        pending.removeAll()
        for item in values {
            item.cancel?()
            item.continuation.resume(throwing: error)
        }
    }
    public func setAvailable(_ value: Bool) {
        guard !stopped else { return }
        available = value
        if !value {
            failPending(UIRequestError.stale)
            generation = UUID()
        }
    }
    /// Explicit controls cancel directly; they do not enter the ordinary request FIFO.
    public func cancelOutstanding() {
        failPending(CancellationError())
        generation = UUID()
    }
    public func stop() {
        guard !stopped else { return }
        stopped = true
        available = false
        failPending(UIRequestError.unavailable)
        generation = UUID()
        consumer?.finish()
        controlConsumer?.finish()
        controlConsumer = nil
        consumer = nil
        consumerID = nil
    }
}

public enum HomeInput: Sendable {
    case text(String)
}
public struct CameraInput: Sendable {
    public enum Operation: String, Sendable {
        case open, close, flip, retry, takePhoto, savePhoto, ignorePhoto, configure, cancelCapture, startRecording,
            stopRecording, saveVideo, ignoreVideo, perceptionOpen, perceptionClose,
            perceptionFlip, perceptionRetry
    }
    public let operation: Operation
    public let recordingID: String?
    public let settings: CameraSettings?
    public let facing: CameraDirection?
    public let mediaID: String?
    public init(
        _ operation: Operation, facing: CameraDirection? = nil, mediaID: String? = nil, settings: CameraSettings? = nil,
        recordingID: String? = nil
    ) {
        self.operation = operation
        self.settings = settings
        self.recordingID = recordingID
        self.facing = facing
        self.mediaID = mediaID
    }
}
public enum SettingsInput: Sendable {
    case restore
    case discover(CloudSettingsDraft)
    case save(CloudSettingsDraft)
}
public enum SettingsReply: Sendable {
    case draft(CloudSettingsDraft)
    case models([String])
    case completed
}
public enum ResourcesInput: Sendable {
    case refresh(UInt64?)
    case restore
    case save(ModelResourceSourceDraft)
    case download(String, ModelResourceSourceDraft)
    case cancel(String)
    case remove(String)
}
public enum ResourcesReply: Sendable {
    case snapshot(ModelResourceViewSnapshot)
    case source(ModelResourceSourceDraft)
    case completed
}
public enum HistoryInput: Sendable {
    case refresh, startNew
    case summarize(String)
    case delete(String)
    case conversation(String)
    case message(String)
    case page(String, UInt64, String?)
    case archives(Int64)
    case photo(String, String)
}
public enum HistoryReply: Sendable {
    case completed
    case conversation(HistoryConversation)
    case archives([HistoryConversation])
    case photo(Data?)
}
public struct DeviceInput: Sendable {
    public let parameters: [String: String]
    public init(_ parameters: [String: String]) { self.parameters = parameters }
}
