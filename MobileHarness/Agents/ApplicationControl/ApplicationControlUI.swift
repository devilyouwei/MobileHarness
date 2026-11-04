import AgentCore
import Foundation
import FunctionContracts
import Gateway
import UI

extension ApplicationControlAgent {
    public func bindUIExecution(_ consumer: GatewayOutputConsumer) { uiExecution.consumer = consumer }
    func startUIInputs() async throws {
        do {
            if let uiWindows {
                let source = await uiWindows.requests
                uiInputs.append(
                    try await consumeUI(source, sessionID: sessionID, maximumConcurrent: 4) { agent, value, context in
                        try await agent.handleWindow(value, context: context)
                    })
            }
            if let connectionFacts {
                let stream = try await connectionFacts()
                let task = Task { [self] in
                    do {
                        for try await fact in stream {
                            try Task.checkCancellation()
                            try observeConnection(fact)
                        }
                    } catch { if !Task.isCancelled { observationFailure(error) } }
                }
                uiInputs.append(AgentUISubscription(task: task, close: {}))
            }
            await setResourceObservationForeground(true)
            if let uiDiagnostics {
                let source = await uiDiagnostics.detectionRequests
                uiInputs.append(
                    try await consumeUI(source, sessionID: sessionID) { agent, value, context in
                        switch value {
                        case .start: try await agent.startDetection(context: context)
                        case .stop: await agent.stopDetection()
                        }
                    })
            }
            if let uiSettings {
                let source = await uiSettings.requests
                let task = try await consumeUI(source, sessionID: sessionID) { agent, value, context in
                    try await agent.handleSettings(value, context: context)
                }
                uiInputs.append(task)
            }
            if let uiResources {
                let source = await uiResources.requests
                let task = try await consumeUI(source, sessionID: sessionID) { agent, value, context in
                    try await agent.handleResources(value, context: context)
                }
                uiInputs.append(task)
            }
            if let uiDevices {
                let source = await uiDevices.requests
                let task = try await consumeUI(source, sessionID: sessionID) { agent, value, context in
                    _ = try await agent.executeUI(
                        AppInteractionIntent(kind: .device, parameters: value.parameters).input(
                            sessionID: context.sessionID),
                        context: context)
                }
                uiInputs.append(task)
            }
        } catch {
            await stopUIInputs()
            throw error
        }
    }
    private func handleWindow(_ value: WindowInput, context: ProcessingContext) async throws {
        guard status().lifecycle == .running, context.sessionID == sessionID else {
            throw CommunicationError.scopeClosed
        }
        let consumer = try uiExecution.begin(context.requestID)
        defer { uiExecution.finish(context.requestID) }
        guard
            let permission = ApplicationControlFunctions.windows.first(where: {
                $0.path == "UI.Window." + value.command.rawValue
            })
        else { throw CommunicationError.invalidPayload }
        guard windowCalls.count < 5 else { throw CommunicationError.capacityExceeded }
        let call = try permission.call(["windowID": value.id.uuidString])
        windowCalls.insert(call.id)
        defer { windowCalls.remove(call.id) }
        let result = try await consumer.executeReturning(
            OutputEnvelope(source: descriptor.id, context: context, output: .toolCall(call)))
        try Task.checkCancellation()
        if result.isCancellationOnly { throw CancellationError() }
        if result.isError {
            throw ApplicationControlIntentFailure.execution(result.failure ?? result.tool?.value ?? "Window failed")
        }
    }
    func stopUIInputs() async {
        await stopDetection()
        await resourceObservation?.shutdown()
        resourceObservation = nil
        await uiInputs.retire(for: descriptor.id)()
    }
    public func setResourceObservationForeground(_ active: Bool) async {
        guard let resourceChanges, lifecycleIsActive else { return }
        if resourceObservation == nil {
            resourceObservation = await ResourceObservationSession(
                source: resourceChanges,
                changed: { [weak self] in try await self?.resourceDidChange() },
                failed: observationFailure)
        }
        await resourceObservation?.setForeground(active)
    }
    private func resourceDidChange() async throws {
        guard let uiResources else { return }
        let generation = await uiResources.presentation.beginRefresh()
        guard observationSequence < UInt64.max else { throw CommunicationError.capacityExceeded }
        let sequence = observationSequence + 1
        _ = try await executeUI(
            ModelResourceObservation.changed(generation: generation).input(sessionID: sessionID, sequence: sequence),
            context: ProcessingContext(
                sessionID: sessionID,
                source: ModelResourceObservation.source, sequence: sequence),
            diagnosticScope: .refresh(generation: generation))
    }
    public func stopDetection() async {
        detection?.cancel()
        _ = await detection?.result
    }
    private func startDetection(context: ProcessingContext) async throws {
        guard detection == nil else { throw AudioDetectionError.busy }
        let consumer = try uiExecution.begin(context.requestID)
        defer { uiExecution.finish(context.requestID) }
        let ready = AudioDetectionReadiness()
        let call = try InternalTool(path: "Speech.Detection.run").call([:])
        let envelope = OutputEnvelope(
            source: descriptor.id, context: context, output: .toolCall(call), executionAttachment: ready)
        let operation = Task {
            let outcome = try await consumer.execute(envelope)
            if outcome.isError {
                throw ApplicationControlIntentFailure.execution(
                    outcome.failure ?? outcome.tool?.value ?? "Detection failed")
            }
        }
        detection = operation
        let deadline = Task {
            for await _ in ready.events {
                do {
                    try await Task.sleep(for: .seconds(10))
                    try Task.checkCancellation()
                    ready.cancel(completed: true)
                    operation.cancel()
                } catch {}
                return
            }
        }
        defer { detection = nil }
        do {
            try await withTaskCancellationHandler {
                try await operation.value
            } onCancel: {
                operation.cancel()
            }
        } catch {
            deadline.cancel()
            ready.finish()
            await deadline.value
            if !Task.isCancelled, operation.isCancelled, ready.completed { return }
            throw error
        }
        deadline.cancel()
        ready.finish()
        await deadline.value
    }
    private func handleSettings(_ value: SettingsInput, context: ProcessingContext) async throws -> SettingsReply {
        guard let settings = uiProviderSettings, let discovery = uiProviderDiscovery,
            let presentation = uiProviderPresentation
        else { throw UIRequestError.unavailable }
        switch value {
        case .restore, .save:
            let operation: ProviderSettingsIntent.Operation
            let id: String
            if case .save(let draft) = value {
                operation = .save
                id = try await settings.stageSave(
                    .init(
                        enabled: draft.enabled, url: draft.url, key: draft.key, model: draft.model,
                        providers: draft.providers.map {
                            .init(enabled: false, url: $0.url, key: $0.key, model: $0.model, name: $0.name, id: $0.id)
                        }, writerProviderID: draft.writerProviderID, writerModel: draft.writerModel,
                        writerThinking: draft.writerThinking),
                    sessionID: sessionID)
            } else {
                operation = .restore
                id = try await settings.stageRestore(sessionID: sessionID)
            }
            do {
                try await presentation.register(id, operation: operation == .restore ? .restore : .save)
                _ = try await executeUI(
                    ProviderSettingsIntent(operation: operation, requestID: id, presentation: true).input(
                        sessionID: sessionID),
                    context: context, provider: true)
                let stored = try await settings.take(id, sessionID: sessionID)
                await settings.discard(id, sessionID: sessionID)
                await presentation.discard(id)
                if operation == .save { return .completed }
                return .draft(
                    .init(
                        enabled: stored.enabled, url: stored.url, key: stored.key, model: stored.model,
                        providers: stored.providers.map {
                            .init(enabled: false, url: $0.url, key: $0.key, model: $0.model, name: $0.name, id: $0.id)
                        }, writerProviderID: stored.writerProviderID, writerModel: stored.writerModel,
                        writerThinking: stored.writerThinking))
            } catch {
                await settings.discard(id, sessionID: sessionID)
                await presentation.discard(id)
                throw error
            }
        case .discover(let draft):
            let id = try await discovery.stage(.init(url: draft.url, key: draft.key), sessionID: sessionID)
            do {
                guard
                    let raw = try await executeUI(
                        ProviderDiscoveryIntent(requestID: id, presentation: false).input(sessionID: sessionID),
                        context: context, provider: true)
                else { throw CommunicationError.invalidPayload }
                guard raw.utf8.count <= 65_536 else { throw CommunicationError.invalidPayload }
                let models = try JSONDecoder().decode([String].self, from: Data(raw.utf8))
                guard models.count <= 2048, models.allSatisfy({ $0.utf8.count <= 512 }) else {
                    throw CommunicationError.invalidPayload
                }
                await discovery.discard(id, sessionID: sessionID)
                return .models(models)
            } catch {
                await discovery.discard(id, sessionID: sessionID)
                throw error
            }
        }
    }
    private func handleResources(_ value: ResourcesInput, context: ProcessingContext) async throws -> ResourcesReply {
        let intent: ModelResourceIntent
        switch value {
        case .refresh(let generation):
            intent = generation.map { .refreshPresentation(generation: $0) } ?? .refreshResources
        case .restore: intent = .restoreSource
        case .save(let draft):
            intent = .saveSource(
                endpoint: draft.endpoint, allowsCellular: draft.allowsCellular,
                recognition: draft.useCustomRecognition, synthesis: draft.useCustomSynthesis)
        case .download(let id, let draft):
            intent = .download(id: id, endpoint: draft.endpoint, allowsCellular: draft.allowsCellular)
        case .cancel(let id): intent = .cancel(id)
        case .remove(let id): intent = .remove(id)
        }
        let scope: ModelResourceHostFailure.Scope
        switch value {
        case .restore, .save: scope = .preference
        case .refresh(let generation?): scope = .refresh(generation: generation)
        default: scope = .operation
        }
        let result = try await executeUI(
            intent.input(sessionID: sessionID), context: context, diagnosticScope: scope)
        switch value {
        case .refresh:
            guard let result else { throw CommunicationError.invalidPayload }
            return .snapshot(try decodeResources(result))
        case .restore, .save:
            guard let result else { throw CommunicationError.invalidPayload }
            return .source(try JSONDecoder().decode(ModelResourceSourceDraft.self, from: Data(result.utf8)))
        default: return .completed
        }
    }
    private enum UICommandFailure: Error {
        case admission(any Error)
        case dispatch(any Error)
        var phase: ModelResourceHostFailure.Phase {
            switch self {
            case .admission: .admission
            case .dispatch: .dispatch
            }
        }
        var underlying: any Error {
            switch self {
            case .admission(let error), .dispatch(let error): error
            }
        }
    }
    private func executeUI(
        _ request: AgentInput, context: ProcessingContext, provider: Bool = false,
        diagnosticScope: ModelResourceHostFailure.Scope? = nil
    ) async throws -> String? {
        do { return try await executeUIBody(request, context: context, provider: provider) } catch let failure
            as UICommandFailure
        {
            try Task.checkCancellation()
            var bytes = Array(String(describing: failure.underlying).utf8.prefix(2048))
            while String(bytes: bytes, encoding: .utf8) == nil { bytes.removeLast() }
            let message = String(decoding: bytes, as: UTF8.self)
            if provider { throw ProviderIntentFailure(message: message, failureCode: nil) }
            guard let diagnosticScope else { throw ApplicationControlIntentFailure.execution(message) }
            let diagnostic = ModelResourceHostFailure(
                requestID: context.requestID, phase: failure.phase, scope: diagnosticScope, message: message)
            let followup = ProcessingContext(
                sessionID: context.sessionID, generation: context.generation, source: ModelResourceHostFailure.source,
                parentID: context.requestID, hops: 1)
            do {
                _ = try await executeUIBody(
                    diagnostic.input(sessionID: sessionID), context: followup, initialFailure: message)
            } catch ApplicationControlIntentFailure.presented {
                throw ApplicationControlIntentFailure.presented(message)
            } catch {
                throw NativeCleanupFailure(errors: [failure.underlying, error])
            }
            throw ApplicationControlIntentFailure.presented(message)
        }
    }
    private func executeUIBody(
        _ request: AgentInput, context: ProcessingContext, provider: Bool = false, initialFailure: String? = nil
    ) async throws -> String? {
        let consumer = try uiExecution.begin(context.requestID)
        defer { uiExecution.finish(context.requestID) }
        do {
            do { try await receive(context.input(request.payload)) } catch { throw UICommandFailure.admission(error) }
            let maximumCalls: Int
            if case .observation(let message) = request.payload {
                if message.appInteraction != nil || message.resourceHostFailure != nil {
                    maximumCalls = 1
                } else if case .restoreSource? = message.resourceIntent {
                    maximumCalls = 3
                } else if case .saveSource? = message.resourceIntent {
                    maximumCalls = 3
                } else {
                    maximumCalls = 2
                }
            } else {
                maximumCalls = 2
            }
            var value: String?
            var failure = initialFailure
            var failureCode: String?
            var presented = false
            for _ in 0..<16 {
                try Task.checkCancellation()
                guard let envelope = try uiExecution.next(context.requestID, maximumCalls: maximumCalls) else {
                    throw CommunicationError.invalidPayload
                }
                let result: OutputExecutionResult
                do {
                    if case .toolCall = envelope.output {
                        result = try await consumer.executeReturning(envelope)
                    } else {
                        result = try await consumer.execute(envelope)
                    }
                } catch { throw UICommandFailure.dispatch(error) }
                if let error = result.failure {
                    throw UICommandFailure.dispatch(ApplicationControlIntentFailure.execution(error))
                }
                if let tool = result.tool {
                    if tool.isError {
                        failure = failure.map { $0 + "; presentation: " + tool.value } ?? tool.value
                        if failureCode == nil { failureCode = tool.failureCode?.rawValue }
                    } else {
                        if case .toolCall(let call) = envelope.output {
                            if [
                                "System.ModelResources.restoreSource", "System.ModelResources.saveSource",
                                "System.ModelResources.snapshotResources", "UI.ResourcePresentation.showResources",
                                "System.Provider.discoverModels", "System.Provider.restoreSettings",
                                "System.Provider.saveSettings",
                            ].contains(call.toolPath) {
                                value = tool.value
                            }
                            if call.toolPath.hasPrefix("UI.ResourcePresentation.show") { presented = failure != nil }
                        }
                    }
                }
                if case .control(let state) = envelope.output {
                    if state == "application.control.finished" { return value }
                    if provider {
                        throw ProviderIntentFailure(
                            message: failure ?? state, failureCode: failureCode, presented: presented)
                    }
                    if presented { throw ApplicationControlIntentFailure.presented(failure ?? state) }
                    throw ApplicationControlIntentFailure.execution(failure ?? state)
                }
            }
            throw CommunicationError.capacityExceeded
        } catch {
            let original = error
            let cleanup = Task.detached { [self] in
                try await AgentUIInputs.$owner.withValue(descriptor.id) {
                    try await self.receive(
                        ModelResourceIntent.retire(context.requestID).input(sessionID: self.sessionID))
                }
            }
            do { try await cleanup.value } catch { throw NativeCleanupFailure(errors: [original, error]) }
            throw error
        }
    }
}
