import Foundation

/// Business policy is selected by the owning Agent, never by transport.
public enum SignalDisposition: Sendable, Equatable {
    case enqueue(priority: Int)
    case merge(key: String)
    case replaceLatest(key: String)
    case updateState
    case feedback
    case control
}

public protocol SignalPreprocessor: Sendable {
    associatedtype State: Sendable
    func classify(_ input: AgentInput, state: State) throws -> SignalDisposition
}

public protocol ContextBuilder: Sendable {
    associatedtype State: Sendable
    associatedtype Request: Sendable
    func build(state: State, batch: SignalBatch) throws -> Request
}

public struct SignalBatch: Codable, Sendable, Equatable {
    public let id: UUID
    public let taskID: UUID
    public let signalIDs: [UUID]
    public let admissionSequence: UInt64
    public init(id: UUID = UUID(), taskID: UUID, signalIDs: [UUID], admissionSequence: UInt64) throws {
        guard !signalIDs.isEmpty, signalIDs.count <= 128, Set(signalIDs).count == signalIDs.count,
            admissionSequence > 0
        else { throw CommunicationError.invalidPayload }
        self.id = id
        self.taskID = taskID
        self.signalIDs = signalIDs
        self.admissionSequence = admissionSequence
    }
}

/// Value state belongs to an Agent actor. Controls/receipts never enter this mailbox.
public struct SignalInbox: Sendable {
    public struct Entry: Sendable {
        public let input: AgentInput
        public let sequence: UInt64
        public let priority: Int
        public let key: String?
    }
    private var entries: [Entry] = []
    private var sequence: UInt64 = 0
    private let capacity: Int
    public var count: Int { entries.count }
    public var isEmpty: Bool { entries.isEmpty }
    public var inputs: [AgentInput] { entries.map(\.input) }
    public mutating func removeAll() { entries.removeAll() }
    public mutating func remove(id: UUID) { entries.removeAll { $0.input.id == id } }
    public mutating func takeBatch() -> [Entry] {
        guard let first = take() else { return [] }
        guard let key = first.key else { return [first] }
        let related = entries.filter {
            $0.key == key && $0.input.sessionID == first.input.sessionID
                && ($0.input.taskScope?.id ?? $0.input.metadata.rootID)
                    == (first.input.taskScope?.id ?? first.input.metadata.rootID)
        }
        .prefix(127)
        let selected = Set(related.map(\.sequence))
        entries.removeAll { selected.contains($0.sequence) }
        return [first] + related
    }
    public init(capacity: Int) throws {
        guard (1...8192).contains(capacity) else { throw CommunicationError.invalidPayload }
        self.capacity = capacity
    }
    @discardableResult public mutating func admit(_ input: AgentInput, disposition: SignalDisposition) throws -> UInt64
    {
        let priority: Int
        let key: String?
        switch disposition {
        case .enqueue(let value):
            priority = value
            key = nil
        case .merge(let value):
            priority = 0
            key = value
        case .replaceLatest(let value):
            priority = 0
            key = value
            guard sequence < UInt64.max else { throw CommunicationError.capacityExceeded }
            entries.removeAll { $0.key == value }
        default: throw CommunicationError.invalidPayload
        }
        guard entries.count < capacity, sequence < UInt64.max else { throw CommunicationError.capacityExceeded }
        sequence += 1
        entries.append(Entry(input: input, sequence: sequence, priority: priority, key: key))
        return sequence
    }
    /// Expiry is returned to the owner for an explicit terminal record, never silently discarded.
    public mutating func take() -> Entry? {
        guard
            let index = entries.indices.max(by: {
                entries[$0].priority == entries[$1].priority
                    ? entries[$0].sequence > entries[$1].sequence : entries[$0].priority < entries[$1].priority
            })
        else { return nil }
        return entries.remove(at: index)
    }
    public mutating func remove(sessionID: UUID) -> [AgentInput] {
        let removed = entries.filter { $0.input.sessionID == sessionID }.map(\.input)
        entries.removeAll { $0.input.sessionID == sessionID }
        return removed
    }
}

/// Serializes short Agent state/commit admission across actor suspension points.
/// It never holds a permit across model inference or device execution.
public final class AgentAdmissionGate: @unchecked Sendable {
    private let lock = NSLock()
    private let capacity: Int
    private var busy = false
    private var closed = false
    private var waiters: [(UUID, CheckedContinuation<Void, any Error>)] = []
    public init(capacity: Int = 32) { self.capacity = capacity }
    public func acquire() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let result: Result<Void, any Error>? = lock.withLock {
                    if Task.isCancelled { return .failure(CancellationError()) }
                    if closed { return .failure(HarnessError.notRunning) }
                    if !busy {
                        busy = true
                        return .success(())
                    }
                    guard waiters.count < capacity else { return .failure(CommunicationError.capacityExceeded) }
                    waiters.append((id, continuation))
                    return nil
                }
                if let result { continuation.resume(with: result) }
            }
        } onCancel: {
            self.cancel(id)
        }
    }
    private func cancel(_ id: UUID) {
        let waiter = lock.withLock { () -> CheckedContinuation<Void, any Error>? in
            guard let index = waiters.firstIndex(where: { $0.0 == id }) else { return nil }
            return waiters.remove(at: index).1
        }
        waiter?.resume(throwing: CancellationError())
    }
    public func release() {
        let waiter = lock.withLock { () -> CheckedContinuation<Void, any Error>? in
            if !waiters.isEmpty { return waiters.removeFirst().1 }
            busy = false
            return nil
        }
        waiter?.resume()
    }
    public func close() {
        let pending = lock.withLock {
            closed = true
            let pending = waiters
            waiters.removeAll()
            return pending
        }
        for (_, waiter) in pending { waiter.resume(throwing: HarnessError.notRunning) }
    }
}
