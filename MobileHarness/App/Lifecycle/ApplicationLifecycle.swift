import Foundation

/// A static service graph. Modules implement their own work; the host only orders it.
public struct ManagedService: Sendable {
    public let id: String
    public let continuesInBackground: Bool
    public let dependencies: Set<String>
    public let start: @MainActor @Sendable () async throws -> Void
    public let invalidate: @MainActor @Sendable () -> Void
    public let foreground: @MainActor @Sendable (Bool) async throws -> Void
    public let stop: @MainActor @Sendable () async throws -> Void

    public init(
        id: String, dependencies: Set<String> = [], continuesInBackground: Bool = false,
        start: @escaping @MainActor @Sendable () async throws -> Void,
        invalidate: @escaping @MainActor @Sendable () -> Void = {},
        foreground: @escaping @MainActor @Sendable (Bool) async throws -> Void = { _ in },
        stop: @escaping @MainActor @Sendable () async throws -> Void
    ) {
        self.id = id
        self.continuesInBackground = continuesInBackground
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
    private var suspensionPending = false
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
            if state == .running { suspensionPending = true }
            // Runs synchronously even while a native/model start is suspended.
            for service in services.reversed() where state != .running || !service.continuesInBackground {
                service.invalidate()
            }
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
                let value = suspensionPending ? false : desiredForeground
                if !value { suspensionPending = false }
                for service in value ? started : Array(started.reversed()) {
                    guard !closed, !Task.isCancelled else { return }
                    // A suspension must reach every service before any resumed admission.
                    if value, sceneRevision != selected { break }
                    do { try await service.foreground(value) } catch {
                        let result = ApplicationLifecycleFailure(service: service.id, primary: error, cleanup: [])
                        sceneFailure = result
                        failure = result
                        onFailure?(result)
                    }
                }
                if !suspensionPending, value == desiredForeground, selected == sceneRevision { return }
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

/// A host-owned, single-worker readiness barrier, independent of page task lifetime.
@MainActor
public final class ForegroundPreparation {
    public enum State: Equatable, Sendable {
        case inactive, checking
        case preparing(String)
        case ready, deferred
        case failed(component: String, message: String)
    }
    public typealias LoadingReport = @MainActor @Sendable (Bool) -> Void
    public struct Step {
        public let id: String
        public let isReady: @MainActor () async throws -> Bool
        public let prepare: @MainActor (@escaping LoadingReport) async throws -> Void
        public init(
            id: String, isReady: @escaping @MainActor () async throws -> Bool,
            prepare: @escaping @MainActor (@escaping LoadingReport) async throws -> Void
        ) {
            self.id = id
            self.isReady = isReady
            self.prepare = prepare
        }
    }
    public private(set) var state: State = .inactive
    private var steps: (@MainActor () -> [Step])?
    private var onValidationFailure: (@MainActor (String, ValidationError) -> Void)?
    private var canPrepare: (@MainActor () -> Bool)?
    private var project: (@MainActor (State) -> Void)?
    private var worker: Task<Void, Never>?
    private var active = false
    private var closed = false
    private var pending = false
    private var revision: UInt64 = 0
    public init(
        steps: @escaping @MainActor () -> [Step], canPrepare: @escaping @MainActor () -> Bool,
        project: @escaping @MainActor (State) -> Void,
        onValidationFailure: @escaping @MainActor (String, ValidationError) -> Void = { _, _ in }
    ) {
        self.steps = steps
        self.canPrepare = canPrepare
        self.project = project
        self.onValidationFailure = onValidationFailure
    }
    deinit { worker?.cancel() }
    private func publish(_ value: State) {
        state = value
        project?(value)
    }
    public func setActive(_ value: Bool) {
        guard !closed, value != active else { return }
        active = value
        revision &+= 1
        pending = value
        worker?.cancel()
        publish(value ? .checking : .inactive)
        startIfIdle()
    }
    /// Configuration changes fence the old result and retain only one replacement request.
    public func refresh() {
        guard active, !closed else { return }
        revision &+= 1
        pending = true
        worker?.cancel()
        publish(.checking)
        startIfIdle()
    }
    private func startIfIdle() {
        guard active, !closed, pending, worker == nil else { return }
        pending = false
        let selected = revision
        worker = Task { [weak self] in
            await self?.run(selected)
            self?.finished()
        }
    }
    private func run(_ selected: UInt64) async {
        var component = "configuration"
        do {
            let selectedSteps = steps?() ?? []
            for step in selectedSteps {
                component = step.id
                try check(selected)
                let ready = try await step.isReady()
                try check(selected)
                if ready { continue }
                guard canPrepare?() == true else {
                    publish(.deferred)
                    return
                }
                let componentID = step.id
                try await step.prepare { [weak self] loading in
                    guard let self, self.active, !self.closed, selected == self.revision else { return }
                    self.publish(loading ? .preparing(componentID) : .checking)
                }
                try check(selected)
                publish(.checking)
                guard try await step.isReady() else { throw ValidationError.notReady }
                try check(selected)
            }
            for step in selectedSteps {
                component = step.id
                try check(selected)
                guard try await step.isReady() else { throw ValidationError.notReady }
                try check(selected)
            }
            publish(.ready)
        } catch {
            guard active, !closed, selected == revision, !Task.isCancelled else { return }
            publish(.failed(component: component, message: String(String(describing: error).prefix(2048))))
            if let failure = error as? ValidationError { onValidationFailure?(component, failure) }
        }
    }
    public enum ValidationError: Error, Sendable, Equatable { case notReady }
    private func check(_ selected: UInt64) throws {
        try Task.checkCancellation()
        guard active, !closed, selected == revision else { throw CancellationError() }
    }
    private func finished() {
        worker = nil
        startIfIdle()
    }
    public func stop() async {
        closed = true
        active = false
        pending = false
        revision &+= 1
        worker?.cancel()
        await worker?.value
        publish(.inactive)
        steps = nil
        canPrepare = nil
        project = nil
        onValidationFailure = nil
    }
}
