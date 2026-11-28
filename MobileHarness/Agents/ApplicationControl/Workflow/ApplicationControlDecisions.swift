import AgentCore
import Foundation
import FunctionContracts
import Gateway
import ModelKit
import PlatformKit
import StorageCore
import UI

extension ApplicationControlAgent {
    func receiveSignal(_ input: AgentInput) async throws {
        if case .observation(let message) = input.payload,
            diagnosticContracts.contains(message.contract)
        {
            try await receiveFailure(input, message: message)
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
                            source: descriptor.id, context: original.context,
                            output: .control("agent.error: task cancelled"), taskScope: original.taskScope))
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
            let fixed = try AgentFixedTaskInput.unwrap(
                signal, input: input, executor: descriptor.id, decode: ApplicationControlTaskInput.message)
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
            if try uiExecution.capture(envelope) { continue }
            guard case .enqueued = continuation.yield(envelope) else {
                await stop()
                lifecycle = .failed
                throw CommunicationError.capacityExceeded
            }
        }
    }
    /// Failure presentation must work even when the context store or model has failed.
    private func receiveFailure(_ input: AgentInput, message: AgentMessage) async throws {
        guard lifecycle == .running || lifecycle == .paused else { throw HarnessError.notRunning }
        guard input.sessionID == sessionID, input.metadata.origin == .local,
            input.metadata.incarnation == nil, input.taskScope == nil, input.metadata.source == "runtime",
            input.metadata.contract == message.contract, input.metadata.version == 1,
            diagnosticContracts.contains(message.contract)
        else { throw CommunicationError.unauthorized }
        guard !input.metadata.expired else { throw CommunicationError.expired }
        try input.validate(message)
        let issue: ExecutionIssue
        let count: UInt64
        if message.contract == ContainerFailureEvent.contract {
            guard let event = message.content(as: ContainerFailureEvent.self) else {
                throw CommunicationError.invalidPayload
            }
            try event.validate()
            if ApplicationControlBluetoothState.isConnectionCondition(event) {
                let state = bluetoothState ?? .disconnected
                bluetoothState = state
                try presentBluetooth(state, input: input)
                processed += 1
                return
            }
            count = event.occurrences
            issue = .init(
                id: "container:" + event.scopeID + ":" + event.id, title: event.module + "." + event.component,
                source: event.module, message: event.operation + ": " + event.message, time: event.lastOccurred,
                failureCode: "container.failure", context: .init(workerID: event.component, sessionID: event.scopeID),
                userMessage: "A required capability is unavailable. Check Runtime Issues.", category: "Container issue")
        } else {
            guard let event = message.content(as: RuntimeFailureEvent.self) else {
                throw CommunicationError.invalidPayload
            }
            try event.validate()
            count = 1
            issue = .init(
                id: "runtime:" + event.id, title: event.title, source: event.sourceAgent, message: event.message,
                time: event.time, failureCode: event.failureCode,
                context: .init(
                    workerID: event.workerID ?? event.sourceAgent, sessionID: event.sessionID, inputID: event.inputID,
                    callID: event.callID, roundID: event.roundID),
                userMessage: ApplicationControlFailurePolicy.userMessage(
                    source: event.sourceAgent, message: event.message, code: event.failureCode)
                    ?? event.message.replacingOccurrences(of: "agent.error: ", with: ""),
                category: event.category.flatMap(AgentFailureDiagnostic.Category.init(rawValue:))
                    .map(ApplicationControlFailurePolicy.categoryTitle))
        }
        let previous = diagnosticCounts[issue.id]
        if let previous, count <= previous { return }
        let age = Date().timeIntervalSince(issue.time)
        let showsToast = previous == nil && issue.context?.callID == nil && (-5...15).contains(age)
        if previous == nil {
            if diagnosticOrder.count == 128 {
                diagnosticCounts.removeValue(forKey: diagnosticOrder.removeFirst())
            }
            diagnosticOrder.append(issue.id)
        }
        diagnosticCounts[issue.id] = count
        processed += 1
        await publishIssue(issue, showsToast)
    }

    private func presentLoading(_ fact: AppEnvironmentFact, input: AgentInput) throws {
        let enabled = fact.value == "loading"
        guard statePresentationCalls.count < 128 else { throw CommunicationError.capacityExceeded }
        let call = try ApplicationControlFunctions.loadingExpression.call([
            "enabled": enabled ? "true" : "false", "revision": String(fact.sequence),
        ])
        sequence &+= 1
        guard
            case .enqueued = continuation.yield(
                OutputEnvelope(
                    source: descriptor.id, context: input.context, output: .toolCall(call), sequence: sequence,
                    taskScope: input.taskScope))
        else { throw CommunicationError.capacityExceeded }
        statePresentationCalls.insert(call.id)
    }

    func presentBluetooth(_ state: ApplicationControlBluetoothState, input: AgentInput) throws {
        guard state != bluetoothPresented else { return }
        guard statePresentationCalls.count <= 126, bluetoothRevision < UInt64.max else {
            throw CommunicationError.capacityExceeded
        }
        bluetoothRevision += 1
        let parameters = ["phase": state.rawValue, "revision": String(bluetoothRevision)]
        let calls = try [ApplicationControlFunctions.bluetoothHome, ApplicationControlFunctions.bluetoothSettings].map {
            try $0.call(parameters)
        }
        for call in calls {
            sequence &+= 1
            guard
                case .enqueued = continuation.yield(
                    OutputEnvelope(
                        source: descriptor.id, context: input.context, output: .toolCall(call), sequence: sequence,
                        taskScope: input.taskScope))
            else { throw CommunicationError.capacityExceeded }
            statePresentationCalls.insert(call.id)
        }
        bluetoothPresented = state
    }

    private func acceptsPassive(_ input: AgentInput) -> Bool {
        switch input.payload {
        case .toolResult: return true
        case .observation(let message):
            if case .retire? = message.resourceIntent {
                return input.metadata.origin == .local && input.metadata.source == "runtime"
            }
            return message.contract == AppEnvironmentFact.contract
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
        case .observation(let message):
            if let fact = message.appEnvironment {
                guard input.metadata.origin == .local, input.metadata.incarnation == nil,
                    input.metadata.source == AppEnvironmentFact.source,
                    input.metadata.contract == AppEnvironmentFact.contract,
                    input.metadata.version == 1, input.metadata.sequence == fact.sequence
                else { throw CommunicationError.invalidPayload }
                try fact.validate()
                try input.validate(message)
                if fact.category == .scene, !["active", "background"].contains(fact.value) {
                    throw CommunicationError.invalidPayload
                }
                if fact.category == .modelPreparation {
                    guard fact.value == "loading" || fact.value == "idle" else {
                        throw CommunicationError.invalidPayload
                    }
                }
                let bluetooth =
                    fact.category == .devices ? try ApplicationControlBluetoothState.environment(fact.value) : nil
                if let current = environment[fact.category], fact.sequence <= current.sequence {
                    // Environment facts are complete snapshots; Gateway publication is not FIFO.
                    guard fact.sequence < current.sequence || fact == current else {
                        throw CommunicationError.invalidPayload
                    }
                    processed += 1
                    return
                }
                if fact.category == .modelPreparation { try presentLoading(fact, input: input) }
                if let bluetooth {
                    bluetoothState = bluetooth
                    try presentBluetooth(bluetooth, input: input)
                }
                environment[fact.category] = fact
                processed += 1
                return
            }
            if let interaction = message.appInteraction {
                guard
                    (input.metadata.origin == .local && input.metadata.incarnation == nil
                        && input.metadata.source == "user") || AgentFixedTaskInput.isTrusted(input),
                    input.metadata.contract == AppInteractionIntent.contract,
                    input.metadata.version == 1
                else { throw CommunicationError.invalidPayload }
                try interaction.validate()
                try input.validate(message)
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
                    (input.metadata.origin == .local && input.metadata.incarnation == nil
                        && input.metadata.source == "user") || AgentFixedTaskInput.isTrusted(input),
                    input.metadata.contract == ProviderSettingsIntent.contract,
                    input.metadata.version == 1, message.contract == ProviderSettingsIntent.contract
                else { throw CommunicationError.invalidPayload }
                try input.validate(message)
                guard pending.count < ApplicationControlSignalPreprocessor.inputCapacity, !inputs.contains(input.id),
                    providerSettingsRequest == nil,
                    preferenceRequest == nil, configurationCall == nil
                else { throw CommunicationError.capacityExceeded }
                let tool =
                    settings.operation == .restore
                    ? ApplicationControlFunctions.providerRestoration : ApplicationControlFunctions.providerSaving
                let call = try tool.call(["requestID": settings.requestID])
                providerSettingsRequest = input.id
                pending[call.id] = input
                inputs.insert(input.id)
                try emit(.toolCall(call), for: input)
                processed += 1
                return
            }
            if let discovery = message.providerDiscovery {
                guard
                    (input.metadata.origin == .local && input.metadata.incarnation == nil
                        && input.metadata.source == "user") || AgentFixedTaskInput.isTrusted(input),
                    input.metadata.contract == ProviderDiscoveryIntent.contract,
                    input.metadata.version == 1, message.contract == ProviderDiscoveryIntent.contract
                else { throw CommunicationError.invalidPayload }
                try input.validate(message)
                guard pending.count < ApplicationControlSignalPreprocessor.inputCapacity, !inputs.contains(input.id)
                else { throw CommunicationError.capacityExceeded }
                let call = try ApplicationControlFunctions.providerDiscovery.call([
                    "requestID": discovery.requestID
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
                (input.metadata.origin == .local && input.metadata.incarnation == nil)
                    || AgentFixedTaskInput.isTrusted(input),
                input.metadata.contract == ModelResourceIntent.contract,
                input.metadata.version == 1, message.contract == ModelResourceIntent.contract,
                let intent = message.resourceIntent
            else { throw CommunicationError.invalidPayload }
            try input.validate(message)
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
            try input.validate(message)
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
                case .saveSource(
                    let endpoint, let cellular, let recognition, let synthesis, let decision, let windows,
                    let threshold, let enhancement, let keywordInterrupt, let models, let voice, let keywordThreshold
                ):
                    var arguments = [
                        "endpoint": endpoint, "allowsCellular": cellular ? "true" : "false",
                        "recognition": recognition ? "true" : "false", "synthesis": synthesis ? "true" : "false",
                        "decision": decision ? "true" : "false",
                        "vadOnsetWindows": String(windows), "vadThreshold": String(threshold),
                        "enhancement": enhancement ? "true" : "false",
                        "keywordInterrupt": keywordInterrupt ? "true" : "false",
                    ]
                    if let models { arguments["speechModels"] = try Self.encodeSpeechModels(models) }
                    arguments["synthesisVoice"] = voice
                    if let keywordThreshold { arguments["keywordThreshold"] = String(keywordThreshold) }
                    call = try ApplicationControlFunctions.saving.call(arguments)
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
                    var arguments = ["requestID": requestID]
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
                var arguments = [
                    "recognition": value.useCustomRecognition ? "true" : "false",
                    "synthesis": value.useCustomSynthesis ? "true" : "false",
                ]
                if let models = value.speechModels { arguments["speechModels"] = try Self.encodeSpeechModels(models) }
                arguments["synthesisVoice"] = value.synthesisVoice
                let call = try ApplicationControlFunctions.speechBinding.call(arguments)
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
    private static func encodeSpeechModels(_ models: [String: String]) throws -> String {
        String(decoding: try JSONEncoder().encode(models), as: UTF8.self)
    }

    private func admitHostFailure(_ failure: ModelResourceHostFailure, message: AgentMessage, input: AgentInput)
        throws
    {
        guard input.metadata.origin == .local, input.metadata.incarnation == nil,
            input.metadata.source == ModelResourceHostFailure.source,
            input.metadata.contract == ModelResourceHostFailure.contract, input.metadata.version == 1,
            message.contract == ModelResourceHostFailure.contract,
            input.metadata.rootID == input.id, input.metadata.parentID == failure.requestID,
            input.id != failure.requestID, input.metadata.hops == 1
        else { throw CommunicationError.unauthorized }
        try failure.validate()
        try input.validate(message)
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
        guard input.metadata.origin == .local, input.metadata.incarnation == nil,
            input.metadata.source == ModelResourceObservation.source,
            input.metadata.contract == ModelResourceObservation.contract, input.metadata.version == 1,
            message.contract == ModelResourceObservation.contract,
            input.metadata.sequence > observationSequence
        else { throw CommunicationError.invalidPayload }
        try observation.validate()
        try input.validate(message)
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
}
