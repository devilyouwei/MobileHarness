import Foundation

/// A static service graph. Modules implement their own work; the host only orders it.
public struct ManagedService: Sendable {
    public let id: String
    public let dependencies: Set<String>
    public let start: @MainActor @Sendable () async throws -> Void
    public let invalidate: @MainActor @Sendable () -> Void
    public let foreground: @MainActor @Sendable (Bool) async throws -> Void
    public let stop: @MainActor @Sendable () async throws -> Void

    public init(
        id: String, dependencies: Set<String> = [],
        start: @escaping @MainActor @Sendable () async throws -> Void,
        invalidate: @escaping @MainActor @Sendable () -> Void = {},
        foreground: @escaping @MainActor @Sendable (Bool) async throws -> Void = { _ in },
        stop: @escaping @MainActor @Sendable () async throws -> Void
    ) {
        self.id = id
        self.dependencies = dependencies
        self.start = start
        self.invalidate = invalidate
        self.foreground = foreground
        self.stop = stop
    }
}

public enum ServiceGraphError: Error, Equatable {
    case capacityExceeded
    case duplicate(String)
    case missingDependency(service: String, dependency: String)
    case cycle
    case closed
}

public struct ServiceCleanupFailure: Sendable {
    public let service: String
    public let error: any Error
}

public struct ApplicationLifecycleFailure: Error {
    public let service: String?
    public let primary: (any Error)?
    public let cleanup: [ServiceCleanupFailure]
}

/// One startup, one coalesced scene-state worker and one joined shutdown; no event queue.
@MainActor public final class ApplicationLifecycle {
    public enum State: Sendable { case idle, starting, running, suspended, failed, stopping, stopped }
    public private(set) var state: State = .idle
    public var onFailure: (@MainActor @Sendable (ApplicationLifecycleFailure) -> Void)?
    public private(set) var failure: ApplicationLifecycleFailure?
    private let services: [ManagedService]
    private var started: [ManagedService] = []
    private var startup: Task<Void, Error>?
    private var shutdown: Task<Void, Error>?
    private var sceneWorker: Task<Void, Never>?
    private var sceneFailure: ApplicationLifecycleFailure?
    private var sceneRevision: UInt64 = 0
    private var desiredForeground = true
    private var closed = false
    private var startingServices = false
    private var startupSuspended = false
    private var startupForegroundWaiter: CheckedContinuation<Void, Never>?

    public init(services: [ManagedService]) throws {
        guard services.count <= 64 else { throw ServiceGraphError.capacityExceeded }
        var ids = Set<String>()
        for service in services {
            guard ids.insert(service.id).inserted else { throw ServiceGraphError.duplicate(service.id) }
        }
        for service in services {
            for dependency in service.dependencies.sorted() where !ids.contains(dependency) {
                throw ServiceGraphError.missingDependency(service: service.id, dependency: dependency)
            }
        }
        var ordered: [ManagedService] = []
        var pending = services
        var emitted = Set<String>()
        while !pending.isEmpty {
            guard let index = pending.firstIndex(where: { $0.dependencies.isSubset(of: emitted) }) else {
                throw ServiceGraphError.cycle
            }
            let next = pending.remove(at: index)
            ordered.append(next)
            emitted.insert(next.id)
        }
        self.services = ordered
    }

    public func start() async throws {
        guard !closed else { throw ServiceGraphError.closed }
        if state == .running { return }
        if state == .suspended { throw CancellationError() }
        if let startup { return try await startup.value }
        guard state == .idle else { throw ServiceGraphError.closed }
        state = .starting
        let task = Task { try await startServices() }
        startup = task
        defer { startup = nil }
        try await task.value
    }

    private func startServices() async throws {
        var current: ManagedService?
        defer { startingServices = false }
        do {
            await waitForStartupForeground()
            try Task.checkCancellation()
            startingServices = true
            for service in services {
                try Task.checkCancellation()
                guard !closed, desiredForeground else { throw CancellationError() }
                current = service
                try await service.start()
                try Task.checkCancellation()
                guard !closed, desiredForeground else { throw CancellationError() }
                started.append(service)
                current = nil
            }
            state = .running
            setForeground(desiredForeground)
        } catch {
            // The failing start may already own resources, so clean it before its dependencies.
            var cleanup: [ServiceCleanupFailure] = []
            if let current {
                current.invalidate()
                do { try await current.stop() } catch { cleanup.append(.init(service: current.id, error: error)) }
            }
            cleanup += await stopStarted()
            if error is CancellationError, startupSuspended || closed, cleanup.isEmpty {
                state = closed ? .stopping : .suspended
                throw CancellationError()
            }
            let result = ApplicationLifecycleFailure(service: current?.id, primary: error, cleanup: cleanup)
            failure = result
            state = .failed
            onFailure?(result)
            throw result
        }
    }

    private func waitForStartupForeground() async {
        guard !desiredForeground, !closed, !Task.isCancelled else { return }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if desiredForeground || closed || Task.isCancelled {
                    continuation.resume()
                } else {
                    startupForegroundWaiter = continuation
                }
            }
        } onCancel: {
            Task { @MainActor in self.resumeStartupForeground() }
        }
    }

    private func resumeStartupForeground() {
        let waiter = startupForegroundWaiter
        startupForegroundWaiter = nil
        waiter?.resume()
    }

    public func setForeground(_ foreground: Bool) {
        guard !closed else { return }
        desiredForeground = foreground
        sceneRevision &+= 1
        if foreground { resumeStartupForeground() }
        if !foreground {
            // Runs synchronously even while a native/model start is suspended.
            for service in services.reversed() { service.invalidate() }
            if state == .starting, startingServices {
                startupSuspended = true
                startup?.cancel()
            }
        }
        guard state == .running, sceneWorker == nil else { return }
        sceneWorker = Task {
            defer { sceneWorker = nil }
            while !Task.isCancelled, !closed {
                let selected = sceneRevision
                let value = desiredForeground
                for service in value ? started : Array(started.reversed()) {
                    guard !closed, !Task.isCancelled else { return }
                    if sceneRevision != selected { break }
                    do { try await service.foreground(value) } catch {
                        let result = ApplicationLifecycleFailure(service: service.id, primary: error, cleanup: [])
                        sceneFailure = result
                        failure = result
                        onFailure?(result)
                    }
                }
                if selected == sceneRevision { return }
            }
        }
    }

    public func waitForForeground() async throws {
        await sceneWorker?.value
        if let sceneFailure { throw sceneFailure }
    }

    public func stop() async throws {
        if let shutdown { return try await shutdown.value }
        if state == .stopped { return }
        closed = true
        for service in services.reversed() { service.invalidate() }
        startup?.cancel()
        resumeStartupForeground()
        sceneWorker?.cancel()
        let task = Task {
            _ = try? await startup?.value
            await sceneWorker?.value
            state = .stopping
            let rollback = failure
            let cleanup = (rollback?.cleanup ?? []) + (await stopStarted())
            state = .stopped
            if !cleanup.isEmpty {
                let result = ApplicationLifecycleFailure(
                    service: rollback?.service, primary: rollback?.primary, cleanup: cleanup)
                failure = result
                onFailure?(result)
                throw result
            }
        }
        shutdown = task
        try await task.value
    }

    private func stopStarted() async -> [ServiceCleanupFailure] {
        let retiring = started
        started.removeAll()
        var failures: [ServiceCleanupFailure] = []
        for service in retiring.reversed() {
            service.invalidate()
            do { try await service.stop() } catch { failures.append(.init(service: service.id, error: error)) }
        }
        return failures
    }
}
