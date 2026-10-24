import Actions
import AgentCore
import Foundation
import Gateway
import UI

/// Role registration and protected output ownership; UI requests are consumed by the Agent.
public actor ApplicationControlExecutionSession {
    public nonisolated let agent: ApplicationControlAgent
    public private(set) var cleanupFailure: AgentFailure?
    private let manager: AgentManager
    private let output: OutputGateway
    private var starting: Task<Void, Error>?
    private var pump: Task<Void, Never>?
    private var closing: Task<Void, Never>?
    private var started = false
    private var registered = false
    private var closed = false
    public private(set) var lastExecutionFailure: String?
    public private(set) var lastDiagnosticDeliveryFailure: String?

    public init(manager: AgentManager, output: OutputGateway, agent: ApplicationControlAgent) {
        self.manager = manager
        self.output = output
        self.agent = agent
    }
    public func prepareForInteraction() async throws {
        guard !closed else { throw CommunicationError.scopeClosed }
        if started { return }
        if let starting { return try await starting.value }
        let operation = Task {
            try await manager.register(agent)
            registered = true
            do {
                try Task.checkCancellation()
                let consumer = try await output.consumer(for: agent)
                await agent.bindUIExecution(consumer)
                try await manager.start(.applicationControl)
                try Task.checkCancellation()
                guard !closed else { throw CommunicationError.scopeClosed }
                started = true
                pump = Task {
                    do {
                        try await IndependentOutputWorkflow.consumeGeneration(agent.outputs) { envelope in
                            do { _ = try await consumer.execute(envelope) } catch {
                                await self.recordFailure(error, envelope: envelope)
                            }
                        }
                    } catch is CancellationError {} catch {
                        lastExecutionFailure = String(describing: error)
                    }
                    await closeResources()
                }
            } catch {
                let original = error
                do {
                    try await manager.remove(.applicationControl)
                    registered = false
                } catch { throw NativeCleanupFailure(errors: [original, error]) }
                throw original
            }
        }
        starting = operation
        defer { starting = nil }
        try await withTaskCancellationHandler {
            try await operation.value
        } onCancel: {
            operation.cancel()
        }
    }
    private func recordFailure(_ error: any Error, envelope: OutputEnvelope) {
        lastExecutionFailure = String(String(describing: error).prefix(512))
        if [ContainerFailureEvent.contract, RuntimeFailureEvent.contract, AppEnvironmentFact.contract].contains(
            envelope.inputMetadata.contract)
        {
            lastDiagnosticDeliveryFailure = lastExecutionFailure
        }
    }
    public func shutdown() async {
        await closeResources()
        await pump?.value
        pump = nil
    }
    private func closeResources() async {
        if let closing { return await closing.value }
        closed = true
        let cleanup = Task {
            starting?.cancel()
            _ = await starting?.result
            if registered {
                do { try await manager.remove(.applicationControl) } catch {
                    lastExecutionFailure = String(describing: error)
                    cleanupFailure = AgentFailure(
                        component: "applicationControl", operation: "stop",
                        underlying: error, code: .cleanupFailed)
                }
                registered = false
            }
            pump?.cancel()
        }
        closing = cleanup
        await cleanup.value
    }
}
public enum ApplicationControlIntentFailure: LocalizedError, Sendable {
    case execution(String)
    case presented(String)
    public var errorDescription: String? {
        switch self {
        case .execution(let message), .presented(let message): message
        }
    }
}

/// Provider transport preserves the producer code without interpreting provider policy.
public struct ProviderIntentFailure: LocalizedError, Sendable {
    public let message: String
    public let failureCode: String?
    public let presented: Bool
    public init(message: String, failureCode: String?, presented: Bool = false) {
        self.message = message
        self.failureCode = failureCode
        self.presented = presented
    }
    public var errorDescription: String? { message }
}

extension ProviderIntentFailure: ProviderRequestFailure {}

extension ApplicationControlIntentFailure: SettingsFailurePresenting {
    public var wasPresented: Bool {
        if case .presented = self { return true }
        return false
    }
}
