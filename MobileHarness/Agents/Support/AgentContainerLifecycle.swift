import Foundation

/// One owner for startup, suspension and terminal joined cleanup. No work is created by init.
@MainActor
final class AgentContainerLifecycle {
    private let open: @MainActor () async throws -> Void
    private let fence: @MainActor () -> Void
    private let foreground: @MainActor (Bool) async throws -> Void
    private let close: @MainActor () async throws -> Void
    private let report: @MainActor (AgentFailure) -> Void
    private var startup: Task<Void, any Error>?
    private var transition: Task<Void, any Error>?
    private var transitionFailure: (any Error)?
    private var cleanup: Task<Void, any Error>?
    private var shutdown: Task<Void, any Error>?
    private var closed = false
    private var started = false
    private var active = true
    private var desiredForeground = true
    private var needsSuspension = false
    private var revision: UInt64 = 0
    private(set) var healthFailure: AgentFailure?
    var isStopped: Bool { closed }
    var isForegroundRequested: Bool { desiredForeground && !closed }
    var isAvailable: Bool { started && active && !closed }

    init(
        start: @escaping @MainActor () async throws -> Void,
        invalidate: @escaping @MainActor () -> Void,
        foreground: @escaping @MainActor (Bool) async throws -> Void,
        stop: @escaping @MainActor () async throws -> Void,
        report: @escaping @MainActor (AgentFailure) -> Void
    ) {
        open = start
        fence = invalidate
        self.foreground = foreground
        close = stop
        self.report = report
    }
    func requireAvailable() throws {
        guard !closed else { throw AgentContainerError.stopped }
        guard isAvailable else { throw AgentContainerError.unavailable }
    }
    func start() async throws(AgentFailure) {
        do {
            guard !closed else { throw AgentContainerError.stopped }
            if started { return }
            let task: Task<Void, any Error>
            if let startup {
                task = startup
            } else {
                task = Task {
                    do {
                        try Task.checkCancellation()
                        try await open()
                        try Task.checkCancellation()
                        guard !closed, active else { throw CancellationError() }
                        started = true
                    } catch {
                        let primary = error
                        closed = true
                        fence()
                        var errors: [any Error] = []
                        do { try await finishCleanup() } catch { errors.append(error) }
                        throw AgentFailure(
                            component: "root", operation: "start", underlying: primary, cleanupErrors: errors)
                    }
                }
                startup = task
            }
            try await withTaskCancellationHandler {
                try await task.value
                try Task.checkCancellation()
            } onCancel: {
                task.cancel()
            }
        } catch { throw failure("start", error) }
    }
    func invalidate() {
        // The host may invalidate every service while initially inactive, before any start request.
        // A cold root owns no work or admission to fence; do not poison its first foreground start.
        guard !closed, started || startup != nil, desiredForeground || active else { return }
        desiredForeground = false
        needsSuspension = true
        active = false
        revision &+= 1
        fence()
        startup?.cancel()
        if started { _ = reconcileForeground() }
    }
    /// A single worker applies the latest desired state; intermediate updates never form a queue.
    private func reconcileForeground() -> Task<Void, any Error> {
        if let transition { return transition }
        let task = Task {
            defer { transition = nil }
            while !closed {
                let current = revision
                let value = needsSuspension ? false : desiredForeground
                do { try await foreground(value) } catch {
                    active = false
                    desiredForeground = false
                    transitionFailure = error
                    fence()
                    throw error
                }
                guard !closed else { return }
                if !value { needsSuspension = false }
                if current == revision, value == desiredForeground {
                    active = value
                    return
                }
            }
        }
        transition = task
        return task
    }
    func setForeground(_ value: Bool) async throws(AgentFailure) {
        do {
            guard !closed else { throw AgentContainerError.stopped }
            guard started else { throw AgentContainerError.unavailable }
            if let transitionFailure { throw transitionFailure }
            if !value { invalidate() }
            if value, !desiredForeground {
                desiredForeground = true
                revision &+= 1
            }
            try await reconcileForeground().value
            guard !closed else { throw AgentContainerError.stopped }
        } catch { throw failure("setForeground", error) }
    }
    func stop() async throws(AgentFailure) {
        do {
            if let shutdown { return try await shutdown.value }
            closed = true
            active = false
            desiredForeground = false
            revision &+= 1
            fence()
            startup?.cancel()
            let task = Task {
                _ = await startup?.result
                var errors: [any Error] = []
                if let transition {
                    do { try await transition.value } catch { errors.append(error) }
                } else if let transitionFailure {
                    errors.append(transitionFailure)
                }
                do { try await finishCleanup() } catch { errors.append(error) }
                if let primary = errors.first {
                    throw AgentFailure(
                        component: "root", operation: "stop", underlying: primary,
                        cleanupErrors: Array(errors.dropFirst()), code: .cleanupFailed)
                }
            }
            shutdown = task
            try await task.value
        } catch { throw failure("stop", error) }
    }
    private func finishCleanup() async throws {
        if let cleanup { return try await cleanup.value }
        let task = Task { try await close() }
        cleanup = task
        try await task.value
    }
    private func failure(_ operation: String, _ error: any Error) -> AgentFailure {
        let value = AgentFailure(component: "root", operation: operation, underlying: error)
        if value.code == .executionFailed || value.code == .cleanupFailed { healthFailure = value }
        report(value)
        return value
    }
}
