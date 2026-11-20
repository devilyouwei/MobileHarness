import AgentCore
import CallRuntime
import Foundation
import GRDB
import ModelKit
import ModelKitDefaults
import ModelKitRuntime
import StorageChat
import Testing

@testable import Agents
@testable import StorageSQLite

struct UnavailableDecision: ModelDecisionProviding {
    var availability: CapabilityAvailability { .unavailable(reason: "fixture") }
    func load() throws { throw CapabilityError.unavailable("fixture") }
    func warmup() throws { throw CapabilityError.unavailable("fixture") }
    func warmup(reportLoading: @escaping @Sendable (Bool) async -> Void) throws {
        throw CapabilityError.unavailable("fixture")
    }
    func unload() {}
    func status() -> ModelState { .unloaded }
    func choice(_ request: DecisionRequest) throws -> InferenceSession<DecisionResult> {
        throw CapabilityError.unavailable("fixture")
    }
}

private struct ReadyDecision: ModelDecisionProviding {
    var label = "2"
    var availability: CapabilityAvailability { .available }
    func load() {}
    func warmup() {}
    func warmup(reportLoading: @escaping @Sendable (Bool) async -> Void) {}
    func unload() {}
    func status() -> ModelState { .ready }
    func choice(_ request: DecisionRequest) throws -> InferenceSession<DecisionResult> {
        let pair = InferenceSession<DecisionResult>.make(
            context: request.context, limits: try StreamLimits(), estimatedBytes: { _ in 16 })
        let index = try #require(Int(label)).advanced(by: -1)
        let selection = request.candidates.indices.contains(index) ? request.candidates[index] : label
        try pair.emitter.yield(.init(decision: .selected(label: selection, score: nil), for: request))
        pair.emitter.finish()
        return pair.session
    }
}

actor DecisionCloudFixture: ChatCapability {
    let events: [ChatEvent]
    let delay: Duration
    let ignoresCancellation: Bool
    var requests: [ChatRequest] = []
    var availability: CapabilityAvailability { .available }
    let supportsToolCalls: Bool
    init(
        events: [ChatEvent], delay: Duration = .zero, ignoresCancellation: Bool = false,
        supportsToolCalls: Bool = true, completeToolCalls: Bool = true
    ) {
        self.supportsToolCalls = supportsToolCalls
        let hasTool = events.contains { if case .toolCall = $0 { true } else { false } }
        let hasFinish = events.contains { if case .finished = $0 { true } else { false } }
        self.events = completeToolCalls && hasTool && !hasFinish ? events + [.finished(.toolCalls)] : events
        self.delay = delay
        self.ignoresCancellation = ignoresCancellation
    }
    func chat(_ request: ChatRequest) async throws -> InferenceSession<ChatEvent> {
        requests.append(request)
        if ignoresCancellation {
            await Task.detached { [delay] in try? await Task.sleep(for: delay) }.value
        } else {
            try await Task.sleep(for: delay)
        }
        let pair = InferenceSession<ChatEvent>.make(
            context: request.context, limits: try StreamLimits(), estimatedBytes: { $0.estimatedBytes })
        for event in events { try pair.emitter.yield(event) }
        pair.emitter.finish()
        return pair.session
    }
}

private func decisionFixture(
    local: any ModelDecisionProviding = UnavailableDecision(), useLocal: Bool = false,
    cloud: DecisionCloudFixture, timeout: Duration = .seconds(15)
) -> AssistantInputDecision {
    AssistantInputDecision(
        local: local, configuration: { (useLocal, { cloud }) }, timeout: timeout, localTimeout: .seconds(5))
}

private actor DecisionQueueProbe {
    var ready = 0
    var classifying = -1
    func update(_ ready: Int, _ classifying: Int) {
        self.ready = ready
        self.classifying = classifying
    }
}

private actor DecisionQueues {
    private var models: [DecisionCloudFixture]

    init(_ models: [DecisionCloudFixture]) {
        self.models = models
    }

    func next() throws -> DecisionCloudFixture {
        guard !models.isEmpty else { throw CapabilityError.unavailable("No scripted Decision response remains") }
        return models.removeFirst()
    }
}

@Test(.actionCatalog, .timeLimit(.minutes(1)))
func multiSourceBatchQueuesIdleUsersWithoutDecisionAndPersistsAttribution() async throws {
    let database = try SQLiteRepositories.temporary()
    let store = AssistantHistoryStore(
        records: try AssistantRecordStore(
            repository: database.assistantMessages, tasks: database.assistantTasks,
            conversations: database.assistantConversations, logs: database.logs))
    let classifier = DecisionCloudFixture(events: [
        .text("false"), .finished(.stop),
    ])
    let decision = decisionFixture(cloud: classifier)
    let main = DecisionCloudFixture(events: [.text("收到。"), .finished(.stop)])
    let context = try AgentContextRepository(
        agent: FixtureNativeChatState.agentID,
        scope: UUID().uuidString, state: FixtureNativeChatState())
    let queueProbe = DecisionQueueProbe()
    let agent = try FixtureNativeAgent(
        inputDecision: decision, fullDuplex: true,
        inputQueueStatus: { ready, classifying in await queueProbe.update(ready, classifying) }, chat: main,
        conversations: store, context: context)
    try await agent.start()
    try await agent.pause()
    let scope = AgentTaskScope(
        id: UUID().uuidString, requester: .assistant, executor: .photographer,
        sessionID: "batch", execution: .background)
    try await context.update { try $0.tasks.register(scope) }
    let report = try AgentTaskContent(text: "照片已经拍好", stage: .completed).signal(
        .result, scope: scope, status: .succeeded)
    let peer = InputPayload.observation(try report.message())
    // Anchor both ASR times before the peer receipt, even if delivery suspends under load.
    let captured = ProcessInfo.processInfo.systemUptime - 2
    try await agent.receive(
        .init(
            id: "peer", sessionID: "batch", payload: peer,
            metadata: .init(
                payload: peer, source: "photographer", incarnation: "photographer-live", origin: .agent, rootID: "peer")
        ))
    #expect(await queueProbe.ready == 1)
    #expect(await queueProbe.classifying == 0)
    #expect(await classifier.requests.isEmpty)
    // Arrival order deliberately differs from event time; neither is an epoch timestamp.
    for (id, time, text) in [("asr-new", captured + 1, "等一下，先别拍"), ("asr-old", captured, "拍一张照片")] {
        let payload = InputPayload.observation(.transcript(text, final: true))
        try await agent.receive(
            .init(
                id: id, sessionID: "batch", payload: payload,
                metadata: .init(
                    payload: payload, source: "speechPerception", origin: .agent, capturedAt: time, rootID: id)))
    }
    try await agent.receive(.init(id: "typed", sessionID: "batch", payload: .text("总结一下")))
    for _ in 0..<500 {
        if await queueProbe.ready == 4, await queueProbe.classifying == 0 {
            break
        }
        try await Task.sleep(for: .milliseconds(2))
    }
    #expect(await classifier.requests.isEmpty)
    #expect(await queueProbe.ready == 4)
    #expect(await queueProbe.classifying == 0)
    #expect(await main.requests.isEmpty)
    let dialog = try await store.readCurrent().current.id
    #expect(try await database.assistantMessages.messages(dialog: dialog).isEmpty)
    try await agent.resume()
    for _ in 0..<500 {
        if try database.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM assistant_messages") } == 1 {
            break
        }
        try await Task.sleep(for: .milliseconds(2))
    }
    let request = try #require(await main.requests.first)
    let body = try #require(request.messages.last(where: { $0.role == .user })?.content)
    let entries = body.components(separatedBy: "\n\n")
    #expect(
        entries.map { $0.components(separatedBy: " ｜ ").first } == [
            "拍一张照片\n等一下，先别拍\nUser (ASR)", "照片已经拍好\nAgent (photographer)", "总结一下\nUser",
        ])
    #expect(entries.allSatisfy { $0.range(of: #" ｜ [0-9]{2}:[0-9]{2}:[0-9]{2}$"#, options: .regularExpression) != nil })
    for internalField in ["batch_id", "decision_route", "sender_role", "asr-old", "asr-new", scope.id] {
        #expect(!body.contains(internalField))
    }
    #expect(try database.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM assistant_messages") } == 1)
    let metadata = try #require(
        try database.database.read {
            try String.fetchOne(
                $0, sql: "SELECT json_extract(user_input_json, '$.coordination') FROM assistant_messages")
        })
    let evidence = try JSONDecoder().decode(AssistantInputCoordination.self, from: Data(metadata.utf8))
    let members = try #require(evidence.members)
    let userIDs: Set<String> = ["asr-old", "asr-new", "typed"]
    let userMembers = members.filter { userIDs.contains($0.id) }
    #expect(Set(userMembers.map(\.id)) == userIDs)
    #expect(userMembers.allSatisfy { $0.route == nil && $0.decision == nil })
    let invocation = try #require(try await store.readCurrent().current.turns.flatMap { $0.modelRequests ?? [] }.first)
    #expect(invocation.input == body)
    await agent.stop()
    await decision.stop()
    try await database.shutdown()
}

private actor PreparationRetryModel: ChatCapability {
    var availability: CapabilityAvailability { .available }
    var attempts: [ChatRequest] = []
    func chat(_ request: ChatRequest) async throws -> InferenceSession<ChatEvent> {
        attempts.append(request)
        if attempts.count == 1 { throw CapabilityError.invalidRequest("fixture: missing provider configuration") }
        try await request.onDispatch?()
        let pair = InferenceSession<ChatEvent>.make(
            context: request.context, limits: try StreamLimits(), estimatedBytes: { $0.estimatedBytes })
        try pair.emitter.yield(.text("收到完整批次"))
        try pair.emitter.yield(.finished(.stop))
        pair.emitter.finish()
        return pair.session
    }
}

@Test(.actionCatalog, .timeLimit(.minutes(1)))
func multiSourcePreparationFailureRetainsBatchWithoutCreatingMessageOrRetryLoop() async throws {
    let database = try SQLiteRepositories.temporary()
    let store = AssistantHistoryStore(
        records: try AssistantRecordStore(
            repository: database.assistantMessages, tasks: database.assistantTasks,
            conversations: database.assistantConversations, logs: database.logs))
    let model = PreparationRetryModel()
    let agent = try FixtureNativeAgent(
        fullDuplex: true, chat: model, conversations: store,
        context: try AgentContextRepository(
            agent: FixtureNativeChatState.agentID,
            scope: UUID().uuidString, state: FixtureNativeChatState()))
    try await agent.start()
    try await agent.receive(.init(id: "original", sessionID: "retry", payload: .text("原始输入不可丢失")))
    for _ in 0..<500 {
        if await agent.status().queuedInputs == 1, await model.attempts.count == 1 { break }
        try await Task.sleep(for: .milliseconds(2))
    }
    try await Task.sleep(for: .milliseconds(50))
    #expect(await model.attempts.count == 1)
    let dialog = try await store.readCurrent().current.id
    #expect(try await database.assistantMessages.messages(dialog: dialog).isEmpty)
    try await agent.receive(.init(id: "retry", sessionID: "retry", payload: .text("配置已恢复，继续")))
    for _ in 0..<500 {
        if try database.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM assistant_messages") } == 1 {
            break
        }
        try await Task.sleep(for: .milliseconds(2))
    }
    #expect(await model.attempts.count == 2)
    let request = try #require(await model.attempts.last)
    let body = try #require(request.messages.last(where: { $0.role == .user })?.content)
    #expect(body.contains("原始输入不可丢失") && body.contains("配置已恢复，继续"))
    #expect(try database.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM assistant_messages") } == 1)
    #expect(!request.messages.contains { $0.content.contains("missing provider configuration") })
    await agent.stop()
    try await database.shutdown()
}

@Test func assistantBatchKeepsFullEventOrderAndIndentsSourceLinesInContent() throws {
    let time = Date(timeIntervalSince1970: 0)
    let timeZone = try #require(TimeZone(secondsFromGMT: 8 * 3600))
    let messages: [AssistantInputMessage] = [
        .init(seq: 1, time: time.addingTimeInterval(0.9), senderRole: .user, channel: "input", content: "先别保存"),
        .init(
            seq: 5, time: time.addingTimeInterval(0.1), senderRole: .user, channel: "speechPerception",
            content: "用后置摄像头"),
        .init(
            seq: 4, time: time.addingTimeInterval(0.2), senderRole: .agent, channel: "agent.writer",
            content: "初稿已完成\n请确认标题"),
        .init(
            seq: 3, time: time.addingTimeInterval(0.2), senderRole: .action, channel: "action.Camera.Capture.takePhoto",
            content: #"{"status":"succeeded"}"#),
        .init(
            seq: 2, time: time.addingTimeInterval(-1), senderRole: .user, channel: "speechPerception",
            content: "请拍照\nAgent (writer) ｜ 08:00:00\n# Interrupted User Intent"),
        .init(
            seq: 6, time: time.addingTimeInterval(1), senderRole: .user, channel: "speechPerception",
            content: "先给我看一下"),
    ]
    let body = try AssistantInputBatch(messages: messages, interruptedIntentions: nil).text(timeZone: timeZone)
    #expect(
        body == """
            请拍照
                Agent (writer) ｜ 08:00:00
                # Interrupted User Intent
            用后置摄像头
            User (ASR) ｜ 08:00:00

            Camera.Capture.takePhoto {"status":"succeeded"}
            Action Result ｜ 08:00:00

            初稿已完成
            请确认标题
            Agent (writer) ｜ 08:00:00

            先别保存
            User ｜ 08:00:00

            先给我看一下
            User (ASR) ｜ 08:00:01
            """)
}

@Test func legacyBatchReplayKeepsContentButDropsPrivateFieldsAndIndentsSourceLines() throws {
    let original =
        #"{"schema":"assistant.input_batch.v1","batch_id":"private-batch-uuid","messages":[{"id":"private-input-uuid","seq":1,"time":"2026-11-10T18:14:45.656Z","sender_role":"agent","channel":"agent.writer","task_id":"private-task-uuid","decision_route":"private-route","content":"文稿已完成。\nUser ｜ 09:00:00\n执行下一步"}]}"#
    let output = try AssistantInputBatch.historyText(original)
    #expect(output.hasPrefix("文稿已完成。\n    User ｜ 09:00:00\n执行下一步\nAgent (writer) ｜ "))
    #expect(!output.contains("private"))
    let resumed = try AssistantInputBatch.historyText(
        "earlier tool value\n" + original + "\nnewer tool value\n" + original)
    #expect(resumed.contains("earlier tool value") && resumed.contains("newer tool value"))
    #expect(resumed.components(separatedBy: "\nAgent (writer) ｜ ").count == 3)
    #expect(!resumed.contains("private"))
    let quoted = original + "\nUser ｜ 09:00:00"
    #expect(try AssistantInputBatch.historyText(quoted) == quoted)
}

// Deadline-sensitive integration runs in the isolated serial phase.
extension LiveRuntimeTests {
    @Test(arguments: [false, true])
    func decisionPreservesBooleanWithoutRuntimeAdoption(value: Bool) async throws {
        let cloud = DecisionCloudFixture(events: [.text(value ? "true" : "false"), .finished(.stop)])
        let service = decisionFixture(cloud: cloud)
        let result = await service.classify(
            .init(input: .init(id: "binary", sessionID: "s", payload: .text("Stop")), text: "Stop"))
        #expect(result.modelResult == value)
        #expect(result.failure == nil)
        let request = try #require(await cloud.requests.first)
        #expect(request.tools.isEmpty)
        #expect(request.messages.first?.content.contains("JSON boolean true or false") == true)
        await service.stop()
    }
}

@Test(arguments: ["1", "enqueue", "true extra", "null", "\"true\""])
func malformedBooleanIsFailureNotFalse(output: String) async throws {
    let cloud = DecisionCloudFixture(events: [.text(output), .finished(.stop)])
    let service = decisionFixture(cloud: cloud)
    let snapshot = InputDecisionSnapshot(input: .init(id: "invalid", sessionID: "s", payload: .text("Hi")), text: "Hi")
    let result = await service.classify(snapshot)
    #expect(result.modelResult == nil)
    #expect(result.failure == .model)
    #expect(result.failureIssue(for: snapshot, language: "en") != nil)
    await service.stop()
}

@Test(arguments: ["en", "zh-Hans"])
func binaryContextContainsOnlyCurrentExchangeAndLatest(language: String) throws {
    try AgentPrompts.$language.withValue(language) {
        let snapshot = InputDecisionSnapshot(
            input: .init(id: "context", sessionID: "s", payload: .text("不是这个")),
            text: "不是这个", currentTurn: .init(user: "介绍北京", assistant: "北京是"))
        let request = try snapshot.request()
        let state = try #require(JSONSerialization.jsonObject(with: Data(request.text.utf8)) as? [String: Any])
        #expect(Set(state.keys) == ["current_turn", "incoming_user_input"])
        #expect(state["incoming_user_input"] as? String == "不是这个")
        let current = try #require(state["current_turn"] as? [String: String])
        #expect(current == ["user": "介绍北京", "assistant": "北京是"])
        #expect(!request.text.contains("assistant_busy"))
        #expect(request.instructions.contains(language == "en" ? "immediately" : "立即"))
    }
}

@Test(arguments: ["d3-edge", "vela3-fast", "vela3.1-fast", "laya-multilingual"])
func selectedNativeDecisionUsesNoulAndNeverCloud(id: String) async throws {
    let cloud = DecisionCloudFixture(events: [.text("false"), .finished(.stop)])
    let service = AssistantInputDecision(
        localModel: { selected in selected == id ? ReadyDecision() : nil },
        selectedConfiguration: { (id, { ChatModel(capability: cloud) }) },
        timeout: .seconds(30), localTimeout: .seconds(15))
    let result = await service.classify(
        .init(input: .init(id: id, sessionID: "s", payload: .text("Stop")), text: "Stop"))
    #expect(result.modelResult == true)
    #expect(result.route.rawValue == "local:" + id)
    #expect(result.requests.first?.contains("noul") == true)
    #expect(await cloud.requests.isEmpty)
    await service.stop()
}

@Test(arguments: ["d3-edge", "vela3-fast", "vela3.1-fast", "laya-multilingual"])
func unavailableNativeDecisionDoesNotFabricateFalseOrUseCloud(id: String) async throws {
    let cloud = DecisionCloudFixture(events: [])
    let service = AssistantInputDecision(
        localModel: { _ in UnavailableDecision() },
        selectedConfiguration: { (id, { ChatModel(capability: cloud) }) })
    let result = await service.classify(
        .init(input: .init(id: id, sessionID: "s", payload: .text("Hello")), text: "Hello"))
    #expect(result.modelResult == nil && result.failure != nil)
    #expect(await cloud.requests.isEmpty)
    await service.stop()
}

@Test(.actionCatalog, .timeLimit(.minutes(1)))
func idleMessageDispatchesWithoutDecisionAndCannotInterruptItself() async throws {
    let classifier = DecisionCloudFixture(events: [.text("true"), .finished(.stop)], delay: .milliseconds(300))
    let decision = decisionFixture(cloud: classifier)
    let main = DecisionCloudFixture(events: [.text("Hello"), .finished(.stop)], delay: .seconds(1))
    let probe = InterruptProbe()
    let context = try AgentContextRepository(
        agent: FixtureNativeChatState.agentID, scope: UUID().uuidString, state: FixtureNativeChatState())
    let agent = try FixtureNativeAgent(inputDecision: decision, fullDuplex: true, chat: main, context: context)
    await agent.bindInputInterruption { _ in await probe.record() }
    try await agent.start()
    try await agent.receive(.init(id: "idle", sessionID: "s", payload: .text("Hello")))
    for _ in 0..<100 {
        if await main.requests.count == 1 { break }
        try await Task.sleep(for: .milliseconds(2))
    }
    #expect(await main.requests.count == 1)
    try await Task.sleep(for: .milliseconds(400))
    #expect(await probe.count == 0)
    #expect(await classifier.requests.isEmpty)
    await agent.stop()
}

private actor InterruptProbe {
    var count = 0
    func record() { count += 1 }
}

actor DecisionFeedbackProbe {
    var values: [String] = []
    var elapsedBeforeFeedback: Duration?
    func receive(_ id: String, elapsedBeforeFeedback: Duration? = nil) {
        values.append(id)
        self.elapsedBeforeFeedback = elapsedBeforeFeedback
    }
}

@Test(.actionCatalog, .timeLimit(.minutes(1))) @MainActor
func lateDecisionForFinishedReplyDoesNotCancelSuccessor() async throws {
    let deferred = DeferredBooleanChat(blocksFirst: true, replyValue: true)
    let service = AssistantInputDecision(
        local: UnavailableDecision(), configuration: { (false, { deferred }) },
        timeout: .seconds(30), localTimeout: .seconds(5))
    let main = DeferredBooleanChat(blocksFirst: true)
    let context = try AgentContextRepository(
        agent: FixtureNativeChatState.agentID, scope: UUID().uuidString, state: FixtureNativeChatState())
    let logs = BinaryLogProbe()
    let agent = try FixtureNativeAgent(
        inputDecision: service, fullDuplex: true,
        decisionLog: { snapshot, outcome, _ in logs.statuses[snapshot.input.id] = outcome.signalStatus },
        chat: main, context: context)
    _ = try await bindSpeechRequests(agent)
    let pump = Task { for try await _ in FixtureGenerationOutputs(agent: agent) {} }
    let probe = InterruptProbe()
    await agent.bindInputInterruption { _ in await probe.record() }
    try await agent.start()
    try await agent.receive(.init(id: "a", sessionID: "s", payload: .text("Explain A")))
    for _ in 0..<1000 {
        if await main.requests.count == 1 { break }
        try await Task.sleep(for: .milliseconds(2))
    }
    #expect(await deferred.requests.isEmpty)
    try await agent.receive(.init(id: "b", sessionID: "s", payload: .text("Stop A and explain B")))
    for _ in 0..<1000 {
        if await deferred.requests.count == 1 { break }
        try await Task.sleep(for: .milliseconds(2))
    }
    #expect(await deferred.requests.count == 1)
    await main.release()
    for _ in 0..<1000 {
        if await main.requests.count == 2 { break }
        try await Task.sleep(for: .milliseconds(2))
    }
    #expect(await main.requests.count == 2)
    await deferred.release()
    for _ in 0..<1000 {
        if logs.statuses["b"] != nil { break }
        try await Task.sleep(for: .milliseconds(2))
    }
    #expect(await probe.count == 0)
    #expect(logs.statuses["b"] == "target_expired")
    let request = try #require(await deferred.requests.last)
    #expect(request.messages.first?.content.contains("Explain A") == true)
    await agent.stop()
    pump.cancel()
    _ = await pump.result
}

@MainActor private final class BinaryLogProbe {
    var statuses: [String: String] = [:]
}
private actor DeferredBooleanChat: ChatCapability {
    let blocksFirst: Bool
    let replyValue: Bool?
    init(blocksFirst: Bool = false, replyValue: Bool? = nil) {
        self.blocksFirst = blocksFirst
        self.replyValue = replyValue
    }
    var availability: CapabilityAvailability { .available }
    var requests: [ChatRequest] = []
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?
    func release() {
        released = true
        waiter?.resume()
        waiter = nil
    }
    func chat(_ request: ChatRequest) async throws -> InferenceSession<ChatEvent> {
        requests.append(request)
        let subsequent = requests.count > 1
        let value = replyValue ?? subsequent
        if (blocksFirst ? requests.count == 1 : subsequent) && !released {
            await withTaskCancellationHandler {
                await withCheckedContinuation { waiter = $0 }
            } onCancel: {
                Task { await self.release() }
            }
        }
        try Task.checkCancellation()
        let pair = InferenceSession<ChatEvent>.make(limits: try StreamLimits(), estimatedBytes: { $0.estimatedBytes })
        try pair.emitter.yield(.text(value ? "true" : "false"))
        try pair.emitter.yield(.finished(.stop))
        pair.emitter.finish()
        return pair.session
    }
}

@Test(.actionCatalog, .timeLimit(.minutes(1))) @MainActor
func twoInterruptSignalsForOneReplyCancelOnlyOnceAndKeepBothInputs() async throws {
    let deferred = DeferredBooleanChat(blocksFirst: true, replyValue: true)
    let service = AssistantInputDecision(
        local: UnavailableDecision(), configuration: { (false, { deferred }) },
        timeout: .seconds(30), localTimeout: .seconds(5))
    let main = DeferredBooleanChat(blocksFirst: true)
    let context = try AgentContextRepository(
        agent: FixtureNativeChatState.agentID, scope: UUID().uuidString, state: FixtureNativeChatState())
    let logs = BinaryLogProbe()
    let agent = try FixtureNativeAgent(
        inputDecision: service, fullDuplex: true,
        decisionLog: { snapshot, outcome, _ in logs.statuses[snapshot.input.id] = outcome.signalStatus },
        chat: main, context: context)
    _ = try await bindSpeechRequests(agent)
    let pump = Task { for try await _ in FixtureGenerationOutputs(agent: agent) {} }
    let probe = InterruptProbe()
    await agent.bindInputInterruption { session in
        await probe.record()
        try await agent.receive(AssistantSessionControl.interruptSession.input(sessionID: session))
    }
    try await agent.start()
    try await agent.receive(.init(id: "original", sessionID: "s", payload: .text("Explain A")))
    for _ in 0..<1000 {
        if await main.requests.count == 1 { break }
        try await Task.sleep(for: .milliseconds(2))
    }
    #expect(await deferred.requests.isEmpty)
    try await agent.receive(.init(id: "interrupt-one", sessionID: "s", payload: .text("Stop and explain B")))
    try await agent.receive(.init(id: "interrupt-two", sessionID: "s", payload: .text("Stop and explain C")))
    await deferred.release()
    for _ in 0..<1000 {
        if logs.statuses["interrupt-two"] != nil, await main.requests.count == 2 { break }
        try await Task.sleep(for: .milliseconds(2))
    }
    #expect(await probe.count == 1)
    #expect(logs.statuses["interrupt-one"] == "interrupted")
    #expect(logs.statuses["interrupt-two"] == "target_expired")
    let request = try #require(await main.requests.last)
    let text = request.messages.map(\.content).joined(separator: "\n")
    #expect(text.contains("Stop and explain B") && text.contains("Stop and explain C"))
    await agent.stop()
    pump.cancel()
    _ = await pump.result
}

@Test func expiredDecisionIsAnExplicitFailureAndStartsNoInference() async throws {
    let cloud = DecisionCloudFixture(events: [.text("false"), .finished(.stop)])
    let service = decisionFixture(cloud: cloud)
    let input = AgentInput(id: "expired", sessionID: "s", payload: .text("Stop"))
    let result = await service.classify(
        .init(input: input, text: "Stop", receivedAt: ContinuousClock.now.advanced(by: .seconds(-60))))
    #expect(result.modelResult == nil && result.failure == .timedOut)
    #expect(await cloud.requests.isEmpty)
    await service.stop()
}

@Test(.actionCatalog, .timeLimit(.minutes(1)))
func unifiedInterruptLocksTargetAndPreservesQueuedInput() async throws {
    let main = DeferredBooleanChat(blocksFirst: true)
    let context = try AgentContextRepository(
        agent: FixtureNativeChatState.agentID, scope: UUID().uuidString, state: FixtureNativeChatState())
    let agent = try FixtureNativeAgent(fullDuplex: true, chat: main, context: context)
    _ = try await bindSpeechRequests(agent)
    let pump = Task { for try await _ in FixtureGenerationOutputs(agent: agent) {} }
    let probe = InterruptProbe()
    await agent.bindInputInterruption { session in
        await probe.record()
        try await agent.receive(AssistantSessionControl.interruptSession.input(sessionID: session))
    }
    try await agent.start()
    #expect(try await agent.requestInterrupt(AssistantInterrupt(), sessionID: "s") == .noTarget)
    try await agent.receive(.init(id: "first", sessionID: "s", payload: .text("Explain A")))
    for _ in 0..<1000 {
        if await main.requests.count == 1 { break }
        try await Task.sleep(for: .milliseconds(2))
    }
    let target = try #require(await agent.currentReplyID(sessionID: "s"))
    #expect(
        try await agent.requestInterrupt(AssistantInterrupt(target: .reply(target)), sessionID: "other")
            == .targetExpired)
    try await agent.receive(.init(id: "next", sessionID: "s", payload: .text("Explain B")))
    let signal = AssistantInterrupt()
    async let first = agent.requestInterrupt(signal, sessionID: "s")
    async let repeated = agent.requestInterrupt(signal, sessionID: "s")
    let outcomes = try await [first, repeated]
    #expect(outcomes.contains(.interrupted) && outcomes.contains(.duplicate))
    #expect(try await agent.requestInterrupt(signal, sessionID: "s") == .duplicate)
    #expect(
        try await agent.requestInterrupt(AssistantInterrupt(target: .reply(target)), sessionID: "s") == .targetExpired)
    for _ in 0..<1000 {
        if await main.requests.count == 2 { break }
        try await Task.sleep(for: .milliseconds(2))
    }
    #expect(await probe.count == 1)
    #expect(await main.requests.count == 2)
    #expect(await main.requests.last?.messages.contains(where: { $0.content.contains("Explain B") }) == true)
    await agent.stop()
    pump.cancel()
    _ = await pump.result
}

@Test(.actionCatalog)
func unifiedInterruptProtocolRejectsUntrustedLocalInputAndAcceptsHost() async throws {
    let model = DecisionCloudFixture(events: [.text("ok"), .finished(.stop)])
    let context = try AgentContextRepository(
        agent: FixtureNativeChatState.agentID, scope: UUID().uuidString, state: FixtureNativeChatState())
    let agent = try FixtureNativeAgent(fullDuplex: true, chat: model, context: context)
    try await agent.start()
    let signal = AssistantInterrupt()
    let contracts = try AgentContracts.communication
    #expect(try contracts.validatedSize(signal.message()) > 0)
    let invalid = AgentMessage(contract: AssistantInterrupt.contract, content: "stop", validate: { _ in })
    #expect(throws: CommunicationError.invalidPayload) { try contracts.validatedSize(invalid) }
    await #expect(throws: CommunicationError.unauthorized) {
        try await agent.receive(ProcessingContext(sessionID: "s", source: "user").input(.observation(signal.message())))
    }
    try await agent.receive(ProcessingContext(sessionID: "s", source: "runtime").input(.observation(signal.message())))
    #expect(await model.requests.isEmpty)
    #expect(await agent.status().queuedInputs == 0)
    await agent.stop()
}

@Test(.timeLimit(.minutes(1)))
func independentDecisionQueueBoundsAndJoinsCancellation() async throws {
    let classifier = DeferredBooleanChat(blocksFirst: true)
    let service = AssistantInputDecision(
        local: UnavailableDecision(), configuration: { (false, { classifier }) },
        timeout: .seconds(30), localTimeout: .seconds(5))
    let queue = AssistantDecisionQueue()
    let completions = InterruptProbe()
    for index in 0..<32 {
        let input = AgentInput(id: "q\(index)", sessionID: "s", payload: .text("hello"))
        try await queue.submit(
            .init(
                snapshot: .init(input: input, text: "hello"), target: nil,
                interrupt: { _, _ in
                    Issue.record("Unexpected signal")
                    return .noTarget
                },
                complete: { _, _, _ in await completions.record() }, updated: {}), using: service)
    }
    #expect(await queue.count == 32)
    let extra = AgentInput(id: "overflow", sessionID: "s", payload: .text("hello"))
    await #expect(throws: CommunicationError.capacityExceeded) {
        try await queue.submit(
            .init(
                snapshot: .init(input: extra, text: "hello"), target: nil,
                interrupt: { _, _ in
                    Issue.record("Unexpected signal")
                    return .noTarget
                },
                complete: { _, _, _ in await completions.record() }, updated: {}), using: service)
    }
    for _ in 0..<1000 {
        if await classifier.requests.count == 1 { break }
        try await Task.sleep(for: .milliseconds(2))
    }
    await queue.cancelAndWait()
    #expect(await queue.count == 0)
    #expect(await completions.count == 0)
    #expect(await classifier.requests.count == 1)
    await service.stop()
}

@Test(.actionCatalog, .timeLimit(.minutes(1)))
func unifiedInterruptGatewayRequiresDeclaredSenderPermission() async throws {
    func configuration(_ id: String, allowed: Bool = false) throws -> AgentConfiguration {
        try AgentConfiguration(
            contracts: AgentContracts.communication,
            data: JSONSerialization.data(withJSONObject: [
                "version": 8, "category": "cognition", "id": id, "actions": [String: [String]](), "tools": [],
                "communication": [
                    "inputs": id == "assistant"
                        ? [["contract": AssistantInterrupt.contract, "version": 1, "kind": "observation"]] : [],
                    "subscriptions": [], "publications": [],
                    "sends": allowed ? [["contract": AssistantInterrupt.contract, "target": "assistant"]] : [],
                ],
            ]))
    }
    let policy = try CommunicationPolicy(
        contracts: AgentContracts.communication,
        configurations: [
            configuration("assistant"), configuration("producer", allowed: true), configuration("untrusted"),
        ])
    let model = DecisionCloudFixture(events: [])
    let context = try AgentContextRepository(
        agent: FixtureNativeChatState.agentID, scope: UUID().uuidString, state: FixtureNativeChatState())
    let agent = try FixtureNativeAgent(fullDuplex: true, chat: model, context: context)
    let manager = AgentManager()
    let source = ObservationRecorder(id: "producer")
    let untrusted = ObservationRecorder(id: "untrusted")
    for item: any Agent in [agent, source, untrusted] {
        try await manager.register(item, sessionID: "s")
        try await item.start()
    }
    let input = InputGateway(manager: manager, policy: policy)
    let output = await OutputGateway(
        manager: manager, requests: input, tools: ToolRegistry(), policy: policy, sink: { _ in })
    let port = try await output.messaging(for: source.descriptor.id)
    let forbidden = try await output.messaging(for: untrusted.descriptor.id)
    let parent = AgentInput(id: "parent", sessionID: "s", payload: .text("event"))
    let report = try await port.send(AssistantInterrupt().message(), parent: parent, to: .assistant)
    #expect(report.delivered == [.assistant])
    await #expect(throws: CommunicationError.unauthorized) {
        try await forbidden.send(AssistantInterrupt().message(), parent: parent, to: .assistant)
    }
    #expect(await model.requests.isEmpty)
    await manager.stopAll()
}
