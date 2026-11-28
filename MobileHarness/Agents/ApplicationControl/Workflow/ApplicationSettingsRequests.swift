import AgentCore
import Foundation
import FunctionContracts
import Gateway
import UI

extension ApplicationControlAgent {
    func handleWindow(_ value: WindowInput, context: ProcessingContext) async throws {
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
        guard let reference = await uiWindows?.reference(for: value.id) else { throw CommunicationError.scopeClosed }
        let call = try permission.call(["windowID": reference])
        windowCalls.insert(call.id)
        defer { windowCalls.remove(call.id) }
        let result = try await consumer.callTool(
            OutputEnvelope(source: descriptor.id, context: context, output: .toolCall(call)))
        try Task.checkCancellation()
        if result.isCancellationOnly { throw CancellationError() }
        if result.isError {
            throw ApplicationControlIntentFailure.execution(result.failure ?? result.tool?.value ?? "Window failed")
        }
    }

    public func stopDetection() async {
        detection?.cancel()
        _ = await detection?.result
    }
    func startDetection(context: ProcessingContext, keywordTest: Bool = false) async throws {
        guard detection == nil else { throw AudioDetectionError.busy }
        let consumer = try uiExecution.begin(context.requestID)
        defer { uiExecution.finish(context.requestID) }
        let ready = AudioDetectionReadiness(keywordTest: keywordTest)
        let call = try InternalTool(path: "Speech.Detection.run").call([:])
        let envelope = OutputEnvelope(
            source: descriptor.id, context: context, output: .toolCall(call), executionAttachment: ready)
        let operation = Task {
            let outcome = try await consumer.callTool(envelope)
            if outcome.isCancellationOnly { throw CancellationError() }
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
    func handleSettings(_ value: SettingsInput, context: ProcessingContext) async throws -> SettingsReply {
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
                        writerThinking: draft.writerThinking, writerUsesLocal: draft.writerUsesLocal,
                        writerLocalModelID: draft.writerLocalModelID,
                        decisionProviderID: draft.decisionProviderID, decisionModel: draft.decisionModel,
                        decisionUsesLocal: draft.decisionUsesLocal, decisionLocalModelID: draft.decisionLocalModelID,
                        assistantLocalModelID: draft.assistantLocalModelID),
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
                        writerThinking: stored.writerThinking, writerUsesLocal: stored.writerUsesLocal,
                        writerLocalModelID: stored.writerLocalModelID,
                        decisionProviderID: stored.decisionProviderID, decisionModel: stored.decisionModel,
                        decisionUsesLocal: stored.decisionUsesLocal == true,
                        decisionLocalModelID: stored.resolvedDecisionLocalModelID,
                        assistantLocalModelID: stored.assistantLocalModelID))
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
    func handleResources(_ value: ResourcesInput, context: ProcessingContext) async throws -> ResourcesReply {
        let intent: ModelResourceIntent
        switch value {
        case .refresh(let generation):
            intent = generation.map { .refreshPresentation(generation: $0) } ?? .refreshResources
        case .restore: intent = .restoreSource
        case .save(let draft):
            intent = .saveSource(
                endpoint: draft.endpoint, allowsCellular: draft.allowsCellular,
                recognition: draft.useCustomRecognition, synthesis: draft.useCustomSynthesis,
                decision: draft.useLocalDecision, vadOnsetWindows: draft.vadOnsetWindows,
                vadThreshold: draft.vadThreshold, enhancement: draft.useSpeechEnhancement,
                keywordInterrupt: draft.useKeywordInterrupt, speechModels: draft.speechModels,
                synthesisVoice: draft.synthesisVoice, keywordThreshold: draft.keywordThreshold)
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
}
