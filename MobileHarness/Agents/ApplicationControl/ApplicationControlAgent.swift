import AgentCore
import Foundation

/// Root-session application operations; shared transaction state with no native or callable implementation imports.
public actor ApplicationControlAgent: Agent {

    // MARK: - Interface

    public nonisolated let descriptor: AgentDescriptor
    public nonisolated let outputs: AsyncStream<OutputEnvelope>

    // MARK: - State and dependencies

    private let contextRepository: AgentContextRepository<ApplicationControlContextState>
    private let preprocessor = ApplicationControlSignalPreprocessor()
    private let contextBuilder = ApplicationControlContextBuilder()

    private let continuation: AsyncStream<OutputEnvelope>.Continuation
    private let sessionID: UUID
    private var lifecycle = AgentLifecycle.registered
    private var pending: [UUID: AgentInput] = [:]
    private var inputs: Set<UUID> = []
    private var configurationCall: UUID?
    private var providerSettingsRequest: UUID?
    private var preferenceRequest: UUID?
    private var preferenceCalls: Set<UUID> = []
    private struct PresentationStep {
        let generation: UInt64
        let failure: Bool
        var failureTerminatesRequest = true
    }
    private var presentationCalls: [UUID: PresentationStep] = [:]
    private var providerPresentationCalls: [UUID: Bool] = [:]
    private var hostFailureCalls: Set<UUID> = []
    private var terminalFailureCalls: Set<UUID> = []
    private var observationSequence: UInt64 = 0
    private var environment: [AppEnvironmentFact.Category: AppEnvironmentFact] = [:]
    private var sequence: UInt64 = 0
    private var processed = 0
    private var deviceResults = ActionResultInbox()
    private let taskCoordinator: AgentFixedTaskCoordinator<ApplicationControlContextState>
    private var taskPump: Task<Void, Never>?
    private var fixedTaskInputs: [UUID: AgentInput] = [:]
    private let admission = AgentAdmissionGate(capacity: 32)
    private var stagedOutputs: [OutputEnvelope]?

    // MARK: - Registration

    public init(
        sessionID: UUID, configuration: AgentConfiguration? = nil,
        context: AgentContextRepository<ApplicationControlContextState>? = nil
    ) throws {
        self.contextRepository =
            context
            ?? AgentContextRepository(
                agent: .applicationControl, scope: UUID(), state: ApplicationControlContextState())
        guard contextRepository.agentID == .applicationControl else { throw AgentConfigurationError.identityMismatch }
        let configuration = try configuration ?? AgentConfigurations.load(named: "ApplicationControl")
        guard configuration.agentID == .applicationControl else { throw AgentConfigurationError.identityMismatch }
        descriptor = AgentDescriptor(
            id: .applicationControl, name: "ApplicationControl",
            inputs: Set(configuration.communication.inputs.map(\.kind)),
            outputs: [.communication, .actionCall, .toolCall, .control, .scheduling],
            capabilities: try configuration.capabilities.adding(internalTools: [
                ApplicationControlFunctions.download, ApplicationControlFunctions.cancellation,
                ApplicationControlFunctions.removal, ApplicationControlFunctions.speechBinding,
                ApplicationControlFunctions.restoration, ApplicationControlFunctions.saving,
                ApplicationControlFunctions.inventory,
                ApplicationControlFunctions.presentation, ApplicationControlFunctions.failurePresentation,
                ApplicationControlFunctions.operationFailurePresentation,
                ApplicationControlFunctions.preferenceFailurePresentation,
                ApplicationControlFunctions.providerDiscovery, ApplicationControlFunctions.providerRestoration,
                ApplicationControlFunctions.providerSaving, ApplicationControlFunctions.providerPresentation,
                ApplicationControlFunctions.deviceControl, ApplicationControlFunctions.navigation,
            ]))
        taskCoordinator = AgentFixedTaskCoordinator(context: self.contextRepository)
        self.sessionID = sessionID
        let pair = AsyncStream<OutputEnvelope>.makeStream(
            bufferingPolicy: .bufferingOldest(ApplicationControlSignalPreprocessor.outputCapacity))
        outputs = pair.stream
        continuation = pair.continuation
    }

    // MARK: - Lifecycle

    public func start() async throws {
        guard lifecycle == .registered else { throw HarnessError.invalidTransition }
        _ = try await contextRepository.snapshot()
        try await taskCoordinator.start()
        lifecycle = .running
        taskPump = Task { [taskCoordinator] in
            for await envelope in taskCoordinator.outputs {
                guard !Task.isCancelled else { return }
                if !relay(envelope) {
                    await taskCoordinator.stop()
                    return
                }
            }
        }
    }
    public func pause() async throws {
        guard lifecycle == .running else { throw HarnessError.invalidTransition }
        await taskCoordinator.pause()
        lifecycle = .paused
    }
    public func resume() async throws {
        guard lifecycle == .paused else { throw HarnessError.invalidTransition }
        await taskCoordinator.resume()
        lifecycle = .running
    }
    public func stop() async {
        admission.close()
        lifecycle = .stopped
        pending.removeAll()
        environment.removeAll()
        inputs.removeAll()
        configurationCall = nil
        providerSettingsRequest = nil
        preferenceRequest = nil
        preferenceCalls.removeAll()
        presentationCalls.removeAll()
        hostFailureCalls.removeAll()
        providerPresentationCalls.removeAll()
        terminalFailureCalls.removeAll()
        fixedTaskInputs.removeAll()
        await taskCoordinator.stop()
        taskPump?.cancel()
        await taskPump?.value
        taskPump = nil
        continuation.finish()
    }

    // MARK: - Input processing

    public func receive(_ input: AgentInput) async throws {
        do { try await receiveSignal(input) } catch {
            if input.metadata.origin == .external, input.sessionID == sessionID,
                (error as? CommunicationError) != .unauthorized,
                descriptor.inputs.contains(input.payload.kind)
            {
                _ = relay(
                    OutputEnvelope(
                        source: descriptor.id, input: input,
                        output: .control("agent.error: input rejected: \(error)")))
            }
            throw error
        }
    }

    private func receiveSignal(_ input: AgentInput) async throws {
        if await taskCoordinator.ownsFeedback(input) {
            try await taskCoordinator.receive(input)
            return
        }
        var input = input
        if case .observation(let message) = input.payload, let signal = message.content(as: AgentTaskSignal.self) {
            if signal.kind == .cancel,
                let original = fixedTaskInputs.values.first(where: { $0.taskScope?.id == signal.scope.id })
            {
                try await taskCoordinator.admitFixedTask(signal, input: input)
                let calls = Set(pending.filter { $0.value.taskScope?.id == signal.scope.id }.keys)
                try await contextRepository.update { $0.state.pendingCallIDs.removeAll { calls.contains($0) } }
                for call in calls {
                    pending[call] = nil
                    presentationCalls[call] = nil
                    providerPresentationCalls[call] = nil
                    preferenceCalls.remove(call)
                    hostFailureCalls.remove(call)
                    terminalFailureCalls.remove(call)
                    if configurationCall == call { configurationCall = nil }
                }
                inputs.remove(original.id)
                if providerSettingsRequest == original.id { providerSettingsRequest = nil }
                if preferenceRequest == original.id { preferenceRequest = nil }
                fixedTaskInputs[original.id] = nil
                guard
                    relay(
                        OutputEnvelope(
                            source: descriptor.id, input: original, output: .control("agent.error: task cancelled")))
                else { throw CommunicationError.capacityExceeded }
                try await taskCoordinator.reportFixedTask(
                    signal.scope, input: original,
                    result: ToolResult(callID: original.id, value: "Task cancelled", isError: true), status: .cancelled)
                return
            }
            if signal.kind == .cancel || signal.businessContract == "runtime.taskTermination"
                || signal.businessContract == AgentTaskContent.contract
            {
                try await taskCoordinator.receive(input)
                return
            }
            let fixed = try AgentFixedTaskInput.unwrap(signal, input: input, executor: descriptor.id)
            guard fixedTaskInputs.count < 32 else { throw CommunicationError.capacityExceeded }
            try await taskCoordinator.admitFixedTask(signal, input: input)
            fixedTaskInputs[fixed.id] = fixed
            input = fixed
        }

        try await admission.acquire()
        defer { admission.release() }
        try Task.checkCancellation()
        let selection = AgentDecisionContext(snapshot: try await contextRepository.snapshot(), input: input)
        let decision = try contextBuilder.build(state: selection, batch: selection.batch())
        stagedOutputs = []
        do { try receiveDecision(decision.input) } catch {
            stagedOutputs = nil
            throw error
        }
        let outputs = stagedOutputs ?? []
        stagedOutputs = nil
        do { try await prepareSignal(input) } catch {
            await stop()
            lifecycle = .failed
            throw error
        }
        guard lifecycle == .running || (lifecycle == .paused && acceptsPassive(input)) else {
            throw HarnessError.notRunning
        }
        for envelope in outputs {
            guard case .enqueued = continuation.yield(envelope) else {
                await stop()
                lifecycle = .failed
                throw CommunicationError.capacityExceeded
            }
        }
    }
    private func acceptsPassive(_ input: AgentInput) -> Bool {
        switch input.payload {
        case .actionResult, .toolResult, .roundResult, .communicationReceipt: return true
        case .observation(let message): return message.contract == AppEnvironmentFact.contract
        default: return false
        }
    }
    private func receiveDecision(_ input: AgentInput) throws {
        guard lifecycle == .running || (lifecycle == .paused && acceptsPassive(input)) else {
            throw HarnessError.notRunning
        }
        guard input.sessionID == sessionID || input.taskScope?.executor == .applicationControl else {
            throw CommunicationError.unauthorized
        }
        guard !input.metadata.expired else { throw CommunicationError.invalidPayload }
        switch input.payload {
        case .actionResult(let result):
            guard input.metadata.origin == .runtime, input.metadata.source == "runtime",
                result.owner.agent == descriptor.id, result.owner.sessionID == sessionID
            else { throw CommunicationError.unauthorized }
            deviceResults.accept(result)
            processed += 1
            return
        case .observation(let message):
            if let fact = message.appEnvironment {
                guard input.metadata.origin == .external, input.metadata.incarnation == nil,
                    input.metadata.source == AppEnvironmentFact.source,
                    input.metadata.contract == AppEnvironmentFact.contract,
                    input.metadata.version == 1, input.metadata.sequence == fact.sequence
                else { throw CommunicationError.invalidPayload }
                try fact.validate()
                _ = try message.validatedSize()
                guard fact.sequence > (environment[fact.category]?.sequence ?? 0) else {
                    throw CommunicationError.outOfOrder
                }
                environment[fact.category] = fact
                processed += 1
                return
            }
            if let interaction = message.appInteraction {
                guard
                    (input.metadata.origin == .external && input.metadata.incarnation == nil
                        && input.metadata.source == "user") || AgentFixedTaskInput.isTrusted(input),
                    input.metadata.contract == AppInteractionIntent.contract,
                    input.metadata.version == 1
                else { throw CommunicationError.invalidPayload }
                try interaction.validate()
                _ = try message.validatedSize()
                guard pending.count < ApplicationControlSignalPreprocessor.inputCapacity, !inputs.contains(input.id)
                else { throw CommunicationError.capacityExceeded }
                let call = try
                    (interaction.kind == .device
                    ? ApplicationControlFunctions.deviceControl : ApplicationControlFunctions.navigation).call(
                        interaction.parameters)
                pending[call.id] = input
                inputs.insert(input.id)
                try emit(.toolCall(call), for: input)
                processed += 1
                return
            }
            if let settings = message.providerSettings {
                guard
                    (input.metadata.origin == .external && input.metadata.incarnation == nil
                        && input.metadata.source == "user") || AgentFixedTaskInput.isTrusted(input),
                    input.metadata.contract == ProviderSettingsIntent.contract,
                    input.metadata.version == 1, message.contract == ProviderSettingsIntent.contract
                else { throw CommunicationError.invalidPayload }
                _ = try message.validatedSize()
                guard pending.count < ApplicationControlSignalPreprocessor.inputCapacity, !inputs.contains(input.id),
                    providerSettingsRequest == nil,
                    preferenceRequest == nil, configurationCall == nil
                else { throw CommunicationError.capacityExceeded }
                let tool =
                    settings.operation == .restore
                    ? ApplicationControlFunctions.providerRestoration : ApplicationControlFunctions.providerSaving
                let call = try tool.call(["requestID": settings.requestID.uuidString])
                providerSettingsRequest = input.id
                pending[call.id] = input
                inputs.insert(input.id)
                try emit(.toolCall(call), for: input)
                processed += 1
                return
            }
            if let discovery = message.providerDiscovery {
                guard
                    (input.metadata.origin == .external && input.metadata.incarnation == nil
                        && input.metadata.source == "user") || AgentFixedTaskInput.isTrusted(input),
                    input.metadata.contract == ProviderDiscoveryIntent.contract,
                    input.metadata.version == 1, message.contract == ProviderDiscoveryIntent.contract
                else { throw CommunicationError.invalidPayload }
                _ = try message.validatedSize()
                guard pending.count < ApplicationControlSignalPreprocessor.inputCapacity, !inputs.contains(input.id)
                else { throw CommunicationError.capacityExceeded }
                let call = try ApplicationControlFunctions.providerDiscovery.call([
                    "requestID": discovery.requestID.uuidString
                ])
                pending[call.id] = input
                inputs.insert(input.id)
                try emit(.toolCall(call), for: input)
                processed += 1
                return
            }
            if let failure = message.resourceHostFailure {
                try admitHostFailure(failure, message: message, input: input)
                processed += 1
                return
            }
            if let observation = message.resourceObservation {
                try admitObservation(observation, message: message, input: input)
                processed += 1
                return
            }
            guard
                (input.metadata.origin == .external && input.metadata.incarnation == nil)
                    || AgentFixedTaskInput.isTrusted(input),
                input.metadata.contract == ModelResourceIntent.contract,
                input.metadata.version == 1, message.contract == ModelResourceIntent.contract,
                let intent = message.resourceIntent
            else { throw CommunicationError.invalidPayload }
            _ = try message.validatedSize()
            if case .retire(let requestID) = intent {
                guard input.metadata.source == "runtime", requestID == input.id else {
                    throw CommunicationError.invalidPayload
                }
                if let configurationCall, pending[configurationCall]?.id == requestID { self.configurationCall = nil }
                if providerSettingsRequest == requestID { providerSettingsRequest = nil }
                if preferenceRequest == requestID { preferenceRequest = nil }
                preferenceCalls.subtract(pending.filter { $0.value.id == requestID }.keys)
                for id in pending.filter({ $0.value.id == requestID }).keys {
                    presentationCalls[id] = nil
                    hostFailureCalls.remove(id)
                    providerPresentationCalls[id] = nil
                    terminalFailureCalls.remove(id)
                }
                pending = pending.filter { $0.value.id != requestID }
                inputs.remove(requestID)
                processed += 1
                return
            }
            guard input.metadata.source == "user" || AgentFixedTaskInput.isTrusted(input) else {
                throw CommunicationError.invalidPayload
            }
            try intent.validate()
            _ = try message.validatedSize()
            guard pending.count < ApplicationControlSignalPreprocessor.inputCapacity, !inputs.contains(input.id) else {
                throw CommunicationError.capacityExceeded
            }
            let call: ToolCall
            switch intent {
            case .refreshResources: call = try ApplicationControlFunctions.inventory.call([:])
            case .refreshPresentation(let generation):
                call = try ApplicationControlFunctions.presentation.call(["generation": String(generation)])
                presentationCalls[call.id] = PresentationStep(generation: generation, failure: false)
            case .restoreSource, .saveSource:
                guard configurationCall == nil, preferenceRequest == nil, providerSettingsRequest == nil else {
                    throw CommunicationError.capacityExceeded
                }
                switch intent {
                case .restoreSource: call = try ApplicationControlFunctions.restoration.call([:])
                case .saveSource(let endpoint, let cellular, let recognition, let synthesis):
                    call = try ApplicationControlFunctions.saving.call([
                        "endpoint": endpoint, "allowsCellular": cellular ? "true" : "false",
                        "recognition": recognition ? "true" : "false", "synthesis": synthesis ? "true" : "false",
                    ])
                default: throw CommunicationError.invalidPayload
                }
                preferenceRequest = input.id
                preferenceCalls.insert(call.id)
            case .configureSpeech(let recognition, let synthesis):
                guard configurationCall == nil, preferenceRequest == nil, providerSettingsRequest == nil else {
                    throw CommunicationError.capacityExceeded
                }
                call = try ApplicationControlFunctions.speechBinding.call([
                    "recognition": recognition ? "true" : "false", "synthesis": synthesis ? "true" : "false",
                ])
                configurationCall = call.id
            case .retire: throw CommunicationError.invalidPayload
            case .download(let id, let endpoint, let cellular):
                call = try ApplicationControlFunctions.download.call([
                    "id": id, "endpoint": endpoint, "allowsCellular": cellular ? "true" : "false",
                ])
            case .cancel(let id): call = try ApplicationControlFunctions.cancellation.call(["id": id])
            case .remove(let id): call = try ApplicationControlFunctions.removal.call(["id": id])
            }
            pending[call.id] = input
            inputs.insert(input.id)
            try emit(.toolCall(call), for: input)
        case .toolResult(let result):
            guard input.metadata.origin == .runtime, input.metadata.source == "runtime",
                let original = pending.removeValue(forKey: result.callID)
            else { throw CommunicationError.invalidPayload }
            if let failed = providerPresentationCalls.removeValue(forKey: result.callID) {
                if providerSettingsRequest == original.id { providerSettingsRequest = nil }
                inputs.remove(original.id)
                try emit(
                    .control(failed || result.isError ? "application.control.failed" : "application.control.finished"),
                    for: original)
                processed += 1
                return
            }
            if case .observation(let message) = original.payload {
                let settings = message.providerSettings
                let discovery = message.providerDiscovery
                if settings?.presentation == true || discovery?.presentation == true,
                    let requestID = settings?.requestID ?? discovery?.requestID
                {
                    var arguments = ["requestID": requestID.uuidString]
                    if result.isError { arguments["failureCode"] = result.failureCode ?? "provider.unavailable" }
                    let call = try ApplicationControlFunctions.providerPresentation.call(arguments)
                    pending[call.id] = original
                    providerPresentationCalls[call.id] = result.isError
                    try emit(.toolCall(call), for: original)
                    processed += 1
                    return
                }
            }
            if hostFailureCalls.remove(result.callID) != nil {
                inputs.remove(original.id)
                try emit(
                    .control(result.isError ? "application.control.failed" : "application.control.finished"),
                    for: original)
                processed += 1
                return
            }
            if terminalFailureCalls.remove(result.callID) != nil {
                if providerSettingsRequest == original.id { providerSettingsRequest = nil }
                if preferenceRequest == original.id { preferenceRequest = nil }
                if configurationCall == result.callID { configurationCall = nil }
                inputs.remove(original.id)
                try emit(.control("application.control.failed"), for: original)
                processed += 1
                return
            }
            let preferenceFunction = preferenceCalls.remove(result.callID) != nil
            if result.isError, preferenceFunction || configurationCall == result.callID {
                let call = try ApplicationControlFunctions.preferenceFailurePresentation.call([
                    "reason": preferenceFunction
                        ? ApplicationControlResourcePolicy.preferenceFailureReason(result.failureCode) : "execution",
                    "message": ApplicationControlResourcePolicy.failureMessage(result.value),
                ])
                pending[call.id] = original
                terminalFailureCalls.insert(call.id)
                if configurationCall == result.callID { configurationCall = call.id }
                try emit(.toolCall(call), for: original)
                processed += 1
                return
            }
            if result.isError, case .observation(let message) = original.payload, let intent = message.resourceIntent,
                ApplicationControlResourcePolicy.isResourceCommand(intent)
            {
                let call = try ApplicationControlFunctions.operationFailurePresentation.call([
                    "message": ApplicationControlResourcePolicy.failureMessage(result.value)
                ])
                pending[call.id] = original
                terminalFailureCalls.insert(call.id)
                try emit(.toolCall(call), for: original)
                processed += 1
                return
            }
            if let step = presentationCalls.removeValue(forKey: result.callID) {
                if !step.failure, result.isError {
                    let call = try ApplicationControlFunctions.failurePresentation.call([
                        "generation": String(step.generation),
                        "message": ApplicationControlResourcePolicy.failureMessage(result.value),
                    ])
                    pending[call.id] = original
                    presentationCalls[call.id] = PresentationStep(generation: step.generation, failure: true)
                    try emit(.toolCall(call), for: original)
                } else {
                    inputs.remove(original.id)
                    try emit(
                        .control(
                            result.isError || (step.failure && step.failureTerminatesRequest)
                                ? "application.control.failed" : "application.control.finished"), for: original)
                }
                processed += 1
                return
            }
            if preferenceFunction, !result.isError {
                let value = try ApplicationControlResourcePolicy.preferenceValue(result.value)
                let call = try ApplicationControlFunctions.speechBinding.call([
                    "recognition": value.useCustomRecognition ? "true" : "false",
                    "synthesis": value.useCustomSynthesis ? "true" : "false",
                ])
                configurationCall = call.id
                pending[call.id] = original
                try emit(.toolCall(call), for: original)
                processed += 1
                return
            }
            if providerSettingsRequest == original.id { providerSettingsRequest = nil }
            if preferenceRequest == original.id { preferenceRequest = nil }
            if configurationCall == result.callID { configurationCall = nil }
            inputs.remove(original.id)
            try emit(
                .control(result.isError ? "application.control.failed" : "application.control.finished"), for: original)
        default: throw CommunicationError.invalidPayload
        }
        processed += 1
    }
    private func admitHostFailure(_ failure: ModelResourceHostFailure, message: AgentMessage, input: AgentInput)
        throws
    {
        guard input.metadata.origin == .external, input.metadata.incarnation == nil,
            input.metadata.source == ModelResourceHostFailure.source,
            input.metadata.contract == ModelResourceHostFailure.contract, input.metadata.version == 1,
            message.contract == ModelResourceHostFailure.contract,
            input.metadata.rootID == input.id, input.metadata.parentID == failure.requestID,
            input.id != failure.requestID, input.metadata.hops == 1
        else { throw CommunicationError.unauthorized }
        try failure.validate()
        _ = try message.validatedSize()
        guard pending.count < ApplicationControlSignalPreprocessor.inputCapacity, !inputs.contains(input.id) else {
            throw CommunicationError.capacityExceeded
        }
        let call: ToolCall
        switch failure.scope {
        case .operation:
            call = try ApplicationControlFunctions.operationFailurePresentation.call(["message": failure.message])
        case .preference:
            call = try ApplicationControlFunctions.preferenceFailurePresentation.call([
                "reason": "execution", "message": failure.message,
            ])
        case .refresh(let generation):
            call = try ApplicationControlFunctions.failurePresentation.call([
                "generation": String(generation), "message": failure.message,
            ])
        }
        pending[call.id] = input
        hostFailureCalls.insert(call.id)
        inputs.insert(input.id)
        try emit(.toolCall(call), for: input)
    }
    private func admitObservation(_ observation: ModelResourceObservation, message: AgentMessage, input: AgentInput)
        throws
    {
        guard input.metadata.origin == .external, input.metadata.incarnation == nil,
            input.metadata.source == ModelResourceObservation.source,
            input.metadata.contract == ModelResourceObservation.contract, input.metadata.version == 1,
            message.contract == ModelResourceObservation.contract,
            input.metadata.sequence > observationSequence
        else { throw CommunicationError.invalidPayload }
        try observation.validate()
        _ = try message.validatedSize()
        guard pending.count < ApplicationControlSignalPreprocessor.inputCapacity, !inputs.contains(input.id) else {
            throw CommunicationError.capacityExceeded
        }
        let call: ToolCall
        let step: PresentationStep
        switch observation {
        case .changed(let generation):
            call = try ApplicationControlFunctions.presentation.call(["generation": String(generation)])
            step = PresentationStep(generation: generation, failure: false)
        case .failed(let generation, let message):
            call = try ApplicationControlFunctions.failurePresentation.call([
                "generation": String(generation), "message": message,
            ])
            step = PresentationStep(generation: generation, failure: true, failureTerminatesRequest: false)
        }
        pending[call.id] = input
        presentationCalls[call.id] = step
        inputs.insert(input.id)
        try emit(.toolCall(call), for: input)
        observationSequence = input.metadata.sequence
    }

    // MARK: - Output

    private func emit(_ output: AgentOutput, for input: AgentInput) throws {
        sequence += 1
        guard stagedOutputs != nil, (stagedOutputs?.count ?? 0) < 64 else { throw CommunicationError.capacityExceeded }
        stagedOutputs?.append(OutputEnvelope(source: descriptor.id, input: input, output: output, sequence: sequence))
    }

    private func relay(_ envelope: OutputEnvelope) -> Bool {
        sequence += 1
        let input = AgentInput(
            id: envelope.inputID, sessionID: envelope.sessionID, payload: .event("relay"),
            metadata: envelope.inputMetadata,
            turn: envelope.turn, taskScope: envelope.taskScope)
        let result = continuation.yield(
            OutputEnvelope(
                source: descriptor.id, input: input,
                output: envelope.output, sequence: sequence, roundID: envelope.roundID, callID: envelope.callID))
        if case .enqueued = result { return true }
        lifecycle = .failed
        continuation.finish()
        return false
    }

    // MARK: - Context

    private func prepareSignal(_ input: AgentInput) async throws {
        let snapshot = try await contextRepository.snapshot()
        let disposition = try preprocessor.classify(input, state: snapshot.state)
        if input.payload.kind == .audio || input.payload.kind == .image { return }
        if case .replaceLatest = disposition { return }
        let callIDs = Array(pending.keys)
        let categories = environment.keys.map(\.rawValue).sorted()
        try await contextRepository.recordSignal(
            input, disposition: disposition, admissionSequence: snapshot.revision + 1,
            consumed: disposition != .feedback, retainingLast: ApplicationControlSignalPreprocessor.evidenceCapacity
        ) { context in
            context.state.pendingCallIDs = callIDs
            context.state.environmentContracts = categories
        }
    }

    public func completeFixedTask(inputID: UUID, value: String?, failure: String? = nil) async throws {
        guard let original = fixedTaskInputs.removeValue(forKey: inputID), let scope = original.taskScope else {
            return
        }
        try await taskCoordinator.reportFixedTask(
            scope, input: original,
            result: ToolResult(callID: inputID, value: failure ?? value ?? "Completed", isError: failure != nil))
    }

    // MARK: - Observability

    public func environmentSnapshot() throws -> String {
        guard lifecycle == .running || lifecycle == .paused else { throw HarnessError.notRunning }
        let facts = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(environment.values.sorted { $0.category.rawValue < $1.category.rawValue }))
        var snapshot: [String: Any] = ["facts": facts]
        if let result = deviceResults.results.last {
            var value: [String: Any] = [
                "executionID": result.executionID.uuidString, "inputID": result.inputID.uuidString,
                "status": result.status.rawValue, "effect": result.effect.rawValue, "path": result.path.description,
            ]
            if let report = result.report {
                value["failureDescription"] = report.failureDescription
                value["executionFailure"] = report.executionFailure?.rawValue
                value["entries"] = report.entries.map { entry -> [String: Any] in
                    var value: [String: Any] = [
                        "path": entry.path, "status": entry.status.rawValue, "details": entry.details,
                    ]
                    if let code = entry.code { value["code"] = code.rawValue }
                    return value
                }
            }
            snapshot["lastDeviceResult"] = value
        }
        let data = try JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys])
        guard data.count <= 65_536 else { throw CommunicationError.invalidPayload }
        return String(decoding: data, as: UTF8.self)
    }

    public func manualResults() -> [ActionResult] { deviceResults.results }

    public func status() -> AgentStatus {
        AgentStatus(lifecycle: lifecycle, queuedInputs: pending.count, processedInputs: processed)
    }

    public func contextSnapshot() async throws -> AgentContext<ApplicationControlContextState> {
        try await contextRepository.snapshot()
    }
}
