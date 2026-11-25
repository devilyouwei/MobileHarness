import AgentCore
import Foundation
import ModelKit
import OSLog
import StorageChat
import StorageCore
import StorageTasks
import UI

extension AssistantChatWorker {
    func generate(_ text: String, input: AgentInput, using chat: any ChatCapability) async {
        let selected =
            continuationRounds[input.id]?.language
            ?? pendingRounds.values.first { $0.input.id == input.id && $0.queued }?.language
            ?? AgentPrompts.normalizedLanguage(language())
        await AgentPrompts.$language.withValue(selected) {
            await generateInLanguage(text, input: input, using: chat)
        }
    }

    func generateInLanguage(_ text: String, input: AgentInput, using chat: any ChatCapability) async {
        await publishInputQueue()
        defer {
            if continuationRounds[input.id] == nil && !pendingRounds.values.contains(where: { $0.input.id == input.id })
            {
                inputInteractions[input.id] = nil
            }
            activeInput = nil
            retireRound()
            roundID = nil
            feedbackFailure = nil
            generationCalls = 0
            budget = nil
            resultBytes = 0
            worker = nil
            finishHostCancellation(input)
            drain()
        }
        let resumed = continuationRounds.removeValue(forKey: input.id)
        var recorded = resumed != nil
        currentOrdinal = resumed?.ordinal ?? 0
        generationCalls = 0
        budget = resumed?.budget
        resultBytes = 0
        generationFinishReason = nil
        var cancelledParkedRound = false
        do {
            let promptTemplates = try AgentPrompts.load(named: State.configurationName)
            if let key = pendingRounds.first(where: { $0.value.input.id == input.id && $0.value.queued })?.key,
                let parked = pendingRounds.removeValue(forKey: key)
            {
                cancelledParkedRound = parked.cancelled
                recorded = true
                roundID = key
                currentOrdinal = parked.ordinal
                budget = parked.budget
                requestCatalog = parked.catalog
                modelCapabilities = parked.capabilities
                requestSkillIDs = parked.skillIDs
                roundCoordinator = parked.coordinator
                roundCalls = parked.calls
                roundReceipt = parked.receipt
                resultBytes = parked.resultBytes
                generationFinishReason = parked.finishReason
                resourceBindings = parked.bindings
                imageScopes = parked.imageScopes
                ephemeralImageIDs = parked.imageIDs
                let next = try await completeRound(
                    parked.initial, input: input, using: parked.chat,
                    text: parked.text, userIntent: parked.userIntent,
                    generationError: parked.cancelled ? CancellationError() : parked.generationError)
                try await settleRound(next, input: input, chat: parked.chat, requestTaskID: parked.requestTaskID)
                return
            }
            let selection = AgentDecisionContext(
                snapshot: try await contextRepository.snapshot(), input: input,
                memberIDs: batchMembers[input.id]?.map(\.id))
            recorded = recorded || selection.snapshot.state.history.current.turns.contains(where: { $0.id == input.id })
            let members = batchMembers[input.id] ?? [input]
            let memberIDs = members.map(\.id)
            let memberEvidence = members.compactMap { member in
                coordination[member.id].map { AssistantInputCoordination.Member(id: member.id, evidence: $0) }
            }
            for member in members {
                if var evidence = coordination[member.id] {
                    evidence.batchID = input.id
                    evidence.memberIDs = memberIDs
                    if member.id == input.id { evidence.members = memberEvidence }
                    coordination[member.id] = evidence
                    try await conversations.recordCoordination(evidence, for: member.id)
                }
            }
            let decision = try contextBuilder.build(state: selection, batch: selection.batch())
            try await contextRepository.update { context in
                try context.consume(decision.batch, retainingLast: 4096)
                try context.transitionWork(input.id, to: .running)
            }
            if let skills = decision.state.skillState {
                guard
                    skills.activeTaskID == nil || skills.taskID(for: input.id) == skills.activeTaskID
                else {
                    throw CommunicationError.scopeClosed
                }
                modelCapabilities = try skills.registry(fixed: descriptor.capabilities)
            }
            let dynamicSystem = try State.systemPrompt(
                modelCapabilities, skills: decision.state.skillState, communication: communicationPolicy)
            let dynamicTools: [ChatToolDefinition] =
                await chat.supportsToolCalls
                ? try modelCapabilities.tools.compactMap { registration in
                    guard let definition = registration.definition else { return nil }
                    return try ChatToolDefinition(declaration: JSONEncoder().encode(definition))
                } : []
            let request: ChatRequest
            if let resumed {
                let history = try await conversations.readCurrent()
                let closedTaskContext =
                    decision.state.skillState != nil
                    && resumed.requestTaskID != nil
                    && resumed.requestTaskID != decision.state.skillState?.activeTaskID
                var messages =
                    closedTaskContext
                    ? try decision.messages(system: dynamicSystem, user: text) + resumed.boundaryMessages
                    : resumed.request.messages
                if decision.state.skillState != nil {
                    messages.removeAll { $0.role == .system }
                    messages.insert(.init(role: .system, content: dynamicSystem), at: 0)
                }
                let allowed = Set(
                    selection.snapshot.records.filter { $0.taskID == input.taskScope?.id }.compactMap {
                        try? JSONDecoder().decode(SignalEvidence.self, from: $0.data).signalID
                    })
                let intervening =
                    closedTaskContext
                    ? []
                    : history.current.turns.filter { turn in
                        turn.id != input.id && (input.taskScope == nil || allowed.contains(turn.id))
                    }.flatMap { turn in
                        (turn.modelRequests ?? []).filter {
                            $0.state == .completed && $0.date > resumed.readyAt
                                && (decision.state.skillState == nil
                                    || $0.historyTaskID == decision.state.skillState?.activeTaskID)
                        }
                    }.sorted { $0.date < $1.date }
                for invocation in intervening {
                    messages += try AssistantHistoryProjection.messages(for: invocation, templates: promptTemplates)
                }
                messages += mergedResults[input.id] ?? []
                let addsBatch = fullDuplex && (batchMembers[input.id]?.count ?? 0) > 1 && messages.last?.content != text
                if addsBatch { messages.append(.init(role: .user, content: text)) }
                let protectedCount =
                    resumed.protectedSuffixCount + (mergedResults[input.id]?.count ?? 0) + (addsBatch ? 1 : 0)
                request = try ChatRequest(
                    messages: try AgentChatContextBuilder.retainingRecent(
                        messages, preservingUser: text, protectedSuffixCount: protectedCount),
                    context: resumed.request.context,
                    maximumOutputTokens: resumed.request.maximumOutputTokens,
                    temperature: resumed.request.temperature,
                    tools: decision.state.skillState == nil ? resumed.request.tools : dynamicTools)
            } else {
                var messages = try decision.messages(system: dynamicSystem, user: text)
                if let attachments = mergedResults[input.id], !attachments.isEmpty {
                    let suppliedCalls = Set(attachments.flatMap(\.toolCalls).map(\.id))
                    // A freshly completed group may already be projected in history. Carry it once.
                    messages.removeAll { message in
                        !Set(message.toolCalls.map(\.id)).isDisjoint(with: suppliedCalls)
                            || message.toolCallID.map(suppliedCalls.contains) == true
                    }
                    messages.insert(contentsOf: attachments, at: max(0, messages.count - 1))
                }
                let record = try await beginHistoryRequest(input: input, text: text, messages: messages)
                recorded = true
                try Task.checkCancellation()
                let tools: [ChatToolDefinition]
                if await chat.supportsToolCalls {
                    tools = try modelCapabilities.tools.compactMap { registration in
                        guard let definition = registration.definition else { return nil }
                        return try ChatToolDefinition(declaration: JSONEncoder().encode(definition))
                    }
                } else {
                    tools = []
                }
                try await conversations.recordToolDefinitions(
                    tools.map { String(decoding: $0.declaration, as: UTF8.self) }, for: input.id)
                request = try ChatRequest(
                    messages: try AgentChatContextBuilder.retainingRecent(
                        messages, preservingUser: text, protectedSuffixCount: 1 + (mergedResults[input.id]?.count ?? 0)),
                    context: InferenceContext(requestID: input.id, scopeID: input.sessionID),
                    temperature: record.temperature, tools: tools)
            }
            var inputParts = [resumed?.inputText ?? text]
            inputParts += (mergedResults[input.id] ?? []).filter { $0.role != .assistant }.map(\.content)
            if (batchMembers[input.id]?.count ?? 0) > 1, !inputParts.contains(text) { inputParts.append(text) }
            let recordedInput = fullDuplex ? inputParts.joined(separator: "\n") : resumed?.inputText
            let attachmentCount = mergedResults[input.id]?.count ?? 0
            if budget == nil { budget = try AgentTaskBudget() }
            let next = try await executeRound(
                request, input: input, using: chat, inputText: recordedInput,
                userIntent: text, protectedSuffixCount: resumed?.protectedSuffixCount ?? (1 + attachmentCount))
            try Task.checkCancellation()
            try await settleRound(
                next, input: input, chat: chat, requestTaskID: selection.snapshot.state.skillState?.activeTaskID)
        } catch is RoundSuspended {
            return
        } catch {
            await speechOutput?.cancel(input: input)
            do {
                if try await retainPreparedBatch(input, error: error) { return }
            } catch { emit(.control("agent.error: batch retention failed: \(error)"), for: input) }
            continuationRounds[input.id] = nil
            queue.remove(id: input.id)
            let cancelled = Task.isCancelled || error is CancellationError
            let interrupted = cancelled && interruptedInputs.contains(input.id)
            var failure = Self.failureDescription(error)
            do {
                try await contextRepository.update {
                    try $0.transitionWork(
                        input.id,
                        to: Task.isCancelled || error is CancellationError ? .cancelled : .failed)
                }
            } catch { failure += "; context terminal persistence failed: \(error)" }
            if let scope = input.taskScope, !Task.isCancelled {
                do {
                    try await reportFixedTask(
                        scope, input: input,
                        result: ToolResult(callID: input.id, value: String(failure.prefix(1024)), isError: true))
                } catch { failure += "; task report failed: \(error)" }
            }
            do {
                try await finishLocalDecision(
                    input: input, finishRequested: false,
                    interrupted: cancelled || cancelledParkedRound)
            } catch {
                failure += "; local task cleanup failed: \(error)"
            }
            if recorded {
                do {
                    try await conversations.finish(
                        input.id, state: interrupted ? .interrupted : (cancelled ? .cancelled : .failed),
                        reason: generationFinishReason, error: failure)
                } catch { failure += "; history persistence failed: \(error)" }
            }
            do { try await finishBatch(input, cancelled: cancelled, interrupted: interrupted, failure: failure) } catch
            {
                failure += "; batch terminal persistence failed: \(error)"
            }
            guard !Task.isCancelled, lifecycle == .running || lifecycle == .paused else { return }
            if cancelled {
                emit(.control("agent.cancelled"), for: input)
            } else {
                emitFailure(error, for: input, detail: failure)
            }
        }
    }

    func finishBatch(
        _ input: AgentInput, cancelled: Bool = false, interrupted: Bool = false, failure: String? = nil
    ) async throws {
        defer { interruptedInputs.remove(input.id) }
        let members = batchMembers.removeValue(forKey: input.id) ?? [input]
        batchTexts[input.id] = nil
        mergedResults[input.id] = nil
        for member in members {
            coordination[member.id] = nil
            semanticMessages[member.id] = nil
            semanticAttachments[member.id] = nil
            if member.id == input.id { continue }
            inputInteractions[member.id] = nil
            replyInputs.remove(member.id)
            try await contextRepository.update { context in
                if context.work[member.id]?.state.terminal == false {
                    try context.transitionWork(
                        member.id,
                        to: interrupted
                            ? .interrupted : (cancelled ? .cancelled : (failure == nil ? .completed : .failed)))
                }
            }
            try await conversations.finish(
                member.id,
                state: interrupted ? .interrupted : (cancelled ? .cancelled : (failure == nil ? .completed : .failed)),
                reason: "batch:" + input.id, error: failure)
        }
    }

    func settleRound(_ next: ChatRequest?, input: AgentInput, chat: any ChatCapability, requestTaskID: String?)
        async throws
    {
        if let next {
            guard let budget else { throw HarnessError.invalidTransition }
            let boundaryMessages = try roundActionResultMessages()
            let previousTaskID = requestTaskID
            let currentTaskID = try await contextRepository.snapshot().state.skillState?.activeTaskID
            let closedTaskContext =
                previousTaskID != nil && previousTaskID != currentTaskID
            continuationRounds[input.id] = ContinuationRound(
                request: next,
                inputText: closedTaskContext
                    ? boundaryMessages.map(\.content).joined(separator: "\n")
                    : roundContinuationInputText, ordinal: currentOrdinal + 1,
                budget: budget, protectedSuffixCount: roundSuffixCount,
                readyAt: Date(), capability: chat,
                requestTaskID: requestTaskID,
                boundaryMessages: boundaryMessages, language: AgentPrompts.language)
            try await contextRepository.update { try $0.transitionWork(input.id, to: .continuation) }
            guard !cancelledAdmissions.contains(input.id), hostCancellationSession != input.sessionID else {
                inputInteractions[input.id] = nil
                throw CancellationError()
            }
            try queue.admit(input, disposition: .enqueue(priority: 0))
            return
        }
        try await contextRepository.update { try $0.transitionWork(input.id, to: .completed) }
        guard lifecycle == .running || lifecycle == .paused else { return }
        try await finishLocalDecision(input: input)
        try await completeTaskDecision(input)
        let interrupted = interruptedInputs.contains(input.id)
        try await conversations.finish(
            input.id, state: interrupted ? .interrupted : .completed, reason: generationFinishReason)
        try await finishBatch(input, interrupted: interrupted)
        emit(.control("agent.finished"), for: input)
    }

    func executeRound(
        _ initial: ChatRequest, input: AgentInput, using chat: any ChatCapability,
        inputText suppliedText: String?, userIntent: String, protectedSuffixCount: Int
    )
        async throws -> ChatRequest?
    {
        let request = initial
        let inputText = suppliedText ?? initial.messages.last?.content ?? ""
        do {
            generationCalls = 0
            resultBytes = 0
            try budget?.reserveRequest()
            if let budget { try await contextRepository.update { try $0.recordBudget(budget, for: input.id) } }
            retireRound()
            let decisionID = UUID().uuidString
            roundID = decisionID
            roundReceipt = nil
            roundCoordinator = AgentRoundCoordinator(id: decisionID, taskID: input.id)
            guard let requestID = roundID else { throw CommunicationError.invalidPayload }
            generationFinishReason = nil
            let decisionContext = try await contextRepository.snapshot()
            requestSkillIDs = decisionContext.state.skillState?.loaded ?? []
            let catalog =
                usesSkills
                ? try AgentSkillLoader.registry(requestSkillIDs, fixed: descriptor.capabilities)
                : modelCapabilities
            requestCatalog = catalog
            var stateMessages = request.messages
            var stateMessageCount = 0
            var requestedStates: [String]?
            ephemeralImageIDs.removeAll()
            resourceBindings.removeAll()
            imageScopes.removeAll()
            if usesSkills {
                guard let stateContext else { throw CommunicationError.invalidPayload }
                let names = try AgentSkillLoader.useStates(requestSkillIDs)
                await stateContext.synchronize(
                    session: input.sessionID, dialog: decisionContext.state.history.current.id)
                let snapshot = try await stateContext.multimodalSnapshot(session: input.sessionID, names: names)
                requestedStates = names
                resourceBindings = snapshot.resourceBindings
                imageScopes = Dictionary(
                    uniqueKeysWithValues: snapshot.images.compactMap { image in
                        image.resourceScope.map { (image.id, $0) }
                    })
                let imageProjection = try AgentChatContextBuilder.applyingStateImages(
                    snapshot.images, to: stateMessages, user: userIntent, supportsImages: await chat.supportsImages)
                stateMessages = imageProjection.messages
                ephemeralImageIDs = imageProjection.ephemeralIDs
                let contextTemplates = try AgentPrompts.stateContext()
                var block =
                    try contextTemplates.render("frame")
                    + contextTemplates.render(
                        "skillState", variables: ["state": String(decoding: snapshot.facts, as: UTF8.self)])
                if let manifest = imageProjection.manifest {
                    block += try contextTemplates.render("images", variables: ["manifest": manifest])
                }
                if let waiting = inputInteractions[input.id]?.first(where: {
                    AgentTaskMessaging.isPeer($0.scope.executor)
                }),
                    let current = decisionContext.state.taskViews?[waiting.scope.id], !current.terminal,
                    current.interactionID == waiting.interactionID
                {
                    let question = String(decoding: try JSONEncoder().encode(current.text), as: UTF8.self)
                    block += try AgentPrompts.load(named: State.configurationName).render(
                        "taskQuestion",
                        variables: ["agent": waiting.scope.executor.rawValue, "question": question])
                }
                guard block.utf8.count <= 16 * 1024 else { throw CommunicationError.capacityExceeded }
                block += try Self.peerTaskFacts(
                    from: decisionContext.state.taskViews ?? [:], dialog: decisionContext.state.history.current.id,
                    budget: min(3_072, 16 * 1024 - block.utf8.count),
                    templates: AgentPrompts.load(named: State.configurationName))
                block += try AgentStatePrompt.block(decisionContext.state.visibleVariables(session: input.sessionID))
                let system = try State.systemPrompt(
                    catalog, skills: decisionContext.state.skillState, communication: communicationPolicy)
                stateMessages.removeAll { $0.role == .system }
                stateMessages.insert(.init(role: .system, content: system), at: 0)
                // Keep the stable instructions/history prefix ahead of facts that change every request.
                // A native call/result group must remain contiguous.
                let factIndex = stateMessages.last?.role == .user ? stateMessages.count - 1 : stateMessages.count
                stateMessages.insert(.init(role: .system, content: block), at: factIndex)
                stateMessageCount += 1
            }
            let providerMessages = try AgentChatContextBuilder.retainingRecent(
                stateMessages, preservingUser: userIntent,
                protectedSuffixCount: protectedSuffixCount + stateMessageCount,
                protectedImageIDs: ephemeralImageIDs)
            let requestTools: [ChatToolDefinition] =
                await chat.supportsToolCalls
                ? try catalog.tools.compactMap { registration in
                    guard let definition = registration.definition else { return nil }
                    return try ChatToolDefinition(declaration: JSONEncoder().encode(definition))
                } : []
            let providerRequest = try ChatRequest(
                messages: providerMessages,
                context: request.context,
                maximumOutputTokens: request.maximumOutputTokens, temperature: request.temperature,
                tools: usesSkills ? requestTools : request.tools
            )
            var historyRequest = AssistantModelRequest(
                id: requestID, input: inputText,
                requestJSON: try Self.historyRequest(providerRequest.messages, imageScopes: imageScopes),
                decisionMetadata: try decisionMetadata(
                    skills: decisionContext.state.skillState, states: requestedStates),
                historyTaskID: decisionContext.state.skillState?.activeTaskID)
            // A runtime-origin input that continues a prior input is a ReACT round, not a user turn.
            if input.metadata.origin == .runtime, input.metadata.parentID != nil { historyRequest.isObservation = true }
            try await conversations.beginModelRequest(historyRequest, for: input.id, awaitingDispatch: true)
            try beginReplyTurn(input)
            var generationError: (any Error)?
            let text: String
            do {
                text = try await collect(providerRequest, input: input, invocationID: requestID, using: chat)
            } catch {
                try Task.checkCancellation()
                guard !(error is CancellationError), lifecycle == .running else { throw error }
                if fullDuplex {
                    let history = try await conversations.readCurrent()
                    if history.current.turns.first(where: { $0.id == input.id })?.modelRequests?.last?.awaitingDispatch
                        == true
                    {
                        throw error
                    }
                }
                generationError = error
                text = ""
            }
            try await conversations.finishModelRequest(
                input.id, reason: generationError == nil ? generationFinishReason : "error",
                error: generationError.map { Self.failureDescription($0) })
            try roundCoordinator?.seal()
            let completedBudget = budget
            try await contextRepository.update {
                if let completedBudget { try $0.recordBudget(completedBudget, for: input.id) }
                try $0.transitionWork(input.id, to: .awaitingFeedback)
            }
            guard let roundID, emit(.roundFinished(roundID), for: input) else { throw HarnessError.queueFull }
            if fullDuplex {
                guard pendingRounds.count < 32 else { throw HarnessError.queueFull }
                pendingRounds[roundID] = PendingRound(
                    input: input, initial: initial, text: text, userIntent: userIntent, chat: chat,
                    generationError: generationError, ordinal: currentOrdinal, budget: budget,
                    requestTaskID: decisionContext.state.skillState?.activeTaskID,
                    catalog: requestCatalog, capabilities: modelCapabilities, skillIDs: requestSkillIDs,
                    coordinator: roundCoordinator, calls: roundCalls, receipt: roundReceipt, resultBytes: resultBytes,
                    finishReason: generationFinishReason,
                    bindings: resourceBindings, imageScopes: imageScopes, imageIDs: ephemeralImageIDs,
                    language: AgentPrompts.language)
                try await publishPendingResults(roundID)
                throw RoundSuspended()
            }
            while roundReceipt == nil {
                try Task.checkCancellation()
                if let feedbackFailure { throw CapabilityError.invalidRequest(feedbackFailure) }
                try await Task.sleep(for: .milliseconds(10))
            }
            return try await completeRound(
                initial, input: input, using: chat, text: text,
                userIntent: userIntent, generationError: generationError)
        }
    }
    func completeRound(
        _ initial: ChatRequest, input: AgentInput, using chat: any ChatCapability,
        text: String, userIntent: String, generationError initialError: (any Error)?
    ) async throws -> ChatRequest? {
        var request = initial
        var generationError = initialError
        guard let completedRoundID = roundID else { throw CommunicationError.scopeClosed }
        if let failure = roundReceipt?.failure {
            guard let previous = generationError, roundCalls.allSatisfy({ $0.result != nil }) else {
                throw CapabilityError.invalidRequest(failure)
            }
            generationError = AssistantChatRoundFailure(cause: previous, cleanup: failure)
        }
        guard roundCalls.allSatisfy({ $0.result != nil }) else {
            throw CapabilityError.invalidRequest("Round sealed with missing execution feedback")
        }
        let journal = try JSONSerialization.data(
            withJSONObject: roundCalls.map { call -> [String: Any] in
                guard let result = call.result else { throw CommunicationError.invalidPayload }
                var record: [String: Any] = [
                    "callID": call.id, "path": call.path, "protocol": call.tool ? "tool" : "action",
                    "requiresReasoning": !isInternalRuntimeCall(call) && result.requiresReasoning,
                    "internal": isInternalRuntimeCall(call), "result": try Self.observationText(result),
                ]
                if let action = call.actionResult {
                    record["executionID"] = action.executionID
                    record["status"] = action.status.rawValue
                    record["effect"] = action.effect.rawValue
                }
                if let native = call.native { record["providerID"] = native.id }
                return record
            }, options: [.sortedKeys])
        try await conversations.recordGenerationRound(
            .init(id: completedRoundID, resultsJSON: String(decoding: journal, as: UTF8.self)), for: input.id)
        if let generationError { throw generationError }
        if let failed = roundCalls.first(where: { isInternalRuntimeCall($0) && $0.result?.hasFailure == true }),
            let result = failed.result,
            !roundCalls.contains(where: { !isInternalRuntimeCall($0) && $0.result?.requiresReasoning == true })
        {
            throw CapabilityError.unavailable(
                "Internal execution failed at \(failed.path): \(try Self.observationText(result))")
        }
        try await releaseDelegations(parent: input)
        if let skills = try await contextRepository.snapshot().state.skillState,
            let id = skills.activeTaskID, let task = skills.tasks.first(where: { $0.id == id }),
            task.status == "finishing"
        {
            if let failed = roundCalls.first(where: { $0.result?.hasFailure == true }), let result = failed.result {
                throw CapabilityError.invalidRequest(
                    "Task closure failed at \(failed.path): \(try Self.observationText(result))")
            }
            try await finishLocalDecision(input: input, taskBoundaryOnly: true)
            return nil
        }
        guard roundCalls.contains(where: { !isInternalRuntimeCall($0) && $0.result?.requiresReasoning == true })
        else {
            return nil
        }
        if fullDuplex {
            for (index, call) in roundCalls.enumerated()
            where !call.tool && call.modelGenerated && !call.forwarded && call.result?.requiresReasoning == true {
                try await enqueueActionResult(
                    call, input: input, chat: chat)
                roundCalls[index].forwarded = true
            }
            let tools = roundCalls.filter(\.tool)
            if tools.contains(where: { !$0.forwarded && $0.result?.requiresReasoning == true }) {
                try await enqueueNativeResults(tools, input: input, round: completedRoundID, text: text, chat: chat)
            }
            return nil
        }
        var messages = request.messages
        let native = roundCalls.compactMap(\.native)
        if !text.isEmpty || !native.isEmpty {
            messages.append(ChatMessage(role: .assistant, content: text, toolCalls: native))
        }
        for call in roundCalls where call.tool {
            guard let native = call.native, let result = call.result else {
                throw CommunicationError.invalidPayload
            }
            messages.append(
                ChatMessage(
                    role: .tool,
                    content: try AgentChatContextBuilder.nativeObservation(result, rejection: call.rejection),
                    toolCallID: native.id))
        }
        messages += try roundActionResultMessages()
        do {
            messages += try await observations(
                roundCalls.compactMap { call in
                    guard !isInternalRuntimeCall(call), let result = call.result, result.requiresReasoning else {
                        return nil
                    }
                    return AssistantChatObservation(path: call.path, result: result)
                }, input, chat)
        } catch {
            try Task.checkCancellation()
            throw error
        }
        let additions = messages.dropFirst(request.messages.count)
        roundContinuationInputText = additions.filter { $0.role != .assistant }.map(\.content).joined(
            separator: "\n")
        roundSuffixCount = max(1, additions.count)
        request = try ChatRequest(
            messages: try AgentChatContextBuilder.retainingRecent(
                messages, preservingUser: userIntent, protectedSuffixCount: roundSuffixCount),
            context: initial.context,
            maximumOutputTokens: initial.maximumOutputTokens, temperature: initial.temperature, tools: initial.tools
        )
        return request
    }
}
