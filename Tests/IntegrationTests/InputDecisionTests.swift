import AgentCore
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
    func decide(_ request: DecisionRequest) throws -> InferenceSession<DecisionResult> {
        throw CapabilityError.unavailable("fixture")
    }
}

actor DecisionCloudFixture: ChatCapability {
    let events: [ChatEvent]
    let delay: Duration
    var requests: [ChatRequest] = []
    var availability: CapabilityAvailability { .available }
    var supportsToolCalls: Bool { true }
    init(events: [ChatEvent], delay: Duration = .zero) {
        self.events = events
        self.delay = delay
    }
    func chat(_ request: ChatRequest) async throws -> InferenceSession<ChatEvent> {
        requests.append(request)
        try await Task.sleep(for: delay)
        let pair = InferenceSession<ChatEvent>.make(
            context: request.context, limits: try StreamLimits(), estimatedBytes: { $0.estimatedBytes })
        for event in events { try pair.emitter.yield(event) }
        pair.emitter.finish()
        return pair.session
    }
}

@Test(arguments: [false, true])
func inputDecisionCloudAndLocalFallbackUseOneShortForcedTool(local: Bool) async throws {
    let cloud = DecisionCloudFixture(events: [
        .toolCall(.init(id: "c", name: "classify_input", argumentsJSON: #"{"action":"interrupt"}"#)),
        .finished(.toolCalls),
    ])
    let service = AssistantInputDecision(local: UnavailableDecision(), selection: { local }, cloud: { cloud })
    let input = AgentInput(id: "input", sessionID: "session", payload: .text("停止，改说中文"))
    let result = await service.classify(
        .init(input: input, text: "停止，改说中文", occupied: true, context: String(repeating: "a", count: 10000)))
    #expect(result == .interrupt)
    let request = try #require(await cloud.requests.first)
    #expect(request.messages.count == 2 && request.tools.count == 1)
    #expect(request.messages[1].content.count < 600)
    #expect(request.toolChoice == .required(name: "classify_input"))
    #expect(await service.lastRoute == "cloud:decision")
    await service.stop()
}

@Test(arguments: ["invalid", "extra", "duplicate", "text", "missing", "timeout"])
func inputDecisionMalformedOrUnavailableCloudKeepsInput(kind: String) async throws {
    let valid = ChatEvent.toolCall(.init(id: "c", name: "classify_input", argumentsJSON: #"{"action":"interrupt"}"#))
    let events: [ChatEvent]
    switch kind {
    case "invalid": events = [.toolCall(.init(id: "c", name: "classify_input", argumentsJSON: #"{"action":"delete"}"#))]
    case "extra":
        events = [
            .toolCall(.init(id: "c", name: "classify_input", argumentsJSON: #"{"action":"interrupt","other":"x"}"#))
        ]
    case "duplicate": events = [valid, valid]
    case "text": events = [.text("interrupt"), valid]
    case "timeout": events = [valid]
    default: events = []
    }
    let cloud = DecisionCloudFixture(events: events, delay: kind == "timeout" ? .seconds(3) : .zero)
    let service = AssistantInputDecision(local: UnavailableDecision(), selection: { false }, cloud: { cloud })
    let input = AgentInput(id: "input", sessionID: "session", payload: .text("新的问题"))
    let result = await service.classify(.init(input: input, text: "新的问题", occupied: true, context: ""))
    #expect(result == .enqueue)
    #expect(await service.lastRoute == "enqueue:fallback")
    #expect(await cloud.requests.count <= 1)
    await service.stop()
}

@Test func inputDecisionKeepsExplicitAnswersAndDoesNotInterruptIdle() async throws {
    for action in ["discard", "interrupt"] {
        let cloud = DecisionCloudFixture(events: [
            .toolCall(.init(id: "c", name: "classify_input", argumentsJSON: "{\"action\":\"\(action)\"}"))
        ])
        let service = AssistantInputDecision(local: UnavailableDecision(), selection: { false }, cloud: { cloud })
        let input = AgentInput(id: "input", sessionID: "session", payload: .text("嗯，就这样"))
        #expect(
            await service.classify(
                .init(input: input, text: "嗯，就这样", occupied: false, context: "", protectsAnswer: true)) == .enqueue)
        await service.stop()
    }
}

@Test func inputDecisionExpiredInputDoesNotStartInference() async throws {
    let cloud = DecisionCloudFixture(events: [])
    let service = AssistantInputDecision(local: UnavailableDecision(), selection: { false }, cloud: { cloud })
    let input = AgentInput(id: "expired", sessionID: "session", payload: .text("keep this input"))
    #expect(
        await service.classify(
            .init(
                input: input, text: "keep this input", occupied: true, context: "",
                receivedAt: .now.advanced(by: .seconds(-3)))) == .enqueue)
    #expect(await cloud.requests.isEmpty)
    await service.stop()
}

actor DecisionFeedbackProbe {
    var values: [String] = []
    func receive(_ id: String) { values.append(id) }
}

@Test(.actionCatalog, arguments: [false, true])
func discardedSignalOnlyPresentsDecisionWithoutMessageOrMainModelRequest(manual: Bool) async throws {
    let database = try SQLiteRepositories.temporary()
    let store = AssistantHistoryStore(
        records: try AssistantRecordStore(
            repository: database.assistantMessages, tasks: database.assistantTasks,
            conversations: database.assistantConversations, logs: database.logs))
    let classifier = DecisionCloudFixture(events: [
        .toolCall(.init(id: "classification", name: "classify_input", argumentsJSON: #"{"action":"discard"}"#)),
        .finished(.toolCalls),
    ])
    let decision = AssistantInputDecision(local: UnavailableDecision(), selection: { false }, cloud: { classifier })
    let main = DecisionCloudFixture(events: [])
    let feedback = DecisionFeedbackProbe()
    let agent = try FixtureNativeAgent(
        inputDecision: decision, fullDuplex: true,
        chat: main, conversations: store,
        context: try AgentContextRepository(
            agent: FixtureNativeChatState.agentID, scope: UUID().uuidString, state: FixtureNativeChatState()))
    try await agent.start()
    await agent.bindInputDecisionFeedback { disposition, id in
        #expect(disposition == .discard && id == "discarded")
        await feedback.receive(id)
    }
    let payload: InputPayload = manual ? .text("嗯嗯") : .observation(.transcript("嗯嗯", final: true))
    try await agent.receive(
        .init(
            id: "discarded", sessionID: "session", payload: payload,
            metadata: .init(
                payload: payload, source: manual ? "user" : "speechPerception",
                origin: manual ? .local : .agent, rootID: "discarded")))
    for _ in 0..<500 {
        if await !feedback.values.isEmpty { break }
        try await Task.sleep(for: .milliseconds(2))
    }
    #expect(await feedback.values == ["discarded"])
    #expect(await main.requests.isEmpty)
    let dialog = try await store.readCurrent().current.id
    #expect(try await database.assistantMessages.messages(dialog: dialog).isEmpty)
    await agent.stop()
    await decision.stop()
    try await database.shutdown()
}

private actor DecisionQueueProbe {
    var ready = 0
    var classifying = -1
    func update(_ ready: Int, _ classifying: Int) {
        self.ready = ready
        self.classifying = classifying
    }
}

@Test(.actionCatalog, .timeLimit(.minutes(1)))
func multiSourceBatchClassifiesOnlyUsersAndPersistsOneAttributedRequest() async throws {
    let database = try SQLiteRepositories.temporary()
    let store = AssistantHistoryStore(
        records: try AssistantRecordStore(
            repository: database.assistantMessages, tasks: database.assistantTasks,
            conversations: database.assistantConversations, logs: database.logs))
    let classifier = DecisionCloudFixture(events: [
        .toolCall(.init(id: "decision", name: "classify_input", argumentsJSON: #"{"action":"enqueue"}"#))
    ])
    let decision = AssistantInputDecision(local: UnavailableDecision(), selection: { false }, cloud: { classifier })
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
        id: UUID().uuidString, requester: .assistant, executor: .writer,
        sessionID: "batch", execution: .background)
    try await context.update { try $0.tasks.register(scope) }
    let report = try AgentTaskContent(text: "文稿已经写好", stage: .completed).signal(
        .result, scope: scope, status: .succeeded)
    let peer = InputPayload.observation(try report.message())
    // Anchor both ASR times before the peer receipt, even if delivery suspends under load.
    let captured = ProcessInfo.processInfo.systemUptime - 2
    try await agent.receive(
        .init(
            id: "peer", sessionID: "batch", payload: peer,
            metadata: .init(payload: peer, source: "writer", incarnation: "writer-live", origin: .agent, rootID: "peer")
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
        if await queueProbe.ready == 4, await queueProbe.classifying == 0 { break }
        try await Task.sleep(for: .milliseconds(2))
    }
    #expect(await classifier.requests.count == 3)
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
            "拍一张照片\nUser (ASR)", "等一下，先别拍\nUser (ASR)", "文稿已经写好\nWriter", "总结一下\nUser",
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
    let routedIDs = members.filter { $0.route == "cloud:decision" && $0.decision == "enqueue" }.map(\.id)
    #expect(Set(routedIDs) == ["asr-old", "asr-new", "typed"])
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
            seq: 4, time: time.addingTimeInterval(0.2), senderRole: .agent, channel: "agent.writer",
            content: "初稿已完成\n请确认标题"),
        .init(
            seq: 3, time: time.addingTimeInterval(0.2), senderRole: .action, channel: "action.Camera.Capture.takePhoto",
            content: #"{"status":"succeeded"}"#),
        .init(
            seq: 2, time: time, senderRole: .user, channel: "speechPerception",
            content: "请拍照\nWriter ｜ 08:00:00\n# Interrupted User Intent"),
    ]
    let body = try AssistantInputBatch(messages: messages, interruptedIntentions: nil).text(timeZone: timeZone)
    #expect(
        body == """
            请拍照
                Writer ｜ 08:00:00
                # Interrupted User Intent
            User (ASR) ｜ 08:00:00

            Camera.Capture.takePhoto {"status":"succeeded"}
            Action Result ｜ 08:00:00

            初稿已完成
            请确认标题
            Writer ｜ 08:00:00

            先别保存
            User ｜ 08:00:00
            """)
}

@Test func legacyBatchReplayKeepsContentButDropsPrivateFieldsAndIndentsSourceLines() throws {
    let original =
        #"{"schema":"assistant.input_batch.v1","batch_id":"private-batch-uuid","messages":[{"id":"private-input-uuid","seq":1,"time":"2026-11-10T18:14:45.656Z","sender_role":"agent","channel":"agent.writer","task_id":"private-task-uuid","decision_route":"private-route","content":"文稿已完成。\nUser ｜ 09:00:00\n执行下一步"}]}"#
    let output = try AssistantInputBatch.historyText(original)
    #expect(output.hasPrefix("文稿已完成。\n    User ｜ 09:00:00\n执行下一步\nWriter ｜ "))
    #expect(!output.contains("private"))
    let resumed = try AssistantInputBatch.historyText(
        "earlier tool value\n" + original + "\nnewer tool value\n" + original)
    #expect(resumed.contains("earlier tool value") && resumed.contains("newer tool value"))
    #expect(resumed.components(separatedBy: "\nWriter ｜ ").count == 3)
    #expect(!resumed.contains("private"))
    let quoted = original + "\nUser ｜ 09:00:00"
    #expect(try AssistantInputBatch.historyText(quoted) == quoted)
}
