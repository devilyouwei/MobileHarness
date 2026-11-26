import AgentCore
import Foundation
import ModelKit
import OSLog
import StorageChat
import StorageCore
import StorageTasks
import UI

extension AssistantChatWorker {
    @discardableResult
    func emitAction(_ call: ActionCall, for input: AgentInput, modelGenerated: Bool = false) throws -> Bool {
        guard roundID != nil, activeInput?.id == input.id else { return emit(.actionCall(call), for: input) }
        guard roundCalls.count < 120 else { throw GenerationError.limitExceeded }
        let id = UUID().uuidString

        try roundCoordinator?.register(id: id)
        roundCalls.append(
            .init(id: id, path: call.actionPath.description, tool: false, native: nil, modelGenerated: modelGenerated))
        return emit(.actionCall(call), for: input, callID: id)
    }

    func modelEvidence(_ event: ChatEvent, input: AgentInput) async throws {
        switch event {
        case .text: break
        case .usage(let usage):
            try await recordGenerationEvidence {
                try await conversations.recordTokenUsage(
                    .init(
                        input: usage.input, generated: usage.generated, total: usage.total,
                        cachedInput: usage.cachedInput, cacheWriteInput: usage.cacheWriteInput), for: input.id)
            }
        case .finished(let reason):
            switch reason {
            case .stop: generationFinishReason = "stop"
            case .lengthLimit: generationFinishReason = "lengthLimit"
            case .toolCalls: generationFinishReason = "toolCalls"
            }
        case .toolCall: break
        }
    }
    func recordGenerationEvidence(_ operation: () async throws -> Void) async throws {
        do { try await operation() } catch {
            feedbackFailure = "Generation history update failed: \(error)"
            throw error
        }
    }
    /// Presentation calls participate in the round, but never count as a model-generated answer.
    func finishReplyWaiting(_ requestID: String, input: AgentInput) async throws {
        guard replyWaitingRequest == requestID else { return }
        replyWaitingRequest = nil
        await replyPresentation?(false)
        guard presentsReply, input.turn != nil else { return }
        // A cancelled round is cleared by the local presentation lifecycle.
        guard !Task.isCancelled else { return }
        guard
            try emitAction(
                Self.replyWaiting.call(["enabled": "false", "requestID": requestID]), for: input)
        else { throw HarnessError.queueFull }
    }
    func dispatchRequest(_ input: AgentInput, requestID: String, model: InferenceModelIdentity? = nil) async throws {
        try await conversations.markModelRequestDispatched(
            input.id, requestID: requestID, modelID: model?.modelID, displayName: model?.displayName)
        interruptedIntents[input.sessionID] = nil
    }

    func collect(_ request: ChatRequest, input: AgentInput, invocationID: String, using chat: any ChatCapability)
        async throws
        -> String
    {
        try Task.checkCancellation()
        let requestID = UUID().uuidString
        if presentsReply, input.turn != nil {
            guard
                try emitAction(
                    Self.replyWaiting.call(["enabled": "true", "requestID": requestID]), for: input)
            else { throw HarnessError.queueFull }
            replyWaitingRequest = requestID
        }
        if let replyPresentation {
            replyWaitingRequest = requestID
            await replyPresentation(true)
        }
        var request = request.measuringInference()
        let recordedRequest = request
        request.onDispatch = { [self] in
            if recordedRequest.metadata?.model == nil { try await self.dispatchRequest(input, requestID: invocationID) }
        }
        request.onModelDispatch = { [self] model in
            try await self.dispatchRequest(input, requestID: invocationID, model: model)
        }
        let startCalls = generationCalls
        let result: Result<String, any Error>
        do {
            result = .success(
                try await AgentChatDriver.collect(
                    request, using: chat,
                    consumers: .init(
                        text: { try await self.consumeActionText($0, input: input) },
                        native: { _ = try await self.consumeNativeTools($0, input: input) },
                        evidence: { event in
                            try await self.dispatchRequest(input, requestID: invocationID)
                            switch event {
                            case .text(let text) where !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
                                try await self.finishReplyWaiting(requestID, input: input)
                            case .toolCall, .finished:
                                try await self.finishReplyWaiting(requestID, input: input)
                            default: break
                            }
                            try await self.modelEvidence(event, input: input)
                        },
                        recording: { evidence in
                            if let update = evidence.transport {
                                try await self.conversations.recordModelTransport(update, for: input.id)
                                return
                            }
                            try await self.conversations.recordModelExchange(
                                requestJSON: evidence.requestJSON, response: evidence.responseJSON, for: input.id,
                                initial: evidence.initial)
                        },
                        timing: { timing in
                            try await self.recordGenerationEvidence {
                                try await self.conversations.recordModelTiming(
                                    startedAt: timing.startedAt, firstTokenAt: timing.firstTokenAt,
                                    latency: timing.firstTokenLatency, for: input.id)
                            }
                        },
                        metadata: { metadata in
                            guard metadata.startedAt != nil else { return }
                            try await self.recordGenerationEvidence {
                                try await self.conversations.recordModelMetadata(
                                    providerModelID: metadata.providerModelID, startedAt: metadata.startedAt,
                                    firstOutputAt: metadata.firstOutputAt,
                                    firstOutputLatency: metadata.firstOutputLatency,
                                    completedAt: metadata.completedAt,
                                    usage: metadata.tokenUsage.map {
                                        .init(
                                            input: $0.input, generated: $0.generated, total: $0.total,
                                            cachedInput: $0.cachedInput, cacheWriteInput: $0.cacheWriteInput)
                                    }, finishReason: metadata.finishReason.map(\.rawValue), for: input.id,
                                    requestID: invocationID)
                            }
                        })))
        } catch {
            result = .failure(error)
        }
        // Runs for errors before a stream exists as well as cancellation of a live stream.
        try await finishReplyWaiting(requestID, input: input)
        let answer = try result.get()
        guard generationCalls > startCalls else {
            throw CapabilityError.unavailable("LLM returned no speakable answer")
        }
        return answer
    }

    func consumeActionText(_ fragments: AsyncThrowingStream<String, any Error>, input: AgentInput)
        async throws -> String
    {
        let catalog = requestCatalog ?? modelCapabilities
        var generator = AgentGenerator(
            capabilities: catalog, textMapping: Self.mapText,
            segmentation: try Self.textSegmentation)
        var text = ""
        var emittedCalls = 0
        for try await delta in fragments {
            try Task.checkCancellation()
            try await recordGenerationEvidence { try await conversations.append(delta, to: input.id) }
            text += delta
            try await emitFunctions(generator.append(delta), for: input, count: &emittedCalls)
        }
        try Task.checkCancellation()
        try await emitFunctions(generator.finish(), for: input, count: &emittedCalls)
        return text
    }

    func consumeNativeTools(_ calls: AsyncThrowingStream<ChatToolCall, any Error>, input: AgentInput)
        async throws -> String
    {
        let catalog = requestCatalog ?? modelCapabilities
        var emittedCalls = 0
        for try await native in calls {
            try Task.checkCancellation()
            let callID = UUID().uuidString
            try await recordGenerationEvidence {
                try await conversations.recordToolCall(
                    ModelToolCall(
                        id: callID, providerID: native.id, name: native.name,
                        argumentsJSON: native.argumentsJSON), for: input.id)
            }
            let call: ToolCall
            do {
                call = try ToolCallParser.parse(
                    id: callID, alias: native.name, argumentsJSON: Data(native.argumentsJSON.utf8),
                    capabilities: catalog)
                guard !roundCalls.contains(where: { $0.native?.id == native.id })
                else {
                    throw GenerationError.limitExceeded
                }
                try budget?.reserveNativeCall()

                try roundCoordinator?.register(id: call.id)
                roundCalls.append(
                    .init(id: callID, path: call.toolPath, tool: true, native: native))
                try await emitFunctions([.tool(call)], for: input, count: &emittedCalls)
            } catch {
                do {
                    try await recordGenerationEvidence {
                        try await conversations.recordToolOutcome(
                            callID, for: input.id, state: .failed, error: String(describing: error))
                    }
                } catch {
                    try Task.checkCancellation()
                    emit(.control("agent.historyError: \(error)"), for: input)
                    throw error
                }
                guard let reason = error as? GenerationError,
                    reason == .unknownCapability || reason == .invalidParameters
                else { throw error }
                guard !roundCalls.contains(where: { $0.native?.id == native.id })
                else {
                    throw GenerationError.limitExceeded
                }
                try budget?.reserveNativeCall()
                let path =
                    catalog.tools.first(where: { $0.alias == native.name })?.path ?? native.name

                try roundCoordinator?.register(id: callID)
                roundCalls.append(
                    .init(
                        id: callID, path: path, tool: true, native: native,
                        rejection: CallRejection(kind: .tool, alias: native.name, callID: callID, reason: reason)))
                try acceptResult(
                    .init(
                        callID: callID,
                        value: invocationRejectionValue(
                            CallRejection(kind: .tool, alias: native.name, callID: callID, reason: reason)),
                        isError: true, failureCode: "invalidInvocation"), at: roundCalls.count - 1)
                try await emitFunctions(
                    [.rejected(CallRejection(kind: .tool, alias: native.name, callID: callID, reason: reason))],
                    for: input, count: &emittedCalls)
            }
        }
        try Task.checkCancellation()
        return ""
    }
    func emitImmediate(_ text: String, for input: AgentInput) async {
        defer {
            worker = nil
            activeInput = nil
            finishHostCancellation(input)
            drain()
        }
        do {
            let selection = AgentDecisionContext(snapshot: try await contextRepository.snapshot(), input: input)
            let batch = try selection.batch()
            try await contextRepository.update {
                try $0.consume(batch, retainingLast: 4096)
                if $0.work[input.id] == nil { try $0.beginWork(input.id, sessionID: input.sessionID) }
                try $0.transitionWork(input.id, to: .running)
            }
            try beginReplyTurn(input)
            guard text.utf8.count <= 16_384 else { throw CapabilityError.eventTooLarge }
            var generator = AgentGenerator(
                capabilities: modelCapabilities, textMapping: Self.mapText,
                segmentation: try Self.textSegmentation)
            var count = 0
            try await emitFunctions(
                generator.append(AgentGenerator.escapeText(text)) + generator.finish(), for: input, count: &count)
            try await contextRepository.update { try $0.transitionWork(input.id, to: .completed) }
            emit(.control("agent.finished"), for: input)
        } catch {
            let cancelled = Task.isCancelled || error is CancellationError
            do {
                try await contextRepository.update {
                    if $0.work[input.id]?.state.terminal == false {
                        try $0.transitionWork(input.id, to: cancelled ? .cancelled : .failed)
                    }
                }
            } catch { emit(.control("agent.historyError: \(error)"), for: input) }
            if !Task.isCancelled {
                if cancelled {
                    emit(.control("agent.cancelled"), for: input)
                } else {
                    emitFailure(error, for: input)
                }
            }
        }
    }
    func reserveGeneratedCall(count: inout Int) throws {
        guard count < 120 else { throw GenerationError.limitExceeded }
        if roundID != nil {
            guard generationCalls < 120 else { throw GenerationError.limitExceeded }
            generationCalls += 1
        }
        count += 1
    }

    func invocationRejectionValue(_ rejection: CallRejection) throws -> String {
        let correction =
            rejection.reason == .unknownCapability
            ? try AgentPrompts.text("Shared/ExecutionFeedback", "unknownAlias")
            : try AgentPrompts.text(
                "Shared/ExecutionFeedback",
                rejection.reason == .controlInsideWait ? "controlInsideWait" : "invalidArguments")
        let loading =
            usesSkills
            ? try AgentPrompts.text("Shared/ExecutionFeedback", "loadSkill")
            : ""
        return try AgentPrompts.text(
            "Shared/ExecutionFeedback", "rejection",
            [
                "reason": String(describing: rejection.reason), "kind": String(describing: rejection.kind),
                "alias": rejection.alias,
            ])
            + (try AgentPrompts.text("Shared/ExecutionFeedback", "notExecuted")) + correction + loading
    }

    func emitFunctions(_ calls: [GenerationEvent], for input: AgentInput, count: inout Int) async throws {
        for event in calls {
            if case .rejected(let rejection) = event {
                try Task.checkCancellation()
                try reserveGeneratedCall(count: &count)
                if rejection.kind != .tool, roundID != nil {
                    let path =
                        (rejection.kind == .control
                            ? modelCapabilities.controls.first(where: { $0.alias == rejection.alias })?.path.description
                            : modelCapabilities.actions.first(where: { $0.alias == rejection.alias })?.path.description)
                        ?? rejection.alias

                    let id = UUID().uuidString
                    try roundCoordinator?.register(id: id)
                    roundCalls.append(
                        .init(
                            id: id, path: path, tool: false,
                            native: nil, rejection: rejection))
                    try acceptResult(
                        .init(
                            callID: id, value: try invocationRejectionValue(rejection), isError: true,
                            failureCode: "invalidInvocation"), at: roundCalls.count - 1)
                }
                guard emit(.rejectedCall(rejection), for: input) else { throw HarnessError.queueFull }
                continue
            }
            if case .scheduling(let directive) = event {
                try Task.checkCancellation()
                guard emit(.scheduling(directive), for: input) else { throw HarnessError.queueFull }
                continue
            }
            if case .tool(let call) = event {
                try Task.checkCancellation()
                try reserveGeneratedCall(count: &count)
                guard emit(.toolCall(call), for: input, callID: roundID == nil ? nil : call.id) else {
                    throw HarnessError.queueFull
                }
                try await recordSkillUse(path: call.toolPath, callType: "tool", input: input)
                continue
            }
            if case .control(let call) = event {
                try Task.checkCancellation()
                guard lifecycle == .running || lifecycle == .paused else { throw HarnessError.notRunning }
                try reserveGeneratedCall(count: &count)
                let id = UUID().uuidString
                try roundCoordinator?.register(id: id)
                let path = call.path.description
                if roundID != nil {
                    roundCalls.append(.init(id: id, path: path, tool: false, native: nil, modelGenerated: true))
                }
                // Controls run in emission order and never wait on Actions.
                let result = try await executeControl(
                    path: path, arguments: call.parameters, input: input, callID: id)
                if roundID != nil { try acceptResult(result, at: roundCalls.count - 1) }
                continue
            }
            guard let original = event.actionCall else { continue }
            let modelGenerated: Bool
            if case .action = event { modelGenerated = true } else { modelGenerated = false }
            let call = original
            try Task.checkCancellation()
            guard lifecycle == .running || lifecycle == .paused else { throw HarnessError.notRunning }
            try reserveGeneratedCall(count: &count)
            if call.actionPath == ActionPath(domain: "Speech", module: "Playback", function: "speak"),
                let text = call.parameters["text"]
            {
                try await emitPlayback(text, for: input, modelGenerated: modelGenerated)
                continue
            }
            if call.actionPath == Self.caption.path, listening?.isListening == false { continue }
            guard try emitAction(call, for: input, modelGenerated: modelGenerated) else { throw HarnessError.queueFull }
            try await recordSkillUse(path: call.actionPath.description, callType: "action", input: input)
        }
    }

    func emitPlayback(_ text: String, for input: AgentInput, modelGenerated: Bool = false) async throws {
        guard listening?.isListening != false else { return }
        guard let speechOutput else { throw CapabilityError.unavailable("Speech output not configured") }
        let audioID = try await speechOutput.prepare(text: text, input: input)
        do {
            try Task.checkCancellation()
            let call = try Self.playback.call(["audioID": audioID])
            guard try emitAction(call, for: input, modelGenerated: modelGenerated) else { throw HarnessError.queueFull }
            captureDecisionText(text, input: input)
        } catch {
            do { try await speechOutput.cancel(audioID: audioID, input: input) } catch let cleanup {
                throw AgentFailure(
                    component: "assistant", operation: "speech.submit", underlying: error, cleanupErrors: [cleanup])
            }
            throw error
        }
    }

    func recordSkillUse(path: String, callType: String, input: AgentInput) async throws {
        guard usesSkills, roundID != nil, let catalog = requestCatalog else { return }
        let visible =
            callType == "action"
            ? catalog.actions.contains { $0.path.description == path }
            : catalog.tools.contains { $0.path == path }
        guard visible else { return }
        let snapshotSkills = requestSkillIDs
        try await contextRepository.update {
            try $0.state.skillState?.recordUse(
                path: path, callType: callType, inputID: input.id, snapshotSkills: snapshotSkills)
        }
    }

    func finishHostCancellation(_ input: AgentInput, force: Bool = false) {
        guard !hostCancellationInProgress || force else { return }
        guard let cancellation = hostCancelledInput, cancellation.id == input.id else { return }
        hostCancelledInput = nil
        replyInputs.remove(input.id)
        if !emit(.control("agent.cancelled"), for: input, terminalRound: cancellation.round) {
            // Explicit bounded rejection: no cancellation success is fabricated for the transport.
            reportHostCancellationFailure = true
        }
    }

    static func failureDescription(_ error: any Error) -> String {
        (error as? any ChatFailureProviding)?.chatFailure.description ?? String(describing: error)
    }

    func emitFailure(_ error: any Error, for input: AgentInput, detail: String? = nil) {
        let cause = (error as? AssistantChatRoundFailure)?.cause ?? error
        let diagnostic: AgentFailureDiagnostic
        if let model = cause as? any ChatFailureProviding {
            let cause = model.chatFailure
            diagnostic = .init(
                category: [.httpStatus, .transport].contains(cause.reason) ? .modelTransport : .modelResponse,
                code: "agent.model." + cause.reason.rawValue, detail: detail ?? Self.failureDescription(error))
        } else if let generation = cause as? GenerationError {
            diagnostic = .init(
                category: .generation, code: "agent.generation." + String(describing: generation),
                detail: detail ?? String(describing: generation))
        } else if cause is ContainerContextError {
            diagnostic = .init(
                category: .context, code: "agent.context.snapshot", detail: detail ?? String(describing: error))
        } else {
            diagnostic = .init(
                category: .runtime, code: "agent.runtime.failed", detail: detail ?? String(describing: error))
        }
        emit(.control("agent.error: \(diagnostic.detail)"), for: input, failure: diagnostic)
    }

    @discardableResult
    func emit(
        _ output: AgentOutput, for input: AgentInput, callID: String? = nil, terminalRound: String? = nil,
        failure: AgentFailureDiagnostic? = nil
    ) -> Bool {
        if case .control(let value) = output,
            value == "agent.finished" || value == "agent.cancelled" || value.hasPrefix("agent.error:")
        {
            replyInputs.remove(input.id)
        }
        outputSequence += 1
        let outputRoundID: String?
        if case .communication = output {
            outputRoundID = nil
        } else {
            outputRoundID = terminalRound ?? (input.id == activeInput?.id ? roundID : nil)
        }
        switch continuation.yield(
            OutputEnvelope(
                source: descriptor.id, context: input.context, output: output, sequence: outputSequence,
                roundID: outputRoundID,
                callID: callID, taskScope: input.taskScope, failure: failure,
                resourceBindings: outputRoundID == nil ? [:] : resourceBindings))
        {
        case .enqueued:
            return true
        case .dropped, .terminated:
            lifecycle = .failed
            queue.removeAll()
            worker?.cancel()
            continuation.finish()
            return false
        @unknown default:
            lifecycle = .failed
            queue.removeAll()
            worker?.cancel()
            continuation.finish()
            return false
        }
    }
}
