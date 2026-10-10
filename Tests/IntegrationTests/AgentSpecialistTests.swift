import Actions
import AgentCore
import Agents
import AppWorkflows
import CallRuntime
import ExecutionRuntime
import Foundation
import FunctionContracts
import Gateway
import ModelKit
import StorageChat
import Testing

/// Synthetic providers and camera effects; verifies production Agent ownership, not device behavior.
private actor SpecialistModel: ChatCapability {
    nonisolated let availability: CapabilityAvailability = .available
    nonisolated let supportsToolCalls = true
    nonisolated let supportsImages = true
    let parent: Bool
    let malformedFirst: Bool
    let closeCamera: Bool
    let target: String
    let questionPhoto: UUID?
    let onRequest: @Sendable () async throws -> Void
    private(set) var requests: [ChatRequest] = []
    init(
        parent: Bool, malformedFirst: Bool = false, closeCamera: Bool = false,
        target: String = "photographer",
        questionPhoto: UUID? = nil,
        onRequest: @escaping @Sendable () async throws -> Void = {}
    ) {
        self.closeCamera = closeCamera
        self.malformedFirst = malformedFirst
        self.parent = parent
        self.target = target
        self.questionPhoto = questionPhoto
        self.onRequest = onRequest
    }
    func chat(_ request: ChatRequest) async throws -> InferenceSession<ChatEvent> {
        try await onRequest()
        requests.append(request)
        if parent { #expect(request.tools.isEmpty) }
        #expect(!request.tools.contains { $0.name == "Agent.send" })
        let pair = InferenceSession<ChatEvent>.make(limits: try StreamLimits(), estimatedBytes: { $0.estimatedBytes })
        if parent && malformedFirst && requests.count == 1 {
            try pair.emitter.yield(.text("<send target=\"photographer\" kind=\"task\" content=\"关闭摄像头\"/>"))
            try pair.emitter.yield(.finished(.stop))
            pair.emitter.finish()
            return pair.session
        }
        if requests.count == 1 || (parent && malformedFirst && requests.count == 2) {
            if parent {
                let content = malformedFirst ? "关闭摄像头" : "capture fixture"
                try pair.emitter.yield(
                    .text("<send target=\"" + target + "\" kind=\"request\" content=\"" + content + "\"/>"))
            } else if target == "photographer" && closeCamera {
                try pair.emitter.yield(.text("<closeCamera/>"))
            } else if target == "photographer" {
                try pair.emitter.yield(.text(questionPhoto == nil ? "<openCamera/><takePhoto/>" : "<takePhoto/>"))
            } else {
                try pair.emitter.yield(resultEvent(request))
            }
        } else if parent {
            if questionPhoto != nil {
                try pair.emitter.yield(
                    taskEvent(request, kind: "input", content: "save fixture", target: "photographer"))
            } else {
                try pair.emitter.yield(.text("<express emotion=\"happy\"/>"))
            }
        } else if let questionPhoto, requests.count == 2 {
            try pair.emitter.yield(
                taskEvent(
                    request, kind: "progress", content: "Save this photo?", target: "assistant", artifact: questionPhoto
                ))
        } else if let questionPhoto, requests.count == 3 {
            try pair.emitter.yield(.text("<savePhoto photoID=\"" + questionPhoto.uuidString + "\"/>"))
        } else {
            try pair.emitter.yield(resultEvent(request))
        }
        try pair.emitter.yield(.finished(.stop))
        pair.emitter.finish()
        return pair.session
    }
    private func taskEvent(_ request: ChatRequest, kind: String, content: String, target: String, artifact: UUID? = nil)
        throws -> ChatEvent
    {
        let id = String((request.messages.first?.content.components(separatedBy: "taskID=").last ?? "").prefix(36))
        guard UUID(uuidString: id) != nil else { throw CommunicationError.invalidPayload }
        var args = ["target": target, "kind": kind, "taskID": id, "content": content]
        if let artifact { args["artifactID"] = artifact.uuidString }
        let attributes = args.sorted { $0.key < $1.key }.map { "\($0.key)=\"\($0.value)\"" }.joined(separator: " ")
        return .text("<send " + attributes + "/>")
    }
    private func resultEvent(_ request: ChatRequest) throws -> ChatEvent {
        try taskEvent(request, kind: "result", content: "Completed fixture", target: "assistant")
    }

}
private actor SpecialistEffects {
    private(set) var owners: [String] = []
    private(set) var finished: Set<AgentID> = []
    func finish(_ agent: AgentID) { finished.insert(agent) }
    private(set) var failures: [String] = []
    func capture(_ owner: String) { owners.append(owner) }
    func fail(_ message: String) {
        failures.append(message)
        Issue.record("Output failed: \(message)")
    }
}
private func specialistEventually(_ predicate: @Sendable () async throws -> Bool) async throws {
    let end = ContinuousClock.now.advanced(by: .seconds(8))
    while !(try await predicate()) {
        guard ContinuousClock.now < end else { throw CommunicationError.expired }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func specialistDelegationUsesRealChildContextAndDirectedResults(_ malformedFirst: Bool) async throws {
    let parentModel = SpecialistModel(parent: true, malformedFirst: malformedFirst)
    let childModel = SpecialistModel(parent: false, closeCamera: malformedFirst)
    let parentContext = AgentContextRepository(agent: AgentID.assistant, scope: UUID(), state: AssistantContextState())
    let childContext = AgentContextRepository(
        agent: AgentID.photographer, scope: UUID(), state: PhotographerContextState())
    let parent = try AssistantAgent(chat: parentModel, context: parentContext)
    let cameraSession = UUID()
    let child = try PhotographerAgent(
        sessionID: cameraSession, context: childContext, chat: childModel,
        photoObservation: { id, _ in try ChatImage(id: id, data: Data([1])) })
    let manager = AgentManager()
    let policy = try CommunicationPolicy(
        contracts: AgentContracts.communication,
        externalSources: [
            "user", "runtime", "phone.microphone", "phone.camera", "model.resources", "app.resources",
            "app.environment",
        ],
        configurations: AgentConfigurations.all())
    let input = InputGateway(manager: manager, policy: policy, allowsExternalSend: true)
    let effects = SpecialistEffects()
    let photoID = UUID()
    let definition = ActionBinding(
        path: .init(domain: "Camera", module: "Capture", function: "takePhoto"),
        displayName: "Synthetic capture", kind: .finite, completion: "Synthetic capture receipt.",
        feedbackPolicy: .observation,
        completing: { invocation in
            #expect(await effects.owners == ["photographer"])
            await effects.capture(invocation.context.source)
            #expect(invocation.context.taskExecutor == "photographer")
            return .value(
                String(
                    decoding: try JSONEncoder().encode(CameraPhotoReceipt(photoID: photoID, width: 1, height: 1)),
                    as: UTF8.self))
        })
    let open = ActionBinding(
        path: .init(domain: "Camera", module: "Capture", function: "open"),
        displayName: "Synthetic open", kind: .finite, completion: "Native open acknowledged.",
        feedbackPolicy: .observation,
        completing: { invocation in
            #expect(invocation.context.taskExecutor == "photographer")
            await effects.capture(invocation.context.source)
            try await child.receive(
                CameraStateObservation(
                    sequence: 2, enabled: true, visible: true,
                    busy: false, needsSettings: false, facing: .back
                ).input(sessionID: cameraSession))
            return .value("{\"operation\":\"open\",\"enabled\":true}")
        })
    let close = ActionBinding(
        path: .init(domain: "Camera", module: "Capture", function: "close"),
        displayName: "Synthetic close", kind: .finite, completion: "Synthetic camera cleanup.",
        protocols: [.action, .tool],
        executionPolicy: .direct, directResultPolicy: .returning,
        completing: { invocation in
            await effects.capture(invocation.context.source)
            #expect(invocation.context.taskExecutor == "photographer")
            return .value("camera closed")
        })
    let reply = ActionBinding(
        path: .init(domain: "UI", module: "Expression", function: "express"),
        displayName: "Synthetic expression", kind: .finite, completion: "Synthetic UI.", completing: { _ in .completed }
    )
    let scheduler = ChannelScheduler(registry: try ActionRegistry(definitions: [definition, reply, close, open])) {
        await input.deliverActionResult($0)
    }
    let gateway = OutputGateway(
        manager: manager, requests: input, tools: try ToolRegistry(modules: [SpecialistTools(definitions: [close])]),
        actions: scheduler,
        policy: policy, sink: { _ in })
    for agent in [parent as any Agent, child as any Agent] {
        try await manager.register(agent)
        try await agent.start()
    }
    let pumps = [parent as any Agent, child as any Agent].map { agent in
        Task {
            do {
                let consumer = try await gateway.consumer(for: agent)
                try await IndependentOutputWorkflow.consumeGeneration(agent.outputs) { envelope in
                    let outcome = try await consumer.execute(envelope)
                    if case .control("agent.finished") = envelope.output { await effects.finish(envelope.source) }
                    if let failure = outcome.failure { await effects.fail(failure) }
                }
            } catch is CancellationError {} catch { await effects.fail(String(describing: error)) }
        }
    }
    do {
        try await input.publish(
            CameraStateObservation(
                sequence: 1, enabled: false, visible: false,
                busy: false, needsSettings: false, facing: .back
            ).input(sessionID: cameraSession))
        await input.flushPublications()
        #expect(try await childContext.snapshot().state.cameraState?.sequence == 1)
        let root = AgentInput(
            sessionID: UUID(), payload: .text(malformedFirst ? "关闭摄像头" : "private parent conversation"))
        let receipt = try await input.send(root, to: .assistant)
        #expect(receipt.delivered == [.assistant])
        try await specialistEventually {
            let views = try await parentContext.snapshot().state.taskViews ?? [:]
            let childSnapshot = try await childContext.snapshot()
            let finished = await effects.finished
            return views.count == 1 && views.values.allSatisfy(\.terminal) && finished.count == 2
                && childSnapshot.state.history.current.turns.first?.state == .completed
        }
        #expect(await effects.owners == (malformedFirst ? ["photographer"] : ["photographer", "photographer"]))
        if malformedFirst {
            let requests = await parentModel.requests
            #expect(requests.count == 2)
            #expect(requests[1].messages.contains { $0.content.contains("communicationRejected") })
        }
        #expect(await effects.failures == [])
        #expect(await childModel.requests.count == 2)
        let childRequests = await childModel.requests
        let firstFacts = try #require(childRequests.first?.messages.last?.content)
        #expect(firstFacts.contains("Current photography state"))
        #expect(firstFacts.contains("\"enabled\":false"))
        if !malformedFirst {
            let nextFacts = try #require(childRequests.last?.messages.last?.content)
            #expect(nextFacts.contains("\"enabled\":true"))
            #expect(nextFacts.contains("\"phase\":\"reviewingPhoto\""))
            #expect(nextFacts.contains("\"sequence\":2"))
        }
        #expect(
            childRequests.last?.messages.contains {
                $0.content.contains(malformedFirst ? "camera closed" : photoID.uuidString)
            } == true)
        #expect(
            childRequests.allSatisfy { !$0.messages.contains { $0.content.contains("private parent conversation") } })
        let storedParent = try await parentContext.snapshot()
        let storedChild = try await childContext.snapshot()
        #expect(storedParent.state.history.current.turns.count == 1)
        #expect(storedChild.state.history.current.turns.count == 1)
        #expect(storedParent.records.allSatisfy { $0.kind != "action.result" })
        #expect((storedChild.state.photoOwners?[photoID] != nil) == !malformedFirst)
        #expect(storedParent.state.taskViews?.values.first?.scope.executor == .photographer)
        var trace = try await input.observeSignals().makeAsyncIterator()
        let observations = try #require(await trace.next()).records
        #expect(observations.contains { $0.task?.kind == .request && $0.mode == .send && $0.phase == .accepted })
        #expect(
            observations.contains {
                $0.task?.kind == .result && $0.phase == .accepted && $0.branches.first?.target == .assistant
            })
        let feedback = observations.filter {
            ($0.contract == "tool.result" || $0.contract == "action.result") && $0.taskScope?.executor == .photographer
        }
        #expect(!feedback.isEmpty)
        #expect(feedback.allSatisfy { $0.mode == .feedback && $0.branches.allSatisfy { $0.target == .photographer } })
        var taskTrace = try await input.observeTasks().makeAsyncIterator()
        let beforeNoise = try #require(await taskTrace.next())
        #expect(!beforeNoise.records.isEmpty && beforeNoise.records.allSatisfy { $0.task != nil })
        for _ in 0..<300 {
            try await input.publish(
                .init(sessionID: UUID(), payload: .observation(.transcript("partial", final: false))))
        }
        await input.flushPublications()
        var afterNoiseTrace = try await input.observeTasks().makeAsyncIterator()
        let afterNoise = try #require(await afterNoiseTrace.next())
        #expect(afterNoise.revision == beforeNoise.revision)
        #expect(afterNoise.records.map(\.id) == beforeNoise.records.map(\.id))
        #expect(afterNoise.evictedCount == beforeNoise.evictedCount)

    } catch {
        Issue.record(
            "Parent: \(try await parentContext.snapshot().state.taskViews ?? [:]); requests: \(await parentModel.requests.count); failures: \(await effects.failures)"
        )
        await manager.stopAll()
        await gateway.shutdown()
        for pump in pumps {
            pump.cancel()
            await pump.value
        }
        throw error
    }
    await manager.stopAll()
    await gateway.shutdown()
    for pump in pumps {
        pump.cancel()
        await pump.value
    }
}

@Test func specialistContextMigrationRejectsPartialAndUnsupportedChatFields() throws {
    let legacy = Data("{\"pendingRequestIDs\":[]}".utf8)
    let migrated = try JSONDecoder().decode(MemoryContextState.self, from: legacy)
    #expect(migrated.history.current.turns.isEmpty)
    #expect(throws: (any Error).self) {
        try JSONDecoder().decode(
            MemoryContextState.self, from: Data("{\"pendingRequestIDs\":[],\"history\":null}".utf8))
    }
    #expect(throws: (any Error).self) {
        try JSONDecoder().decode(
            MemoryContextState.self, from: Data("{\"pendingRequestIDs\":[],\"chatSchemaVersion\":99}".utf8))
    }
    let roundTrip = try JSONDecoder().decode(MemoryContextState.self, from: JSONEncoder().encode(migrated))
    #expect(roundTrip.chatSchemaVersion == 1)
}

@Test(.timeLimit(.minutes(1)))
func specialistMemoryStartsAfterParentEvidenceCommit() async throws {
    let context = AgentContextRepository(agent: AgentID.assistant, scope: UUID(), state: AssistantContextState())
    let childContext = AgentContextRepository(agent: AgentID.memory, scope: UUID(), state: MemoryContextState())
    let parentModel = SpecialistModel(parent: true, target: "memory")
    let childModel = SpecialistModel(
        parent: false, target: "memory",
        onRequest: {
            let evidence = try await context.snapshot().state.history.current.turns.first?.modelRequests?.first
            #expect(evidence?.state == .completed)
            #expect(evidence?.toolCalls.isEmpty == true)
            #expect(evidence?.fragments.joined().contains("<send") == true)
        })
    let parent = try AssistantAgent(chat: parentModel, context: context)
    let child = try MemoryAgent(sessionID: UUID(), context: childContext, chat: childModel)
    let manager = AgentManager()
    let policy = try CommunicationPolicy(
        contracts: AgentContracts.communication,
        externalSources: [
            "user", "runtime", "phone.microphone", "phone.camera", "model.resources", "app.resources",
            "app.environment",
        ],
        configurations: AgentConfigurations.all())
    let input = InputGateway(manager: manager, policy: policy, allowsExternalSend: true)
    let effects = SpecialistEffects()
    let reply = ActionBinding(
        path: .init(domain: "UI", module: "Expression", function: "express"),
        displayName: "Synthetic expression", kind: .finite, completion: "Synthetic UI.", completing: { _ in .completed }
    )
    let scheduler = ChannelScheduler(registry: try ActionRegistry(definitions: [reply])) {
        await input.deliverActionResult($0)
    }
    let gateway = OutputGateway(
        manager: manager, requests: input, tools: ToolRegistry(), actions: scheduler, policy: policy, sink: { _ in })
    let agents: [any Agent] = [parent, child]
    for agent in agents {
        try await manager.register(agent)
        try await agent.start()
    }
    let pumps = agents.map { agent in
        Task {
            do {
                let consumer = try await gateway.consumer(for: agent)
                try await IndependentOutputWorkflow.consumeGeneration(agent.outputs) {
                    let result = try await consumer.execute($0)
                    if case .control("agent.finished") = $0.output { await effects.finish($0.source) }
                    if let failure = result.failure { await effects.fail(failure) }
                }
            } catch is CancellationError {} catch { await effects.fail(String(describing: error)) }
        }
    }
    do {
        _ = try await input.send(AgentInput(sessionID: UUID(), payload: .text("read history")), to: .assistant)
        try await specialistEventually {
            let views = try await context.snapshot().state.taskViews ?? [:]
            let finished = await effects.finished
            return views.count == 1 && views.values.allSatisfy(\.terminal) && finished.count == 2
        }
        #expect(await childModel.requests.count == 1)
        #expect(await effects.failures == [])
        #expect(try await childContext.snapshot().state.history.current.turns.count == 1)
    } catch {
        await manager.stopAll()
        await gateway.shutdown()
        for pump in pumps {
            pump.cancel()
            await pump.value
        }
        throw error
    }
    await manager.stopAll()
    await gateway.shutdown()
    for pump in pumps {
        pump.cancel()
        await pump.value
    }
}

private struct SpecialistTools: ToolModule { let definitions: [ActionBinding] }
@Test(.timeLimit(.minutes(1)))
func specialistTypedUIBypassesAssistantAndCompletesWithoutModels() async throws {
    let session = UUID()
    let manager = AgentManager()
    let policy = try CommunicationPolicy(
        contracts: AgentContracts.communication,
        externalSources: [
            "user", "runtime", "phone.microphone", "phone.camera", "model.resources", "app.resources",
            "app.environment",
        ],
        configurations: AgentConfigurations.all())
    let input = InputGateway(manager: manager, policy: policy, allowsExternalSend: true)
    let effects = SpecialistEffects()
    let definition = ActionBinding(
        path: .init(domain: "Camera", module: "Capture", function: "open"),
        displayName: "Synthetic open", kind: .finite, completion: "Synthetic camera.", protocols: [.tool],
        executionPolicy: .direct, directResultPolicy: .returning,
        completing: { invocation in
            await effects.capture(invocation.context.source)
            return .completed
        })
    let gateway = OutputGateway(
        manager: manager, requests: input,
        tools: try ToolRegistry(modules: [SpecialistTools(definitions: [definition])]),
        actions: ChannelScheduler(registry: ActionRegistry()), policy: policy, sink: { _ in })
    let repository = AgentContextRepository(agent: AgentID.assistant, scope: UUID(), state: AssistantContextState())
    let parent = try AssistantAgent(context: repository)
    let camera = PhotographerIntentRuntime(
        sessionID: session, manager: manager, input: input, output: gateway,
        agent: try PhotographerAgent(sessionID: session), report: { await effects.fail($0) })
    let root = AgentInteractionRuntime(
        agent: parent, manager: manager, input: input, output: gateway,
        startChildren: { try await camera.prepareForInteraction() }, report: { await effects.fail($0) },
        inputRejected: { await camera.rejectInput($0, reason: $1) })
    try await root.start()
    let operation = Task { try await camera.perform(.open) }
    do {
        try await operation.value
        #expect(await effects.owners == ["photographer"])
        let state = try await repository.snapshot().state
        #expect(state.history.current.turns.isEmpty)
        #expect(state.taskViews?.isEmpty != false)
        var observation = try await input.observeSignals().makeAsyncIterator()
        let signals = try #require(await observation.next()).records
        #expect(
            signals.contains { $0.contract == "photography.camera" && $0.branches.map(\.target) == [.photographer] })
        #expect(!signals.contains { $0.task?.kind == .request })
        #expect(await effects.failures == [])
    } catch {
        Issue.record(
            "UI routing: \(try await repository.snapshot().state.taskViews ?? [:]); effects: \(await effects.owners); executions: \(await gateway.executionResults())"
        )
        operation.cancel()
        await root.shutdown()
        await camera.shutdown()
        await gateway.shutdown()
        throw error
    }
    await root.shutdown()
    await camera.shutdown()
    await gateway.shutdown()
}

private actor SpecialistSpeech: Agent {
    nonisolated let descriptor = AgentDescriptor(
        id: AgentID(rawValue: "speechSynthesis"), name: "Synthetic synthesis", inputs: [.observation], outputs: [])
    nonisolated let outputs = AsyncStream<OutputEnvelope> { $0.finish() }
    private(set) var requests = 0
    func start() {}
    func pause() {}
    func resume() {}
    func stop() {}
    func receive(_ input: AgentInput) throws {
        guard case .observation(let message) = input.payload, case .speechSynthesis? = message.perception else {
            throw CommunicationError.invalidPayload
        }
        requests += 1
    }
    func status() -> AgentStatus { .init(lifecycle: .running, queuedInputs: 0, processedInputs: requests) }
}

@Test(.timeLimit(.minutes(1)))
func specialistQuestionUsesFixedActivationAndForwardsNextUserAnswer() async throws {
    let photoID = UUID()
    let parentModel = SpecialistModel(parent: true, questionPhoto: photoID)
    let childModel = SpecialistModel(parent: false, questionPhoto: photoID)
    let parentContext = AgentContextRepository(agent: AgentID.assistant, scope: UUID(), state: AssistantContextState())
    let childContext = AgentContextRepository(
        agent: AgentID.photographer, scope: UUID(), state: PhotographerContextState())
    let parent = try AssistantAgent(chat: parentModel, context: parentContext)
    let child = try PhotographerAgent(
        sessionID: UUID(), context: childContext, chat: childModel,
        photoObservation: { id, _ in try ChatImage(id: id, data: Data([1])) })
    let speech = SpecialistSpeech()
    let manager = AgentManager()
    let policy = try CommunicationPolicy(
        contracts: AgentContracts.communication,
        externalSources: [
            "user", "runtime", "phone.microphone", "phone.camera", "model.resources", "app.resources",
            "app.environment",
        ],
        configurations: AgentConfigurations.all())
    let input = InputGateway(manager: manager, policy: policy, allowsExternalSend: true)
    let effects = SpecialistEffects()
    let paths = ["Camera.Capture.takePhoto", "Camera.Capture.savePhoto", "UI.Caption.print", "Speech.Playback.speak"]
    let definitions = paths.map { path -> ActionBinding in
        let parts = path.split(separator: ".").map(String.init)
        return ActionBinding(
            path: .init(domain: parts[0], module: parts[1], function: parts[2]),
            displayName: path, kind: .finite, completion: "Synthetic effect.",
            feedbackPolicy: path.hasPrefix("Camera") ? .observation : .recordOnly,
            completing: { invocation in
                if path.hasPrefix("Camera") {
                    await effects.capture(invocation.context.source)
                    #expect(invocation.context.taskExecutor == "photographer")
                    if path.hasSuffix("takePhoto") {
                        return .value(
                            String(
                                decoding: try JSONEncoder().encode(
                                    CameraPhotoReceipt(photoID: photoID, width: 1, height: 1)), as: UTF8.self))
                    }
                    #expect(invocation.call.parameters["photoID"] == photoID.uuidString)
                    return .value(
                        String(
                            decoding: try JSONEncoder().encode(
                                CameraPhotoCommandReceipt(photoID: photoID, state: .saved)), as: UTF8.self))
                }
                return .completed
            })
    }
    let scheduler = ChannelScheduler(registry: try ActionRegistry(definitions: definitions)) {
        await input.deliverActionResult($0)
    }
    let gateway = OutputGateway(
        manager: manager, requests: input, tools: ToolRegistry(), actions: scheduler, policy: policy, sink: { _ in })
    for agent in [parent as any Agent, child as any Agent, speech as any Agent] {
        try await manager.register(agent)
        try await agent.start()
    }
    let pumps = [parent as any Agent, child as any Agent].map { agent in
        Task {
            do {
                let consumer = try await gateway.consumer(for: agent)
                try await IndependentOutputWorkflow.consumeGeneration(agent.outputs) { envelope in
                    let result = try await consumer.execute(envelope)
                    if case .control("agent.finished") = envelope.output { await effects.finish(envelope.source) }
                    if let failure = result.failure { await effects.fail(failure) }
                }
            } catch is CancellationError {} catch { await effects.fail(String(describing: error)) }
        }
    }
    do {
        let session = UUID()
        _ = try await input.send(AgentInput(sessionID: session, payload: .text("photo")), to: .assistant)
        try await specialistEventually { await speech.requests == 1 }
        #expect(await childModel.requests.count == 2)
        #expect(await parentModel.requests.count == 1)
        let view = try #require(try await parentContext.snapshot().state.taskViews?.values.first)
        #expect(view.stage == .waitingUser && view.artifactID == photoID && !view.terminal)
        let cameraRequest = try #require(await childModel.requests.first)
        #expect(cameraRequest.messages.first?.content.contains("Active task: taskID=\(view.scope.id)") == true)
        let observationRequest = try #require(await childModel.requests.last)
        #expect(
            observationRequest.messages.contains {
                $0.content.contains("kind=\"progress\"") && $0.content.contains("artifactID=\"\(photoID)\"")
            })
        let stale = try AgentTaskInputIntent(
            taskID: view.scope.id, interactionID: UUID(), artifactID: photoID, text: "save")
        let rejected = try await input.send(stale.input(sessionID: session), to: .assistant)
        #expect(rejected.delivered.isEmpty && rejected.rejected[.assistant] != nil)
        _ = try await input.send(AgentInput(sessionID: session, payload: .text("save")), to: .assistant)
        try await specialistEventually {
            let views = try await parentContext.snapshot().state.taskViews ?? [:]
            let history = try await childContext.snapshot().state.history.current
            return views.values.allSatisfy(\.terminal) && history.turns.filter { $0.state == .completed }.count == 2
        }
        #expect(await childModel.requests.count == 4)
        #expect(await parentModel.requests.count == 2)
        #expect(await parentModel.requests.last?.messages.first?.content.contains("status=running") == true)
        #expect(await effects.owners == ["photographer", "photographer"])
        #expect(await effects.failures == [])
    } catch {
        Issue.record(
            "Question routing: \(try await parentContext.snapshot().state.taskViews ?? [:]); errors: \(await effects.failures)"
        )
        for pump in pumps {
            pump.cancel()
            await pump.value
        }
        await manager.stopAll()
        await gateway.shutdown()
        throw error
    }
    for pump in pumps {
        pump.cancel()
        await pump.value
    }
    await manager.stopAll()
    await gateway.shutdown()
}

private actor SpecialistPendingModel: ChatCapability {
    nonisolated let availability: CapabilityAvailability = .available
    private(set) var requests = 0
    private var emitter: InferenceEmitter<ChatEvent>?
    func chat(_ request: ChatRequest) throws -> InferenceSession<ChatEvent> {
        requests += 1
        let pair = InferenceSession<ChatEvent>.make(limits: try StreamLimits(), estimatedBytes: { $0.estimatedBytes })
        emitter = pair.emitter
        return pair.session
    }
}

@Test(.timeLimit(.minutes(1))) func specialistPauseJoinsInferenceWhenChildCancellationDeliveryFails() async throws {
    let context = AgentContextRepository(agent: .assistant, scope: UUID(), state: AssistantContextState())
    let model = SpecialistPendingModel()
    let failing = try AssistantAgent(chat: model, context: context)
    try await failing.bind(
        AgentMessaging { _, _, target in
            DeliveryReport(rejected: target.map { [$0: "Target unavailable"] } ?? [:])
        })
    try await failing.start()
    let session = UUID()
    let scope = AgentTaskScope(requester: .assistant, executor: .photographer, sessionID: session)
    try await context.update {
        try $0.tasks.register(scope)
        $0.state.taskViews = [scope.id: AgentTaskView(scope: scope, content: try AgentTaskContent(text: "In progress"))]
    }
    let input = AgentInput(sessionID: session, payload: .text("pending inference"))
    try await failing.receive(input)
    try await specialistEventually { await model.requests == 1 }
    await #expect(throws: CommunicationError.unavailableTarget) { try await failing.pause() }
    #expect(await failing.status().lifecycle == .paused)
    #expect(await failing.status().queuedInputs == 0)
    #expect(try await context.snapshot().state.history.current.turns.first?.state == .cancelled)
    await failing.stop()
}

private actor ReplyActivityProbe {
    var values: [ReplyActivity] = []
    var listeningCalls = 0
    func record(_ output: AgentOutput) {
        if case .communication(let action) = output,
            let activity = action.message.content(as: ReplyActivity.self)
        {
            values.append(activity)
        }
        if case .actionCall(let call) = output, call.actionPath.description == "Speech.Listening.update" {
            listeningCalls += 1
        }
    }
}

@Test(.timeLimit(.minutes(1)))
func assistantReportsReplyActivityWithoutOwningListening() async throws {
    let session = UUID()
    let root = try AssistantAgent(reportsReplyActivity: true, chat: FixedTextChat(text: ""))
    try await root.start()
    let probe = ReplyActivityProbe()
    let pump = Task { for await envelope in root.outputs { await probe.record(envelope.output) } }
    await #expect(throws: (any Error).self) { try await root.receive(ListeningIntent().input(sessionID: session)) }
    try await root.receive(AgentInput(sessionID: session, payload: .text("hello")))
    try await specialistEventually {
        let values = await probe.values
        return values.contains { !$0.inputs.isEmpty } && values.last?.inputs.isEmpty == true
    }
    let values = await probe.values
    #expect(values.contains { !$0.inputs.isEmpty })
    #expect(values.last?.inputs.isEmpty == true)
    #expect(await probe.listeningCalls == 0)
    await root.stop()
    await pump.value
}

@Test(.timeLimit(.minutes(1))) func assistantExecutesRobotActionWithoutDelegation() async throws {
    let context = AgentContextRepository(agent: AgentID.assistant, scope: UUID(), state: AssistantContextState())
    let assistant = try AssistantAgent(chat: FixedTextChat(text: "<dance cycles=\"1\"/>"), context: context)
    let manager = AgentManager()
    let policy = try CommunicationPolicy(
        contracts: AgentContracts.communication,
        externalSources: [
            "user", "runtime", "phone.microphone", "phone.camera", "model.resources", "app.resources",
            "app.environment",
        ],
        configurations: AgentConfigurations.all())
    let input = InputGateway(manager: manager, policy: policy)
    let resource = ResourceID(rawValue: "nexarm.motor.1")
    let resources = try ResourceCoordinator(definitions: [
        ResourceDefinition(
            id: resource, allowedOwners: [.assistant, .applicationControl, .photographer],
            executionGroup: ResourceID(rawValue: "nexarm.writer"),
            preempts: [.assistant: [.photographer], .applicationControl: [.photographer]]
        ) {}
    ])
    let effects = SpecialistEffects()
    let binding = ActionBinding(
        path: .init(domain: "NexArm", module: "Gesture", function: "dance"),
        displayName: "Synthetic dance", kind: .finite, completion: "Synthetic effect.", resources: [resource],
        completing: { invocation in
            #expect(ResourceExecutionContext.owner?.agent == .assistant)
            await effects.capture(invocation.context.source)
            return .completed
        })
    let scheduler = ChannelScheduler(registry: try ActionRegistry(definitions: [binding]), resources: resources) {
        await input.deliverActionResult($0)
    }
    let gateway = OutputGateway(
        manager: manager, requests: input, tools: ToolRegistry(), actions: scheduler, policy: policy, sink: { _ in })
    try await manager.register(assistant)
    try await assistant.start()
    let consumer = try await gateway.consumer(for: assistant)
    let pump = Task {
        do {
            try await IndependentOutputWorkflow.consumeGeneration(assistant.outputs) { envelope in
                let result = try await consumer.execute(envelope)
                if case .control("agent.finished") = envelope.output { await effects.finish(envelope.source) }
                if let failure = result.failure { await effects.fail(failure) }
            }
        } catch is CancellationError {} catch { await effects.fail(String(describing: error)) }
    }
    do {
        try await input.publish(.init(sessionID: UUID(), payload: .text("跳舞")))
        try await specialistEventually { await effects.finished.contains(.assistant) }
        #expect(await effects.owners == ["assistant"])
        #expect(await effects.failures.isEmpty)
        let snapshot = try await context.snapshot()
        #expect(snapshot.state.taskViews?.isEmpty != false)
        #expect(snapshot.records.contains { $0.kind == "action.result" })
        var observations = try await input.observeSignals().makeAsyncIterator()
        let signals = try #require(await observations.next()).records
        #expect(!signals.contains { $0.task?.kind == .request })
        #expect(signals.contains { $0.contract == "action.result" && $0.branches.first?.target == .assistant })
    } catch {
        await manager.stopAll()
        await gateway.shutdown()
        pump.cancel()
        await pump.value
        throw error
    }
    await manager.stopAll()
    await gateway.shutdown()
    await pump.value
}

@Test(.timeLimit(.minutes(1))) func interactionSceneChangeWaitsForChildRegistration() async throws {
    let manager = AgentManager()
    let input = InputGateway(manager: manager)
    let gateway = OutputGateway(
        manager: manager, requests: input, tools: ToolRegistry(), actions: ChannelScheduler(registry: ActionRegistry()),
        sink: { _ in })
    let parent = try AssistantAgent()
    let child = try PhotographerAgent(sessionID: UUID())
    let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    let release = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    let runtime = AgentInteractionRuntime(
        agent: parent, manager: manager, input: input, output: gateway,
        startChildren: {
            entered.continuation.yield(())
            var iterator = release.stream.makeAsyncIterator()
            _ = await iterator.next()
            try await manager.register(child)
            try await child.start()
        })
    let transition = Task { try await runtime.setForeground(false) }
    var iterator = entered.stream.makeAsyncIterator()
    _ = await iterator.next()
    #expect(await manager.descriptors().map(\.id) == [.assistant])
    release.continuation.yield(())
    release.continuation.finish()
    try await transition.value
    #expect(await parent.status().lifecycle == .paused)
    #expect(await child.status().lifecycle == .paused)
    try await runtime.setForeground(true)
    #expect(await parent.status().lifecycle == .running)
    #expect(await child.status().lifecycle == .running)
    await runtime.shutdown()
    await manager.stopAll()
    await gateway.shutdown()
}

@Test func photographerCameraFactsArePassiveRevisionedAndScoped() async throws {
    let session = UUID()
    let agent = try PhotographerAgent(sessionID: session)
    try await agent.start()
    let first = CameraStateObservation(
        sequence: 1, enabled: true, visible: true, busy: false,
        needsSettings: false, facing: .front)
    try await agent.receive(first.input(sessionID: session))
    #expect(try await agent.contextSnapshot().state.cameraState == first)
    try await agent.pause()
    let second = CameraStateObservation(
        sequence: 3, enabled: false, visible: false, busy: false,
        needsSettings: true, facing: .back, failure: "permission denied")
    try await agent.receive(second.input(sessionID: session))
    await #expect(throws: CommunicationError.outOfOrder) { try await agent.receive(first.input(sessionID: session)) }
    await #expect(throws: CommunicationError.unauthorized) { try await agent.receive(second.input(sessionID: UUID())) }
    let payload = InputPayload.observation(second.message)
    let forged = AgentInput(
        sessionID: session, payload: payload,
        metadata: InputMetadata(payload: payload, source: "user", sequence: 3))
    await #expect(throws: CommunicationError.unauthorized) { try await agent.receive(forged) }
    let mismatched = AgentInput(
        sessionID: session, payload: payload,
        metadata: InputMetadata(payload: payload, source: CameraStateObservation.source, sequence: 4))
    await #expect(throws: CommunicationError.invalidPayload) { try await agent.receive(mismatched) }
    let expired = AgentInput(
        sessionID: session, payload: payload,
        metadata: InputMetadata(
            payload: payload, source: CameraStateObservation.source, sequence: 3,
            deadline: .now.advanced(by: .seconds(-1))))
    await #expect(throws: CommunicationError.expired) { try await agent.receive(expired) }
    let snapshot = try await agent.contextSnapshot()
    #expect(snapshot.state.cameraState == second)
    #expect(snapshot.state.history.current.turns.isEmpty)
    #expect(snapshot.work.isEmpty && snapshot.records.isEmpty)
    #expect(await agent.status().processedInputs == 2)
    var recovered = try JSONDecoder().decode(PhotographerContextState.self, from: JSONEncoder().encode(snapshot.state))
    recovered.recoverInterruptedWork()
    #expect(recovered.cameraState == nil)
    #expect(throws: CommunicationError.invalidPayload) {
        try CameraStateObservation(
            sequence: 0, enabled: true, visible: true, busy: false,
            needsSettings: false, facing: .front
        ).message.validatedSize()
    }
    #expect(throws: CommunicationError.invalidPayload) {
        try CameraStateObservation(
            sequence: 1, enabled: true, visible: true, busy: false,
            needsSettings: false, facing: .front, failure: String(repeating: "x", count: 513)
        ).message.validatedSize()
    }
    await agent.stop()
}

@Test func photographerPhaseProjectsExistingTaskAndArtifactState() throws {
    let task = AgentTaskScope(requester: .assistant, executor: .photographer, sessionID: UUID())
    let input = AgentInput(sessionID: task.sessionID, payload: .text("photo"), taskScope: task)
    var context = AgentContext(agentID: .photographer, scopeID: UUID(), state: PhotographerContextState())
    try context.tasks.register(task)
    try context.beginWork(input.id, sessionID: input.sessionID)
    #expect(PhotographerContextState.phase(context, input: input) == .preparing)
    try context.transitionWork(input.id, to: .running)
    try context.transitionWork(input.id, to: .awaitingFeedback)
    #expect(PhotographerContextState.phase(context, input: input) == .awaitingFeedback)
    try context.transitionWork(input.id, to: .continuation)
    let photo = UUID()
    try context.append(.init(taskID: task.id, kind: "user.text", data: JSONEncoder().encode(SignalEvidence(input))))
    context.state.photoOwners = [photo: input.id]
    #expect(PhotographerContextState.phase(context, input: input) == .reviewingPhoto)
    context.state.taskViews = [
        task.id: AgentTaskView(
            scope: task,
            content: try AgentTaskContent(text: "Save?", stage: .waitingUser, interactionID: UUID(), artifactID: photo))
    ]
    #expect(PhotographerContextState.phase(context, input: input) == .waitingUser)
    let failed = try AgentTaskContent(text: "failure").signal(.result, scope: task, status: .failed)
    try context.tasks.report(failed, agent: .photographer)
    #expect(PhotographerContextState.phase(context, input: input) == .failed)
    let messages = try PhotographerContextState.decisionContextMessages(context, input: input)
    #expect(messages[0].content.contains("absent camera means unknown"))
    #expect(messages[0].content.contains(task.id.uuidString))
}
