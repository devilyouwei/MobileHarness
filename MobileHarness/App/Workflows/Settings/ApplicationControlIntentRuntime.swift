import AgentCore
import Agents
import AppPresentationWorkflow
import Foundation
import Gateway

/// Root-owned transport; Agent chooses business calls, ModelKit owns admitted background transfers.
public actor ApplicationControlIntentRuntime {
    public nonisolated let agent: ApplicationControlAgent
    private let manager: AgentManager
    private let input: InputGateway
    private let output: OutputGateway
    private var consumer: GatewayOutputConsumer?
    private let sessionID: UUID

    public func prepareForInteraction() async throws { try await ensureStarted() }
    private var started = false
    private var ownsRegistration = false
    private var closed = false
    private var admissions = 0
    private var diagnosing = false
    private var starting: Task<Void, Error>?
    private var pump: Task<Void, Never>?
    private var closing: Task<Void, Never>?
    private struct Request {
        var providerRequest = false
        var failureCode: String?
        var maximumCalls = 2
        var waiter: CheckedContinuation<String?, any Error>?
        var result: Result<String?, any Error>?
        var worker: Task<Void, Never>?
        var failure: String?
        var value: String?
        var failurePresented = false
        var failurePresentationAttempted = false
        var calls: Set<UUID> = []
    }
    private var requests: [UUID: Request] = [:]
    public init(
        sessionID: UUID, manager: AgentManager, input: InputGateway, output: OutputGateway,
        agent: ApplicationControlAgent
    ) {
        self.sessionID = sessionID
        self.manager = manager
        self.input = input
        self.output = output
        self.agent = agent
    }
    public func configureProvider(_ intent: ProviderSettingsIntent) async throws {
        do {
            let value = try await executeInput(
                intent.input(sessionID: sessionID), maximumCalls: intent.presentation ? 2 : 1, providerRequest: true)
            guard value == intent.requestID.uuidString else { throw CommunicationError.invalidPayload }
        } catch let transport as TransportFailure {
            throw ProviderIntentFailure(message: transport.message, failureCode: nil)
        }
    }
    public func discoverProvider(requestID: UUID, presentation: Bool = false) async throws -> String {
        do {
            guard
                let value = try await executeInput(
                    ProviderDiscoveryIntent(requestID: requestID, presentation: presentation).input(
                        sessionID: sessionID), maximumCalls: presentation ? 2 : 1,
                    providerRequest: true)
            else { throw CommunicationError.invalidPayload }
            return value
        } catch let transport as TransportFailure {
            throw ProviderIntentFailure(message: transport.message, failureCode: nil)
        }
    }
    /// One-way facts have no request slot, completion waiter or recipient acknowledgment.
    public func observeEnvironment(_ fact: AppEnvironmentFact) async throws {
        try fact.validate()
        guard !closed else { throw CommunicationError.scopeClosed }
        try await ensureStarted()
        try await input.publish(fact.input(sessionID: sessionID))
    }
    public func interact(_ intent: AppInteractionIntent) async throws {
        try intent.validate()
        do {
            _ = try await executeInput(intent.input(sessionID: sessionID), maximumCalls: 1)
        } catch let error as TransportFailure {
            throw ApplicationControlIntentFailure.execution(error.message)
        }
    }
    public func perform(_ intent: ModelResourceIntent) async throws { _ = try await executeIntent(intent) }
    public func inventory() async throws -> String {
        guard let value = try await executeIntent(.refreshResources) else { throw CommunicationError.invalidPayload }
        return value
    }
    public func presentInventory(generation: UInt64) async throws -> String {
        guard let value = try await executeIntent(.refreshPresentation(generation: generation)) else {
            throw CommunicationError.invalidPayload
        }
        return value
    }
    public func observe(_ observation: ModelResourceObservation, sequence: UInt64) async throws {
        try observation.validate()
        guard sequence > 0 else { throw CommunicationError.invalidPayload }
        guard !closed else { throw CommunicationError.scopeClosed }
        try await ensureStarted()
        try await input.publish(observation.input(sessionID: sessionID, sequence: sequence))
    }
    public func preferences(_ intent: ModelResourceIntent) async throws -> String {
        switch intent {
        case .restoreSource, .saveSource: break
        default: throw CommunicationError.unauthorized
        }
        guard let value = try await executeIntent(intent) else { throw CommunicationError.invalidPayload }
        return value
    }
    public func rejectInput(_ id: UUID, reason: String) async { if requests[id] != nil { await fail(id, reason) } }
    private func boundConsumer() throws -> GatewayOutputConsumer {
        guard let consumer else { throw CommunicationError.scopeClosed }
        return consumer
    }
    private func executeIntent(_ intent: ModelResourceIntent) async throws -> String? {
        if case .retire = intent { throw CommunicationError.unauthorized }
        try Task.checkCancellation()
        try intent.validate()
        let maximumCalls: Int
        switch intent {
        case .restoreSource, .saveSource: maximumCalls = 3
        default: maximumCalls = 2
        }
        let scope: ModelResourceHostFailure.Scope
        switch intent {
        case .restoreSource, .saveSource, .configureSpeech: scope = .preference
        case .refreshPresentation(let generation): scope = .refresh(generation: generation)
        default: scope = .operation
        }
        return try await executeBusinessInput(
            intent.input(sessionID: sessionID), scope: scope, maximumCalls: maximumCalls)
    }
    private struct TransportFailure: LocalizedError {
        let phase: ModelResourceHostFailure.Phase
        let message: String
        var errorDescription: String? { message }
    }
    private func executeBusinessInput(
        _ request: AgentInput, scope: ModelResourceHostFailure.Scope, failure: String? = nil, maximumCalls: Int = 2
    ) async throws -> String? {
        do { return try await executeInput(request, failure: failure, maximumCalls: maximumCalls) } catch let transport
            as TransportFailure
        {
            // executeInput has released its slot and joined the original worker before this new admission.
            guard started, !closed, admissions < 32, !diagnosing,
                !requests.values.contains(where: { $0.failurePresentationAttempted && $0.result == nil })
            else { throw ApplicationControlIntentFailure.execution(transport.message) }
            diagnosing = true
            defer { diagnosing = false }
            var bytes = Array(transport.message.utf8.prefix(2048))
            while String(bytes: bytes, encoding: .utf8) == nil { bytes.removeLast() }
            let diagnostic = ModelResourceHostFailure(
                requestID: request.id, phase: transport.phase, scope: scope,
                message: String(decoding: bytes, as: UTF8.self))
            do {
                _ = try await executeInput(
                    diagnostic.input(sessionID: sessionID), failure: transport.message, maximumCalls: 1)
            } catch ApplicationControlIntentFailure.presented(let diagnosticFailure) {
                throw ApplicationControlIntentFailure.presented(
                    transport.message + "; diagnostic: " + String(diagnosticFailure.prefix(512)))
            } catch {
                throw ApplicationControlIntentFailure.execution(
                    transport.message + "; diagnostic: " + String(String(describing: error).prefix(512)))
            }
            throw ApplicationControlIntentFailure.presented(transport.message)
        }
    }
    private func executeInput(
        _ request: AgentInput, failure: String? = nil, maximumCalls: Int = 2, providerRequest: Bool = false
    ) async throws
        -> String?
    {
        try Task.checkCancellation()
        guard !closed else { throw CommunicationError.scopeClosed }
        guard admissions < 32 else { throw CommunicationError.capacityExceeded }
        admissions += 1
        defer { admissions -= 1 }
        try await ensureStarted()
        guard !closed else { throw CommunicationError.scopeClosed }
        requests[request.id] = Request(providerRequest: providerRequest, maximumCalls: maximumCalls, failure: failure)
        defer { requests[request.id] = nil }
        do {
            try await input.publish(request)
        } catch {
            throw TransportFailure(phase: .admission, message: String(describing: error))
        }
        // Accepted work is independently owned; publication loss has a bounded business-result wait.
        let watchdog = Task {
            do { try await Task.sleep(for: .seconds(120)) } catch { return }
            await finish(request.id, .failure(ApplicationControlIntentFailure.execution("Result deadline exceeded")))
        }
        do {
            let value: String? = try await withCheckedThrowingContinuation { continuation in
                if let result = requests[request.id]?.result {
                    continuation.resume(with: result)
                } else {
                    requests[request.id]?.waiter = continuation
                }
            }
            watchdog.cancel()
            await watchdog.value
            await requests[request.id]?.worker?.value
            return value
        } catch {
            watchdog.cancel()
            await watchdog.value
            await requests[request.id]?.worker?.value
            throw error
        }
    }

    private func ensureStarted() async throws {
        if started { return }
        if let starting {
            try await starting.value
            return
        }
        let startup = Task { try await self.start() }
        starting = startup
        defer { starting = nil }
        try await startup.value
    }
    private func start() async throws {
        try Task.checkCancellation()
        guard !closed else { throw CommunicationError.scopeClosed }
        try await manager.register(agent)
        ownsRegistration = true
        do {
            try Task.checkCancellation()
            guard !closed else { throw CommunicationError.scopeClosed }
            try await manager.start(.applicationControl)
            consumer = try await output.consumer(for: agent)
        } catch {
            try await manager.remove(.applicationControl)
            ownsRegistration = false
            throw error
        }
        started = true
        let stream = agent.outputs
        pump = Task {
            do {
                try await IndependentOutputWorkflow.consumeGeneration(stream) { envelope in await self.consume(envelope)
                }
            } catch { await self.streamEnded() }
            await self.streamEnded()
        }
    }
    private func consume(_ envelope: OutputEnvelope) async {
        if envelope.roundID != nil || envelope.taskScope != nil && requests[envelope.inputID] == nil
            || {
                if case .communication = envelope.output { return true }
                return false
            }()
        {
            do { _ = try await boundConsumer().execute(envelope) } catch { await streamEnded() }
            return
        }
        guard !closed, envelope.source == .applicationControl, envelope.sessionID == sessionID else { return }
        if requests[envelope.inputID] == nil {
            // Published facts have no waiter; their effects/feedback and receiver errors are independent.
            let resourceFact = envelope.inputMetadata.contract == ModelResourceObservation.contract
            let receiverError: Bool
            if case .control(let value) = envelope.output {
                receiverError = value.hasPrefix("agent.error:")
            } else {
                receiverError = false
            }
            if resourceFact || receiverError {
                do { _ = try await boundConsumer().execute(envelope) } catch { await streamEnded() }
            }
            return
        }
        guard requests[envelope.inputID]?.result == nil
        else { return }
        switch envelope.output {
        case .toolCall(let call):
            await requests[envelope.inputID]?.worker?.value
            guard !closed, requests[envelope.inputID]?.result == nil else { return }
            guard let request = requests[envelope.inputID], request.calls.count < request.maximumCalls,
                !request.calls.contains(call.id)
            else {
                await fail(envelope.inputID, "Resource call sequence exceeded or duplicated")
                return
            }
            if Self.failurePresentationPaths.contains(call.toolPath) {
                requests[envelope.inputID]?.failurePresentationAttempted = true
            }
            requests[envelope.inputID]?.calls.insert(call.id)
            requests[envelope.inputID]?.worker = Task { await self.execute(envelope) }
        case .control(let control):
            await requests[envelope.inputID]?.worker?.value
            guard !closed, requests[envelope.inputID]?.result == nil else { return }
            do {
                let result = try await boundConsumer().execute(envelope)
                if result.isError {
                    throw ApplicationControlIntentFailure.execution(result.failure ?? "Resource control failed")
                }
                switch control {
                case let value where value.hasPrefix("agent.error:"):
                    await fail(envelope.inputID, value)
                case "application.control.finished":
                    await finish(envelope.inputID, .success(requests[envelope.inputID]?.value))
                case "application.control.failed":
                    await finish(
                        envelope.inputID,
                        .failure(
                            resourceFailure(envelope.inputID)))
                default: await fail(envelope.inputID, "Unsupported resource control")
                }
            } catch { await fail(envelope.inputID, String(describing: error)) }
        default: await fail(envelope.inputID, "Unsupported resource output")
        }
    }
    private static let failurePresentationPaths: Set<String> = [
        "UI.ResourcePresentation.showResourceFailure",
        "UI.ResourcePresentation.showResourceOperationFailure",
        "UI.ResourcePresentation.showResourcePreferenceFailure",
    ]
    private func execute(_ envelope: OutputEnvelope) async {
        do {
            guard case .toolCall(let call) = envelope.output, await output.returnsToolResult(for: call) else {
                throw ApplicationControlIntentFailure.execution("Resource call requires returning feedback")
            }
            let result = try await boundConsumer().execute(envelope)
            if let tool = result.tool {
                if tool.isError {
                    if requests[envelope.inputID]?.failureCode == nil {
                        requests[envelope.inputID]?.failureCode = tool.failureCode?.rawValue
                    }
                    let previous = requests[envelope.inputID]?.failure
                    requests[envelope.inputID]?.failure =
                        previous.map {
                            String($0.prefix(512)) + "; presentation: " + String(tool.value.prefix(512))
                        } ?? tool.value
                } else if Self.failurePresentationPaths.contains(call.toolPath)
                    || (call.toolPath == "UI.ResourcePresentation.showProviderResult"
                        && call.arguments["failureCode"] != nil)
                {
                    requests[envelope.inputID]?.failurePresented = true
                } else if [
                    "System.ModelResources.restoreSource", "System.ModelResources.saveSource",
                    "System.ModelResources.snapshotResources",
                    "UI.ResourcePresentation.showResources", "System.Provider.discoverModels",
                    "System.Provider.restoreSettings", "System.Provider.saveSettings",
                ].contains(
                    call.toolPath)
                {
                    let maximumBytes =
                        [
                            "System.ModelResources.snapshotResources", "UI.ResourcePresentation.showResources",
                            "System.Provider.discoverModels",
                        ]
                        .contains(call.toolPath) ? 65_536 : 2048
                    guard tool.value.utf8.count <= maximumBytes else { throw CommunicationError.invalidPayload }
                    requests[envelope.inputID]?.value = tool.value
                }
            }
            if let failure = result.failure { throw ApplicationControlIntentFailure.execution(failure) }
        } catch { await fail(envelope.inputID, String(describing: error)) }
    }
    private func resourceFailure(_ id: UUID) -> any Error {
        let message = requests[id]?.failure ?? "Resource operation failed"
        if requests[id]?.providerRequest == true {
            return ProviderIntentFailure(
                message: message, failureCode: requests[id]?.failureCode,
                presented: requests[id]?.failurePresented == true)
        }
        return requests[id]?.failurePresented == true
            ? ApplicationControlIntentFailure.presented(message) : ApplicationControlIntentFailure.execution(message)
    }
    private func fail(_ id: UUID, _ message: String) async {
        guard requests[id]?.result == nil else { return }
        var failure =
            requests[id]?.failure.map {
                String($0.prefix(512)) + "; dispatch: " + String(message.prefix(512))
            } ?? String(message.prefix(512))
        if !closed, !message.hasPrefix("agent.error: input rejected:") {
            do {
                try await input.publish(ModelResourceIntent.retire(id).input(sessionID: sessionID))
            } catch { failure += "; retirement: " + String(String(describing: error).prefix(512)) }
        }
        requests[id]?.failure = failure
        if requests[id]?.failurePresentationAttempted == true {
            await finish(id, .failure(resourceFailure(id)))
        } else {
            await finish(id, .failure(TransportFailure(phase: .dispatch, message: failure)))
        }
    }
    private func finish(_ id: UUID, _ result: Result<String?, any Error>) async {
        guard requests[id]?.result == nil else { return }
        var result = result
        if !closed {
            do {
                switch result {
                case .success(let value): try await agent.completeFixedTask(inputID: id, value: value)
                case .failure(let error):
                    try await agent.completeFixedTask(inputID: id, value: nil, failure: String(describing: error))
                }
            } catch { result = .failure(error) }
        }
        requests[id]?.result = result
        requests[id]?.waiter?.resume(with: result)
        requests[id]?.waiter = nil
    }
    private func streamEnded() async { await closeResources() }
    public func shutdown() async {
        await closeResources()
        await pump?.value
    }
    private func closeResources() async {
        if let closing {
            await closing.value
            return
        }
        closed = true
        let cleanup = Task { await self.cleanup() }
        closing = cleanup
        await cleanup.value
    }
    private func cleanup() async {
        starting?.cancel()
        _ = try? await starting?.value
        let workers = requests.values.compactMap(\.worker)
        for worker in workers { worker.cancel() }
        for worker in workers { await worker.value }
        if ownsRegistration {
            do { try await manager.remove(.applicationControl) } catch {
                for id in Array(requests.keys) { await finish(id, .failure(error)) }
            }
            ownsRegistration = false
        }
        pump?.cancel()
        for id in Array(requests.keys) { await finish(id, .failure(CommunicationError.scopeClosed)) }
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
