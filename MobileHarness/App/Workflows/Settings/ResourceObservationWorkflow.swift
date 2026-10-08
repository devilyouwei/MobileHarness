import Foundation

public enum ResourceObservationSample: Sendable {
    case changed
    case failed(String)
}
public enum ResourceObservationDelivery: Sendable {
    case accepted
    case retry(String)
}

/// Root-owned sampled input adaptation. No native SDK, business binding or presentation function selection.
@MainActor public final class ResourceObservationWorkflow {
    private enum Reading: Equatable {
        case facts(String)
        case failed(String)
    }
    private let read: @MainActor () async throws -> String
    private let deliver: @MainActor (ResourceObservationSample, UInt64) async throws -> ResourceObservationDelivery
    private let wait: @MainActor () async throws -> Void
    private let invalidate: @MainActor () -> Void
    private let report: @MainActor (String) -> Void
    private var worker: Task<Void, Never>?
    private var owner: UUID?
    private var foreground = false
    private var closed = false
    private var previous: Reading?
    private var sequence: UInt64 = 0
    public private(set) var lastFailure: String?
    public init(
        read: @escaping @MainActor () async throws -> String,
        deliver: @escaping @MainActor (ResourceObservationSample, UInt64) async throws -> ResourceObservationDelivery,
        wait: @escaping @MainActor () async throws -> Void = { try await Task.sleep(for: .seconds(1)) },
        invalidate: @escaping @MainActor () -> Void,
        report: @escaping @MainActor (String) -> Void
    ) {
        self.read = read
        self.deliver = deliver
        self.wait = wait
        self.invalidate = invalidate
        self.report = report
    }
    deinit { worker?.cancel() }
    public func setForeground(_ active: Bool) {
        guard !closed, foreground != active else { return }
        foreground = active
        previous = nil
        if active {
            startIfIdle()
        } else {
            invalidate()
            worker?.cancel()
        }
    }
    private func startIfIdle() {
        guard foreground, !closed, worker == nil else { return }
        let id = UUID()
        owner = id
        let wait = self.wait
        worker = Task { [weak self] in
            while !Task.isCancelled {
                guard let active = self?.foreground, active else { break }
                await self?.sample()
                if Task.isCancelled { break }
                do { try await wait() } catch {
                    if !Task.isCancelled { self?.cadenceFailed(error) }
                    break
                }
            }
            self?.finished(id)
        }
    }
    private func cadenceFailed(_ error: any Error) {
        foreground = false
        lastFailure = Self.bounded(error.localizedDescription)
        report(lastFailure ?? "Resource observation cadence failed")
    }
    private func finished(_ id: UUID) {
        guard owner == id else { return }
        owner = nil
        worker = nil
        startIfIdle()
    }
    private func sample() async {
        let reading: Reading
        do {
            let fingerprint = try await read()
            guard fingerprint.utf8.count <= 65_536 else { throw CocoaError(.coderInvalidValue) }
            reading = .facts(fingerprint)
        } catch {
            guard !Task.isCancelled else { return }
            reading = .failed(Self.bounded(error.localizedDescription))
        }
        guard foreground, !Task.isCancelled, reading != previous else { return }
        guard sequence < UInt64.max else {
            cadenceFailed(CocoaError(.coderInvalidValue))
            return
        }
        sequence += 1
        let sample: ResourceObservationSample
        switch reading {
        case .facts: sample = .changed
        case .failed(let message): sample = .failed(message)
        }
        do {
            let result = try await deliver(sample, sequence)
            guard foreground, !Task.isCancelled else { return }
            switch result {
            case .accepted:
                previous = reading
                if case .failed(let message) = reading { lastFailure = message } else { lastFailure = nil }
            case .retry(let message): lastFailure = Self.bounded(message)
            }
        } catch {
            guard foreground, !Task.isCancelled else { return }
            lastFailure = Self.bounded(error.localizedDescription)
            report(lastFailure ?? "Resource observation delivery failed")
        }
    }
    private static func bounded(_ raw: String) -> String {
        var bytes = Array(raw.utf8.prefix(2048))
        while String(bytes: bytes, encoding: .utf8) == nil { bytes.removeLast() }
        return String(decoding: bytes, as: UTF8.self)
    }
    public func shutdown() async {
        closed = true
        foreground = false
        invalidate()
        let task = worker
        task?.cancel()
        await task?.value
    }
}
