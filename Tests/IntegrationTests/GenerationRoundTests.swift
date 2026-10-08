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
import Storage
import StorageChat
import Testing

private actor RoundModel: ChatCapability {
    let availability: CapabilityAvailability = .available
    let supportsToolCalls: Bool
    let action: Bool
    let toolCount: Int
    let photo: Bool
    let photoCommand: String?
    let supportsImages: Bool
    private(set) var requests: [ChatRequest] = []
    init(action: Bool, toolCount: Int, photo: Bool = false, supportsImages: Bool = false, photoCommand: String? = nil) {
        self.photoCommand = photoCommand
        self.action = action
        self.photo = photo
        self.supportsImages = supportsImages
        self.toolCount = toolCount
        supportsToolCalls = toolCount > 0
    }
    func chat(_ request: ChatRequest) throws -> InferenceSession<ChatEvent> {
        requests.append(request)
        let pair = InferenceSession<ChatEvent>.make(limits: try StreamLimits(), estimatedBytes: { $0.estimatedBytes })
        if requests.count == 1 {
            if photo { try pair.emitter.yield(.text("<takePhoto/>")) }
            if let photoCommand { try pair.emitter.yield(.text("<" + photoCommand + "/>")) }
            if action { try pair.emitter.yield(.text("<wait><express emotion=\"happy\"/></wait>")) }
            for index in 0..<toolCount {
                try pair.emitter.yield(
                    .toolCall(.init(id: "native-\(index)", name: "runtimeInfo", argumentsJSON: "{}")))
            }
            try pair.emitter.yield(.finished(toolCount == 0 ? .stop : .toolCalls))
        } else {
            try pair.emitter.yield(.text("已观察真实结果。"))
            try pair.emitter.yield(.finished(.stop))
        }
        pair.emitter.finish()
        return pair.session
    }
}

private struct RoundTools: ToolModule { let definitions: [ActionBinding] }
private enum RoundFailure: Error { case expected }
private actor RoundLog {
    private(set) var outputs: [OutputEnvelope] = []
    private(set) var failures: [String] = []
    func record(_ output: OutputEnvelope, result: OutputExecutionResult) {
        outputs.append(output)
        if let failure = result.failure { failures.append(failure) }
    }
}
private struct RoundHarness {
    let agent: AssistantAgent
    let model: RoundModel
    let store: ConversationHistoryStore
    let gateway: OutputGateway
    let scheduler: ChannelScheduler
    let manager: AgentManager
    let log: RoundLog
    func start(_ input: AgentInput) async throws -> Task<Void, any Error> {
        try await agent.start()
        try await agent.receive(input)
        return Task {
            try await IndependentOutputWorkflow.consumeGeneration(agent.outputs) { envelope in
                let result = try await gateway.execute(envelope)
                await log.record(envelope, result: result)
                if case .control(let value) = envelope.output,
                    value == "assistant.finished" || value.hasPrefix("assistant.error:")
                {
                    await agent.stop()
                }
            }
        }
    }
    func close() async {
        await gateway.shutdown()
        await manager.stopAll()
    }
}
private func roundHarness(
    action: Bool, toolCount: Int, observeAction: Bool, observeTool: Bool,
    deliverActionFeedback: Bool = true, photo: Bool = false, supportsImages: Bool = false, photoCommand: String? = nil,
    photoObservation: (@Sendable (UUID, AgentInput) async throws -> ChatImage)? = nil,
    handler: @escaping ActionCompletionHandler
) async throws -> RoundHarness {
    let model = RoundModel(
        action: action, toolCount: toolCount, photo: photo, supportsImages: supportsImages, photoCommand: photoCommand)
    let store = ConversationHistoryStore()
    let actionPolicies: [String: GenerationFeedbackPolicy] = [
        "UI.Expression.express": observeAction ? .observation : .recordOnly,
        "UI.Caption.print": .recordOnly, "UI.Caption.beginReplyTurn": .recordOnly,
        "Speech.Playback.speak": .recordOnly, "Camera.Capture.takePhoto": .observation,
        "Camera.Capture.savePhoto": .observation, "Camera.Capture.ignorePhoto": .observation,
    ]
    let agent = try AssistantAgent(
        chat: model, conversations: store,
        generationPolicies: .init(
            actions: actionPolicies, tools: ["System.Runtime.runtimeInfo": observeTool ? .observation : .recordOnly]),
        photoObservation: photoObservation)
    _ = try await bindSpeechRequests(agent)
    let manager = AgentManager()
    try await manager.register(agent)
    let input = InputGateway(manager: manager)
    let paths = [
        "UI.Expression.express", "UI.Caption.print", "UI.Caption.beginReplyTurn", "Speech.Playback.speak",
        "Camera.Capture.takePhoto", "Camera.Capture.savePhoto", "Camera.Capture.ignorePhoto",
    ]
    let definitions = paths.map { path -> ActionBinding in
        let parts = path.split(separator: ".").map(String.init)
        return ActionBinding(
            path: .init(domain: parts[0], module: parts[1], function: parts[2]),
            displayName: path, kind: .finite, completion: "Actual fixture completion.",
            feedbackPolicy: path == "UI.Expression.express" && observeAction ? .observation : .recordOnly,
            completing: { invocation in
                if path == "UI.Expression.express" || path.hasPrefix("Camera.Capture.") {
                    return try await handler(invocation)
                }
                return .completed
            })
    }
    let tool = ActionBinding(
        path: .init(domain: "System", module: "Runtime", function: "runtimeInfo"),
        displayName: "Runtime", kind: .finite, completion: "Actual completion.", protocols: [.tool],
        executionPolicy: .direct,
        feedbackPolicy: observeTool ? .observation : .recordOnly, completing: handler)
    let scheduler = ChannelScheduler(registry: try ActionRegistry(definitions: definitions)) {
        deliverActionFeedback ? await input.deliverActionResult($0) : .closed
    }
    let gateway = OutputGateway(
        manager: manager, requests: input,
        tools: try ToolRegistry(modules: [RoundTools(definitions: [tool])]), actions: scheduler, sink: { _ in })
    return .init(
        agent: agent, model: model, store: store, gateway: gateway, scheduler: scheduler, manager: manager,
        log: RoundLog())
}

@Test(arguments: ["action", "tool", "mixed"], [false, true])
func generationRoundPolicyControlsContinuationForAllThreeRoutes(_ route: String, _ observe: Bool) async throws {
    let harness = try await roundHarness(
        action: route != "tool", toolCount: route == "action" ? 0 : 1,
        observeAction: observe, observeTool: observe, handler: { _ in .value("actual-result") })
    let input = AgentInput(sessionID: UUID(), payload: .text("test"))
    let pump = try await harness.start(input)
    try await pump.value
    let requests = await harness.model.requests
    #expect(requests.count == (observe ? 2 : 1))
    if observe {
        if route != "action" {
            #expect(requests[1].messages.contains { $0.role == .tool && $0.content == "actual-result" })
        }
        if route != "tool" {
            #expect(requests[1].messages.contains { $0.role == .user && $0.content.contains("actual-result") })
        }
    }
    let record = try #require(try await harness.store.snapshot().current.turns.first)
    #expect(record.state == .completed)
    #expect(record.generationRounds?.count == (observe ? 2 : 1))
    let modelRequests = try #require(record.modelRequests)
    #expect(modelRequests.count == requests.count)
    #expect(modelRequests.first?.input == "test")
    #expect(modelRequests.first?.toolCalls.count == (route == "action" ? 0 : 1))
    #expect(modelRequests.first?.firstTokenAt != nil || route == "tool")
    if route == "tool" { #expect(modelRequests.first?.firstTokenAt == nil) }
    if route != "action" { #expect(modelRequests.first?.toolCalls.first?.output == "actual-result") }
    if observe {
        #expect(modelRequests[1].input.contains("actual-result"))
        #expect(!modelRequests[1].input.contains("已观察真实结果"))
        #expect(modelRequests[1].fragments.joined() == "已观察真实结果。")
        #expect(modelRequests[1].toolCalls.isEmpty)
        #expect(modelRequests[1].firstTokenAt != nil)
        let context = try JSONDecoder().decode([ChatMessage].self, from: Data(modelRequests[1].requestJSON.utf8))
        #expect(context == requests[1].messages)
        #expect(record.raw == modelRequests.flatMap(\.fragments).joined())
    }
    #expect(await harness.log.failures.isEmpty)
    let outputs = await harness.log.outputs
    #expect(
        !outputs.contains {
            if case .toolCall(let call) = $0.output { call.toolPath.hasPrefix("UI.Caption") } else { false }
        })
    await harness.close()
}

@Test(arguments: ["action", "tool", "mixed"], [false, true])
func generationRoundObservesVoidAndFailureWithoutReplayingFunctions(_ route: String, _ fail: Bool) async throws {
    let harness = try await roundHarness(
        action: route != "tool", toolCount: route == "action" ? 0 : 1, observeAction: true, observeTool: true,
        handler: { _ in
            if fail { throw RoundFailure.expected }
            return .completed
        })
    let pump = try await harness.start(.init(sessionID: UUID(), payload: .text("observe")))
    try await pump.value
    let requests = await harness.model.requests
    #expect(requests.count == 2)
    let observations = requests[1].messages.map(\.content).joined()
    #expect(observations.contains(fail ? "handlerFailed" : "completed"))
    let records = await harness.scheduler.executionSnapshot().records
    #expect(records.filter { $0.path.description == "UI.Expression.express" }.count == (route == "tool" ? 0 : 1))
    #expect(try await harness.store.snapshot().current.turns.first?.state == .completed)
    await harness.close()
}

private actor RoundConcurrencyGate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var startedWaiter: CheckedContinuation<Void, Never>?
    private(set) var active = 0
    private(set) var maximum = 0
    private(set) var started = 0
    func run() async -> ActionCompletion {
        active += 1
        started += 1
        maximum = max(maximum, active)
        if started == 4 {
            startedWaiter?.resume()
            startedWaiter = nil
        }
        if !released { await withCheckedContinuation { waiters.append($0) } }
        active -= 1
        return .value("actual-\(started)")
    }
    func waitForFour() async {
        if started >= 4 { return }
        await withCheckedContinuation { startedWaiter = $0 }
    }
    func release() {
        released = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

@Test(.timeLimit(.minutes(1))) func generationRoundToolsHaveFourWayBoundAndFullRoundBarrier() async throws {
    let gate = RoundConcurrencyGate()
    let harness = try await roundHarness(
        action: false, toolCount: 6, observeAction: false, observeTool: true,
        handler: { _ in await gate.run() })
    let pump = try await harness.start(.init(sessionID: UUID(), payload: .text("parallel")))
    await gate.waitForFour()
    #expect(await gate.active == 4)
    #expect(await gate.started == 4)
    #expect(await harness.model.requests.count == 1)
    await gate.release()
    try await pump.value
    #expect(await gate.maximum == 4)
    #expect(await gate.started == 6)
    let requests = await harness.model.requests
    #expect(requests.count == 2)
    #expect(requests[1].messages.filter { $0.role == .tool }.map(\.toolCallID) == (0..<6).map { "native-\($0)" })
    #expect(await harness.scheduler.executionSnapshot().records.allSatisfy { $0.path.domain != "System" })
    await harness.close()
}

@Test func generationRoundScheduledToolRegistrationIsRejected() throws {
    let binding = ActionBinding(
        path: .init(domain: "Fixture", module: "Work", function: "run"),
        displayName: "Run", kind: .finite, completion: "Completed.", protocols: [.action, .tool],
        executionPolicy: .scheduled(channel: "work"), handler: { _ in })
    #expect(throws: ToolRegistrationError.self) { try ToolRegistry(modules: [RoundTools(definitions: [binding])]) }
}

private actor MixedRoundGate {
    private var started = 0
    private var startedWaiter: CheckedContinuation<Void, Never>?
    private var actionWaiter: CheckedContinuation<Void, Never>?
    private var released = false
    func run(_ invocation: any FunctionInput) async -> ActionCompletion {
        started += 1
        if started == 2 {
            startedWaiter?.resume()
            startedWaiter = nil
        }
        if invocation.call.actionPath.domain == "UI", !released {
            await withCheckedContinuation { actionWaiter = $0 }
        }
        return .value(invocation.call.actionPath.domain == "UI" ? "action-observation" : "tool-observation")
    }
    func waitForBoth() async {
        if started == 2 { return }
        await withCheckedContinuation { startedWaiter = $0 }
    }
    func release() {
        released = true
        actionWaiter?.resume()
        actionWaiter = nil
    }
}

@Test(.timeLimit(.minutes(1))) func generationRoundToolBypassesWaitButContinuationWaitsForRecordOnlyAction()
    async throws
{
    let gate = MixedRoundGate()
    let harness = try await roundHarness(
        action: true, toolCount: 1, observeAction: false, observeTool: true,
        handler: { await gate.run($0) })
    let pump = try await harness.start(.init(sessionID: UUID(), payload: .text("mixed")))
    await gate.waitForBoth()
    #expect(await harness.model.requests.count == 1)
    await gate.release()
    try await pump.value
    let requests = await harness.model.requests
    #expect(requests.count == 2)
    #expect(requests[1].messages.last?.content == "tool-observation")
    let first = try #require(try await harness.store.snapshot().current.turns.first?.generationRounds?.first)
    let outcomes = try #require(JSONSerialization.jsonObject(with: Data(first.resultsJSON.utf8)) as? [[String: String]])
    #expect(outcomes.map { $0["protocol"] } == ["action", "tool"])
    #expect(outcomes.map { $0["result"] } == ["action-observation", "tool-observation"])
    await harness.close()
}

private actor CancellableRoundGate {
    private var entered = false
    private var waiter: CheckedContinuation<Void, Never>?
    private(set) var cleaned = false
    func run() async throws -> ActionCompletion {
        entered = true
        waiter?.resume()
        waiter = nil
        do { try await Task.sleep(for: .seconds(60)) } catch {
            cleaned = true
            throw error
        }
        return .completed
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { waiter = $0 }
    }
}

@Test(.timeLimit(.minutes(1))) func generationRoundCancellationJoinsNativeCleanupAndPersistsCancellation() async throws
{
    let gate = CancellableRoundGate()
    let harness = try await roundHarness(
        action: false, toolCount: 1, observeAction: false, observeTool: true,
        handler: { _ in try await gate.run() })
    let pump = try await harness.start(.init(sessionID: UUID(), payload: .text("cancel")))
    await gate.waitUntilEntered()
    pump.cancel()
    await #expect(throws: CancellationError.self) { try await pump.value }
    #expect(await gate.cleaned)
    await harness.agent.stop()
    #expect(try await harness.store.snapshot().current.turns.first?.state == .cancelled)
    // Model completion and cancellation of later execution are separate evidence.
    #expect(try await harness.store.snapshot().current.turns.first?.modelRequests?.first?.state == .completed)
    #expect(await harness.model.requests.count == 1)
    await harness.close()
}

@Test func generationRoundRejectsExcessNativeCallsWithoutAnotherModelRequest() async throws {
    let harness = try await roundHarness(
        action: false, toolCount: 17, observeAction: false, observeTool: true,
        handler: { _ in .completed })
    let pump = try await harness.start(.init(sessionID: UUID(), payload: .text("excess")))
    try await pump.value
    let record = try #require(try await harness.store.snapshot().current.turns.first)
    #expect(record.state == .failed)
    #expect(record.error?.contains("limitExceeded") == true)
    #expect(await harness.model.requests.count == 1)
    #expect(await harness.log.outputs.filter { if case .toolCall = $0.output { true } else { false } }.count <= 16)
    await harness.close()
}

@Test func generationRoundRejectsMismatchedSealIdentity() async throws {
    let harness = try await roundHarness(
        action: false, toolCount: 0, observeAction: false, observeTool: false,
        handler: { _ in .completed })
    let envelope = OutputEnvelope(
        source: harness.agent.descriptor.id,
        input: .init(sessionID: UUID(), payload: .text("seal")),
        output: .roundFinished(UUID()), roundID: UUID())
    let result = try await harness.gateway.execute(envelope)
    #expect(result.failure != nil)
    #expect(await harness.model.requests.isEmpty)
    #expect(await harness.scheduler.executionSnapshot().records.isEmpty)
    await harness.close()
}

@Test func generationRoundFeedbackDeliveryFailureStopsWithoutReplayingEffect() async throws {
    let harness = try await roundHarness(
        action: true, toolCount: 0, observeAction: true, observeTool: false,
        deliverActionFeedback: false, handler: { _ in .value("committed") })
    let pump = try await harness.start(.init(sessionID: UUID(), payload: .text("delivery failure")))
    try await pump.value
    #expect(await harness.model.requests.count == 1)
    let records = await harness.scheduler.executionSnapshot().records
    #expect(records.filter { $0.path.description == "UI.Expression.express" }.count == 1)
    #expect(records.first { $0.path.description == "UI.Expression.express" }?.phase == .succeeded)
    #expect(try await harness.store.snapshot().current.turns.first?.state == .failed)
    await harness.close()
}

@Test func generationRoundObservationRegistrationDoesNotDependOnReturnShape() {
    let value = ActionBinding(path: "System.Runtime.value", handler: { _ in "value" })
    let completion = ActionBinding(path: "System.Runtime.void", completing: { _ in })
    let observation = ActionBinding(
        path: "System.Runtime.void", feedbackPolicy: .observation, completing: { _ in })
    #expect(value.feedbackPolicy == .recordOnly)
    #expect(completion.feedbackPolicy == .recordOnly)
    #expect(observation.feedbackPolicy == .observation)
}

@Test(arguments: [false, true]) func assistantPhotoActionAttachesOwnedImageAfterRoundBarrier(_ mixed: Bool) async throws
{
    let photoID = UUID()
    let bytes = Data([0xff, 0xd8, 0xff, 0xd9])
    let harness = try await roundHarness(
        action: false, toolCount: mixed ? 1 : 0, observeAction: false,
        observeTool: mixed, photo: true, supportsImages: true,
        photoObservation: { id, input in
            #expect(id == photoID)
            #expect(input.payload.kind == .text)
            return try ChatImage(id: id, data: bytes)
        },
        handler: { invocation in
            if invocation.call.actionPath.description == "Camera.Capture.takePhoto" {
                return .value(
                    "{\"photoID\":\"\(photoID.uuidString)\",\"width\":640,\"height\":480,\"mimeType\":\"image/jpeg\"}")
            }
            return .value("native actual result")
        })
    let pump = try await harness.start(.init(sessionID: UUID(), payload: .text("拍一张照片并告诉我看到了什么")))
    try await pump.value
    let requests = await harness.model.requests
    #expect(requests.count == 2)
    let image = try #require(requests[1].messages.last?.images?.first)
    #expect(image.id == photoID && image.data == bytes)
    #expect(requests[0].messages.allSatisfy { $0.images == nil })
    if mixed { #expect(requests[1].messages.contains { $0.role == .tool && $0.content == "native actual result" }) }
    let records = await harness.scheduler.executionSnapshot().records
    #expect(records.filter { $0.path.description == "Camera.Capture.takePhoto" }.count == 1)
    let turn = try #require(try await harness.store.snapshot().current.turns.first)
    let history = try #require(turn.modelRequests?.last?.requestJSON)
    #expect(turn.continuationRequests == nil)
    #expect(history.contains(photoID.uuidString))
    #expect(history.contains("imageReferences"))
    #expect(history.contains("byteCount"))
    #expect(!history.contains("bytes omitted"))
    #expect(!history.contains(bytes.base64EncodedString()))
    await harness.close()
}

@Test(arguments: ["capture", "reader", "provider"]) func assistantPhotoFailuresDoNotFabricateVisionOrRepeatCapture(
    _ failure: String
) async throws {
    let id = UUID()
    let harness = try await roundHarness(
        action: false, toolCount: 0, observeAction: false, observeTool: false,
        photo: true, supportsImages: failure != "provider",
        photoObservation: { id, _ in
            if failure == "reader" { throw RoundFailure.expected }
            return try ChatImage(id: id, data: Data([1]))
        },
        handler: { _ in
            if failure == "capture" { throw RoundFailure.expected }
            return .value("{\"photoID\":\"\(id.uuidString)\"}")
        })
    let pump = try await harness.start(.init(sessionID: UUID(), payload: .text("photo")))
    try await pump.value
    let requests = await harness.model.requests
    #expect(requests.count == (failure == "capture" ? 2 : 1))
    #expect(requests.allSatisfy { $0.messages.allSatisfy { $0.images == nil } })
    #expect(
        await harness.scheduler.executionSnapshot().records.filter { $0.path.description == "Camera.Capture.takePhoto" }
            .count == 1)
    await harness.close()
}

@Test func capturedPhotoStorePersistsOwnedBytesAndRejectsOverflow() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let owner = StorageOwner(namespace: "photos", source: "assistant", session: UUID(), input: UUID())
    let store = CapturedPhotoStore(root: root)
    let bytes = Data([0xff, 0xd8, 0xff, 0xd9])
    let id = try await store.save(bytes, owner: owner)
    let restarted = CapturedPhotoStore(root: root)
    #expect(try await restarted.read(id, owner: owner) == bytes)
    await #expect(throws: FileStorageError.self) {
        try await restarted.read(
            id, owner: StorageOwner(namespace: "photos", source: owner.source, session: owner.session, input: UUID()))
    }
    for _ in 1..<32 { _ = try await store.save(bytes, owner: owner) }
    await #expect(throws: FileStorageError.self) { _ = try await store.save(bytes, owner: owner) }
    #expect(try await store.read(id, owner: owner) == bytes)
}

private actor PhotoFunctionEndpoint: CameraControlCapability {
    let id = UUID()
    private(set) var captures = 0
    func takePhoto(invocation: any FunctionInput) throws -> CameraPhotoReceipt {
        captures += 1
        return try CameraPhotoReceipt(photoID: id, width: 640, height: 480)
    }
    func setEnabled(_ enabled: Bool, invocation: any FunctionInput) {}
    func flip(_ facing: CameraActions.Facing, invocation: any FunctionInput) {}
}

@Test func photoFunctionPreservesValueCompletionAndValidatesBeforeCapture() async throws {
    let endpoint = PhotoFunctionEndpoint()
    let definition = try #require(
        CameraModule(camera: endpoint).definitions.first { $0.path.description == "Camera.Capture.takePhoto" })
    let tool = ActionBinding(
        function: definition, protocols: [.tool], executionPolicy: .direct,
        directResultPolicy: .returning, feedbackPolicy: .observation)
    let executor = ToolExecutor(registry: try ToolRegistry(modules: [RoundTools(definitions: [tool])]))
    let envelope = OutputEnvelope(
        source: .assistant, input: .init(sessionID: UUID(), payload: .text("photo")), output: .control("fixture"))
    let invalid = try #require(
        try await executor.execute(
            ToolCall(toolPath: "Camera.Capture.takePhoto", arguments: ["unexpected": "yes"]), envelope: envelope))
    #expect(invalid.isError)
    #expect(await endpoint.captures == 0)
    let valid = try #require(
        try await executor.execute(ToolCall(toolPath: "Camera.Capture.takePhoto"), envelope: envelope))
    let receipt = try JSONDecoder().decode(CameraPhotoReceipt.self, from: Data(valid.value.utf8))
    #expect(receipt.photoID == endpoint.id)
    #expect(await endpoint.captures == 1)
}

@Test(arguments: ["savePhoto", "ignorePhoto"], [false, true])
func photoDispositionObservationDrivesReplyWithoutAnotherImageOrCapture(_ command: String, _ denied: Bool) async throws
{
    let id = UUID()
    let receipt = CameraPhotoCommandReceipt(photoID: id, state: command == "savePhoto" ? .saved : .ignored)
    let value = String(decoding: try JSONEncoder().encode(receipt), as: UTF8.self)
    let harness = try await roundHarness(
        action: false, toolCount: 0, observeAction: false, observeTool: false, photoCommand: command,
        handler: { _ in
            if denied { throw CameraControlError.permissionDenied }
            return .value(value)
        })
    let pump = try await harness.start(.init(sessionID: UUID(), payload: .text(command)))
    try await pump.value
    let requests = await harness.model.requests
    #expect(requests.count == 2)
    #expect(requests.allSatisfy { $0.messages.allSatisfy { $0.images == nil } })
    #expect(
        requests.last?.messages.contains { $0.content.contains(denied ? "permissionDenied" : id.uuidString) } == true)
    let records = await harness.scheduler.executionSnapshot().records
    #expect(records.filter { $0.path.description == "Camera.Capture." + command }.count == 1)
    #expect(records.allSatisfy { $0.path.description != "Camera.Capture.takePhoto" })
    await harness.close()
}

private struct IndependentProtocolModel: ChatCapability {
    let availability: CapabilityAvailability = .available
    let supportsToolCalls = true
    func chat(_ request: ChatRequest) throws -> InferenceSession<ChatEvent> {
        let pair = InferenceSession<ChatEvent>.make(limits: try StreamLimits(), estimatedBytes: { $0.estimatedBytes })
        try pair.emitter.yield(.text("Hello."))
        try pair.emitter.yield(.toolCall(.init(id: "independent-native", name: "runtimeInfo", argumentsJSON: "{}")))
        try pair.emitter.yield(.finished(.toolCalls))
        pair.emitter.finish()
        return pair.session
    }
}

@Test(.timeLimit(.minutes(1))) func nativeParsingAndEmissionDoNotWaitForSpeechPreparation() async throws {
    let agent = try AssistantAgent(chat: IndependentProtocolModel())
    let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    let release = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    let observed = AsyncStream<AgentOutput>.makeStream(bufferingPolicy: .bufferingOldest(16))
    try await agent.bind(
        AgentMessaging { message, _, target in
            if case .speechSynthesis? = message.perception {
                entered.continuation.yield(())
                await withTaskCancellationHandler {
                    var iterator = release.stream.makeAsyncIterator()
                    _ = await iterator.next()
                } onCancel: {
                    release.continuation.finish()
                }
                try Task.checkCancellation()
            }
            return DeliveryReport(delivered: target.map { [$0] } ?? [])
        })
    try await agent.start()
    let consumer = Task {
        for await envelope in agent.outputs {
            observed.continuation.yield(envelope.output)
            if case .roundFinished = envelope.output { await agent.stop() }
        }
        observed.continuation.finish()
    }
    try await agent.receive(.init(sessionID: UUID(), payload: .text("independent parsing")))
    var speechStartup = entered.stream.makeAsyncIterator()
    _ = await speechStartup.next()
    var outputs = observed.stream.makeAsyncIterator()
    var sawNative = false
    while let output = await outputs.next() {
        if case .toolCall(let call) = output {
            #expect(call.toolPath == "System.Runtime.runtimeInfo")
            sawNative = true
            break
        }
        if case .roundFinished = output { Issue.record("Round sealed before speech preparation settled") }
        if case .actionCall(let call) = output {
            #expect(call.actionPath.description != "Speech.Playback.speak")
        }
    }
    #expect(sawNative)
    release.continuation.finish()
    await consumer.value
    var sawPlayback = false
    var sawSeal = false
    while let output = await outputs.next() {
        if case .actionCall(let call) = output, call.actionPath.description == "Speech.Playback.speak" {
            sawPlayback = true
        }
        if case .roundFinished = output { sawSeal = true }
    }
    #expect(sawPlayback && sawSeal)
}

private struct OpenMalformedProtocolModel: ChatCapability {
    let availability: CapabilityAvailability = .available
    let termination: AsyncStream<SessionTermination>.Continuation
    func chat(_ request: ChatRequest) throws -> InferenceSession<ChatEvent> {
        let pair = InferenceSession<ChatEvent>.make(
            limits: try StreamLimits(), estimatedBytes: { $0.estimatedBytes },
            onTermination: { termination.yield($0) })
        try pair.emitter.yield(.text("<wait/>"))
        // Deliberately keep the model stream open after a malformed Action token.
        return pair.session
    }
}

@Test(.timeLimit(.minutes(1))) func actionParserFailureCancelsOpenModelStreamWithoutWaitingForAnotherEvent()
    async throws
{
    let termination = AsyncStream<SessionTermination>.makeStream(bufferingPolicy: .bufferingOldest(1))
    let agent = try AssistantAgent(chat: OpenMalformedProtocolModel(termination: termination.continuation))
    try await agent.start()
    try await agent.receive(.init(sessionID: UUID(), payload: .text("malformed action")))
    var sawFailure = false
    for await envelope in agent.outputs {
        if case .roundFinished = envelope.output { Issue.record("Malformed Action parser sealed a successful round") }
        if case .control(let value) = envelope.output, value.hasPrefix("assistant.error:") {
            sawFailure = true
            #expect(!value.contains("timed out"))
            await agent.stop()
        }
    }
    #expect(sawFailure)
    var events = termination.stream.makeAsyncIterator()
    let ended = try #require(await events.next())
    if case .cancelled = ended {} else { Issue.record("Failed protocol did not cancel the open model stream") }
}

@Test func capturedPhotoHistoryReadsSurviveSessionsAndEnforceProducingInput() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = CapturedPhotoStore(root: root)
    let owner = StorageOwner(namespace: "photos", source: "assistant", session: UUID(), input: UUID())
    let bytes = Data([1, 2, 3])
    let id = try await store.save(bytes, owner: owner)
    let restarted = CapturedPhotoStore(root: root)
    #expect(try await restarted.readForInput(id, source: owner.source, input: owner.input) == bytes)
    await #expect(throws: FileStorageError.invalidFile) {
        try await restarted.readForInput(id, source: "other", input: owner.input)
    }
    await #expect(throws: FileStorageError.invalidFile) {
        try await restarted.readForInput(id, source: owner.source, input: UUID())
    }
    #expect(try await restarted.readForInput(UUID(), source: owner.source, input: owner.input) == nil)
    try FileManager.default.removeItem(at: root.appendingPathComponent(id.uuidString + ".jpg"))
    #expect(try await restarted.readForInput(id, source: owner.source, input: owner.input) == nil)
}
