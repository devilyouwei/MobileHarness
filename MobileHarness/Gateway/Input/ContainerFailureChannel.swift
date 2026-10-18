import AgentCore
import Foundation
import Synchronization

public struct ContainerFailureRecord: Sendable {
    public enum Delivery: String, Sendable { case pending, published, failed, dropped }
    public var event: ContainerFailureEvent
    public var delivery: Delivery = .pending
    public var deliveryFailure: String?
}
public struct ContainerFailureSnapshot: Sendable {
    public let revision: UInt64
    public let records: [ContainerFailureRecord]
    public let evictedRecords: UInt64
    public let droppedPending: UInt64
    public let rejectedAfterStop: UInt64
}

/// Root-owned diagnostic transport. Reporting never waits for an Agent, storage or UI.
public final class ContainerFailureChannel: Sendable {
    public let scopeID = UUID().uuidString
    private struct Connection: Sendable {
        let id = UUID()
        let publish: @Sendable (ContainerFailureEvent) async throws -> Void
    }
    private struct State {
        var records: [ContainerFailureRecord] = []
        var pending: [String] = []
        var observers: [UUID: AsyncStream<ContainerFailureSnapshot>.Continuation] = [:]
        var evictedRecords: UInt64 = 0
        var droppedPending: UInt64 = 0
        var rejectedAfterStop: UInt64 = 0
        var revision: UInt64 = 0
        var closed = false
        var connection: Connection?
        var worker: Task<Void, Never>?
    }
    private let state = Mutex(State())
    private let wake = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    public init() {}
    deinit {
        wake.continuation.finish()
        state.withLock { $0.worker?.cancel() }
    }
    public func sink(module: String) -> @Sendable (String, String, any Error) -> Void {
        { [self] component, operation, error in
            report(module: module, component: component, operation: operation, error: error)
        }
    }
    @discardableResult public func report(
        module: String, component: String, operation: String,
        phase: ContainerFailureEvent.Phase = .operation, error: any Error, includeCancellation: Bool = false
    ) -> Bool {
        guard !(error is CancellationError) || includeCancellation else { return false }
        let event = ContainerFailureEvent(
            scopeID: scopeID, module: String(module.prefix(16)), component: String(component.prefix(64)),
            operation: String(operation.prefix(64)), phase: phase,
            code: String(String(reflecting: type(of: error)).prefix(32)),
            message: String(String(describing: error).prefix(512)))
        let accepted = state.withLock { value in
            guard !value.closed else {
                value.rejectedAfterStop &+= 1
                value.revision &+= 1
                return false
            }
            let id: String
            if let index = value.records.firstIndex(where: {
                $0.event.module == event.module && $0.event.component == event.component
                    && $0.event.operation == event.operation && $0.event.phase == event.phase
                    && $0.event.code == event.code && $0.event.message == event.message
            }) {
                id = value.records[index].event.id
                if value.records[index].event.occurrences < UInt64.max { value.records[index].event.occurrences += 1 }
                value.records[index].event.lastOccurred = event.lastOccurred
                value.records[index].delivery = .pending
                value.records[index].deliveryFailure = nil
            } else {
                if value.records.count == 128 {
                    let removed = value.records.removeFirst().event.id
                    if value.pending.contains(removed) { value.droppedPending &+= 1 }
                    value.pending.removeAll { $0 == removed }
                    value.evictedRecords &+= 1
                }
                id = event.id
                value.records.append(ContainerFailureRecord(event: event))
            }
            Self.enqueue(id, state: &value)
            value.revision &+= 1
            return true
        }
        if accepted {
            notify()
            wake.continuation.yield(())
        }
        return accepted
    }
    private static func enqueue(_ id: String, state: inout State) {
        guard !state.pending.contains(id) else { return }
        if state.pending.count == 64 {
            let removed = state.pending.removeFirst()
            if let index = state.records.firstIndex(where: { $0.event.id == removed }) {
                state.records[index].delivery = .dropped
            }
            state.droppedPending &+= 1
        }
        state.pending.append(id)
    }
    public func start() {
        state.withLock { value in
            guard !value.closed, value.worker == nil else { return }
            let stream = wake.stream
            value.worker = Task { [weak self] in
                for await _ in stream {
                    guard !Task.isCancelled else { return }
                    while !Task.isCancelled, let self, await self.deliverNext() {}
                }
            }
        }
        wake.continuation.yield(())
    }
    public func connect(input: InputGateway, sessionID: String) {
        connect { event in
            let message = AgentMessage(
                contract: ContainerFailureEvent.contract, content: event, maximumBytes: 8192,
                validate: { try $0.validate() })
            try await input.publish(
                ExternalInputDraft(
                    sessionID: sessionID, payload: .observation(message), source: ContainerFailureEvent.source,
                    rootID: event.id))
        }
    }
    /// Injectable publication seam; failures update this journal and never report back into it.
    public func connect(publish: @escaping @Sendable (ContainerFailureEvent) async throws -> Void) {
        state.withLock { value in
            guard !value.closed else { return }
            value.connection = Connection(publish: publish)
            let failed = value.records.filter { $0.delivery == .failed }
            for record in failed {
                Self.enqueue(record.event.id, state: &value)
            }
        }
        wake.continuation.yield(())
    }
    public func disconnect() { state.withLock { $0.connection = nil } }
    private func deliverNext() async -> Bool {
        let next = state.withLock { value -> (ContainerFailureEvent, Connection)? in
            guard !value.closed, let connection = value.connection, !value.pending.isEmpty else { return nil }
            let id = value.pending.removeFirst()
            guard let record = value.records.first(where: { $0.event.id == id }) else { return nil }
            return (record.event, connection)
        }
        guard let (event, connection) = next else { return false }
        let failure: String?
        do {
            try Task.checkCancellation()
            try await connection.publish(event)
            failure = nil
        } catch {
            failure = String(String(describing: error).prefix(512))
        }
        state.withLock { value in
            guard let index = value.records.firstIndex(where: { $0.event.id == event.id }) else { return }
            value.revision &+= 1
            guard value.connection?.id == connection.id else {
                if !value.closed { Self.enqueue(event.id, state: &value) }
                return
            }
            // A repeat reported during publication remains pending with its newer count.
            if value.pending.contains(event.id) { return }
            value.records[index].delivery = failure == nil ? .published : .failed
            value.records[index].deliveryFailure = failure
        }
        notify()
        return true
    }
    public func snapshot() -> ContainerFailureSnapshot { state.withLock { Self.snapshot($0) } }
    private static func snapshot(_ value: State) -> ContainerFailureSnapshot {
        ContainerFailureSnapshot(
            revision: value.revision, records: value.records, evictedRecords: value.evictedRecords,
            droppedPending: value.droppedPending, rejectedAfterStop: value.rejectedAfterStop)
    }
    public func observe() throws -> AsyncStream<ContainerFailureSnapshot> {
        let id = UUID()
        let pair = AsyncStream<ContainerFailureSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let initial = try state.withLock { value -> (ContainerFailureSnapshot, Bool) in
            guard value.observers.count < 8 else { throw CommunicationError.capacityExceeded }
            if !value.closed { value.observers[id] = pair.continuation }
            return (Self.snapshot(value), value.closed)
        }
        pair.continuation.onTermination = { [weak self] _ in
            self?.state.withLock { $0.observers[id] = nil }
        }
        pair.continuation.yield(initial.0)
        if initial.1 { pair.continuation.finish() }
        return pair.stream
    }
    private func notify() {
        let (snapshot, observers) = state.withLock { (Self.snapshot($0), Array($0.observers.values)) }
        for observer in observers { observer.yield(snapshot) }
    }
    public func stop() async {
        let (worker, observers) = state.withLock { value in
            value.closed = true
            value.connection = nil
            let observers = Array(value.observers.values)
            value.observers.removeAll()
            return (value.worker, observers)
        }
        worker?.cancel()
        wake.continuation.finish()
        await worker?.value
        let snapshot = snapshot()
        for observer in observers {
            observer.yield(snapshot)
            observer.finish()
        }
    }
}
