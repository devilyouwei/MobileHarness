import AgentCore
import CallRuntime
import Foundation
import GRDB
import ModelKit
import ModelKitDefaults
import ModelKitRuntime
import StorageChat
import Synchronization
import Testing
import UI

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
    #expect(userMembers.allSatisfy { $0.route == nil && $0.interrupt == nil })
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
func binaryContextContainsOnlyCurrentReplyAndLatestInput(language: String) throws {
    try AgentPrompts.$language.withValue(language) {
        let snapshot = InputDecisionSnapshot(
            input: .init(id: "context", sessionID: "s", payload: .text("previous request and Web.Page.browse result")),
            text: "不是这个", currentAssistantReply: "北京是")
        let request = try snapshot.request()
        let pending = try InputDecisionSnapshot(input: snapshot.input, text: "等一下").request()
        let templates = try AgentPrompts.shared.load("Agents/Assistant/Input/InputDecision.json")
        #expect(
            try request.text == templates.render("context", variables: ["assistantReply": "北京是", "userInput": "不是这个"]))
        #expect(try pending.text == templates.render("context", variables: ["assistantReply": "", "userInput": "等一下"]))
        #expect(try request.instructions == templates.render("question"))
        #expect(!request.text.contains("previous request") && !request.text.contains("Web.Page.browse"))
        #expect(pending.instructions == request.instructions)
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

@Test(.actionCatalog, .timeLimit(.minutes(1)), arguments: [false, true])
func idleMessageDispatchesWithoutDecisionAndCannotInterruptItself(speech: Bool) async throws {
    let classifier = DecisionCloudFixture(events: [.text("true"), .finished(.stop)], delay: .milliseconds(300))
    let decision = decisionFixture(cloud: classifier)
    let main = DecisionCloudFixture(events: [.text("Hello"), .finished(.stop)], delay: .seconds(1))
    let probe = InterruptProbe()
    let context = try AgentContextRepository(
        agent: FixtureNativeChatState.agentID, scope: UUID().uuidString, state: FixtureNativeChatState())
    let agent = try FixtureNativeAgent(
        inputDecision: decision, fullDuplex: true, speechSessionID: "s", chat: main, context: context)
    await agent.bindFixtureInputInterruption { _ in await probe.record() }
    try await agent.start()
    if speech {
        try await agent.receive(speechSignal(SpeechActivity(.captureStarted, generation: "capture")))
        try await agent.receive(
            speechSignal(
                SpeechActivity(.onsetConfirmed, generation: "capture", utterance: "idle-turn")))
        try await agent.receive(keywordSignal("idle-turn"))
        #expect(await agent.interruptionWait == nil)
        let payload = InputPayload.observation(
            SpeechRecognition(.final, text: "Hello", generation: "capture").message())
        try await agent.receive(
            .init(
                id: "idle", sessionID: "s", payload: payload,
                metadata: .init(payload: payload, source: "speechPerception", origin: .agent, rootID: "idle"),
                turn: .init(id: "idle-turn", ordinal: 1)))
    } else {
        try await agent.receive(.init(id: "idle", sessionID: "s", payload: .text("Hello")))
    }
    for _ in 0..<100 {
        if await main.requests.count == 1 { break }
        try await Task.sleep(for: .milliseconds(2))
    }
    #expect(await main.requests.count == 1)
    try await Task.sleep(for: .milliseconds(400))
    #expect(await probe.count == 0)
    #expect(await agent.interruptionWait == nil)
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
    await agent.bindFixtureInputInterruption { _ in await probe.record() }
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
    let content = try #require(request.messages.first?.content)
    let templates = try AgentPrompts.shared.load("Agents/Assistant/Input/InputDecision.json", language: "en")
    #expect(
        try content.contains(
            templates.render("context", variables: ["assistantReply": "", "userInput": "Stop A and explain B"])))
    #expect(try content.contains(templates.render("question")))
    #expect(!content.contains("Explain A"))
    await agent.stop()
    pump.cancel()
    _ = await pump.result
}

@Test(.actionCatalog, .timeLimit(.minutes(1)), arguments: ["model", "keyword-first", "asr-first", "late-final"])
@MainActor
func keywordAndModelShareOneInterruptionAndLogTheWinningSignal(order: String) async throws {
    let keywordWins = order != "model"
    let keywordUtterance = order == "asr-first" ? "command" : "ongoing"
    let main = DeferredBooleanChat(blocksFirst: true)
    let classifier = DeferredBooleanChat(blocksFirst: true, replyValue: true)
    let decision = AssistantInputDecision(
        local: UnavailableDecision(), configuration: { (false, { classifier }) },
        timeout: .seconds(15), localTimeout: .seconds(5))
    let log = RuntimeLogState()
    let context = try AgentContextRepository(
        agent: FixtureNativeChatState.agentID, scope: UUID().uuidString, state: FixtureNativeChatState())
    let database = try SQLiteRepositories.temporary()
    let records = try AssistantRecordStore(
        repository: database.assistantMessages, tasks: database.assistantTasks,
        conversations: database.assistantConversations, logs: database.logs)
    let store = AssistantHistoryStore(records: records)
    let agent = try FixtureNativeAgent(
        inputDecision: decision, fullDuplex: true,
        decisionLog: { snapshot, outcome, duration in
            log.record(.decision(outcome.logItem(for: snapshot, duration: duration)))
        }, keywordLog: { log.record(.decision($0)) }, speechSessionID: "s", chat: main,
        conversations: store, listening: FullKeywordListening(), context: context)
    _ = try await bindSpeechRequests(agent)
    let adjustments = Mutex([OutputEnvelope]())
    let volumeCalls = Mutex([OutputEnvelope]())
    let pump = Task {
        for try await envelope in FixtureGenerationOutputs(agent: agent) {
            if case .actionControl = envelope.output {
                adjustments.withLock { $0.append(envelope) }
            } else if case .toolCall(let call) = envelope.output, call.toolPath == "Speech.Playback.setVolume" {
                volumeCalls.withLock { $0.append(envelope) }
            }
        }
    }
    defer { pump.cancel() }
    let cleanup = DecisionSettlementGate()
    let interrupts = InterruptProbe()
    await agent.bindFixtureInputInterruption { session in
        try await agent.receive(AssistantSessionControl.interruptSession.input(sessionID: session))
        await interrupts.record()
        await cleanup.wait()
    }
    try await agent.start()
    // An energy update can be the first event while both reply and playback are idle.
    try await agent.receive(
        speechSignal(
            SpeechActivity(.energyChanged, generation: "capture", utterance: "command", energy: .high)))
    #expect(adjustments.withLock { $0.isEmpty })
    try await agent.receive(speechSignal(SpeechActivity(.captureStarted, generation: "capture")))
    try await agent.receive(.init(id: "reply", sessionID: "s", payload: .text("Tell a story")))
    for _ in 0..<500 where await main.requests.isEmpty { try await Task.sleep(for: .milliseconds(2)) }
    try #require(await agent.currentReplyID(sessionID: "s") != nil)
    let playbackExecutionID = UUID().uuidString
    let playbackStarted = InputPayload.executionFeedback(
        .actionStarted(
            roundID: nil, callID: nil, executionID: playbackExecutionID,
            controlCapabilities: [ActionControl.Command.pause.rawValue, ActionControl.Command.resume.rawValue],
            path: .init(domain: "Speech", module: "Playback", function: "speak")))
    try await agent.receive(
        .init(
            id: "playback-start", sessionID: "s", payload: playbackStarted,
            metadata: .init(
                payload: playbackStarted, source: "runtime", origin: .runtime, rootID: "reply", parentID: "reply")))
    try await agent.receive(
        speechSignal(SpeechActivity(.onsetConfirmed, generation: "capture", utterance: "command")))
    let final = InputPayload.observation(
        SpeechRecognition(.final, text: "Stop the story", generation: "capture").message())
    try await agent.receive(
        .init(
            id: "command-final", sessionID: "s", payload: final,
            metadata: .init(payload: final, source: "speechPerception", origin: .agent, rootID: "command-final"),
            turn: .init(id: "command", ordinal: 1)))
    for _ in 0..<500 where await classifier.requests.isEmpty { try await Task.sleep(for: .milliseconds(2)) }
    try #require(await classifier.requests.count == 1)

    try await agent.receive(
        speechSignal(SpeechActivity(.onsetConfirmed, generation: "capture", utterance: "ongoing")))
    for _ in 0..<500 where adjustments.withLock({ $0.isEmpty }) { try await Task.sleep(for: .milliseconds(2)) }
    let pause = try #require(adjustments.withLock { $0.first })
    #expect(pause.inputID == "reply" && pause.roundID == nil)
    if case .actionControl(let control) = pause.output {
        #expect(control.executionID == playbackExecutionID)
        #expect(control.command == .pause)
    }

    try await agent.receive(
        speechSignal(
            SpeechActivity(
                .energyChanged, generation: "capture", utterance: "command", energy: .medium)))
    for _ in 0..<500 where volumeCalls.withLock({ $0.isEmpty }) { try await Task.sleep(for: .milliseconds(2)) }
    let volume = try #require(volumeCalls.withLock { $0.first })
    guard case .toolCall(let volumeCall) = volume.output else { throw HarnessError.invalidTransition }
    #expect(volumeCall.arguments == ["volume": "0.35", "executionID": playbackExecutionID])
    #expect(volume.roundID == nil && volume.callID == nil)
    try await agent.receive(
        speechSignal(SpeechActivity(.energyChanged, generation: "capture", utterance: "command", energy: .low)))
    for _ in 0..<500 where volumeCalls.withLock({ $0.count < 2 }) { try await Task.sleep(for: .milliseconds(2)) }
    let latestVolume = try #require(volumeCalls.withLock { $0.last })
    guard case .toolCall(let latestCall) = latestVolume.output else { throw HarnessError.invalidTransition }
    #expect(latestCall.arguments["volume"] == "1" && latestCall.id != volumeCall.id)
    #expect(adjustments.withLock { $0.count == 1 })
    try await agent.acceptDirectToolReply(
        .init(
            source: volume.source, inputID: volume.inputID, sequence: volume.sequence,
            tool: .init(callID: volumeCall.id, value: "completed", completion: .completed), failure: nil),
        envelope: volume)
    #expect(adjustments.withLock { $0.count == 1 })
    try await agent.acceptDirectToolReply(
        .init(
            source: latestVolume.source, inputID: latestVolume.inputID, sequence: latestVolume.sequence,
            tool: .init(callID: latestCall.id, value: "completed", completion: .completed), failure: nil),
        envelope: latestVolume)
    for _ in 0..<500 where adjustments.withLock({ $0.count < 2 }) { try await Task.sleep(for: .milliseconds(2)) }
    let resume = try #require(adjustments.withLock { $0.last })
    if case .actionControl(let control) = resume.output {
        #expect(control.executionID == playbackExecutionID && control.command == .resume)
    }
    try await agent.receive(
        speechSignal(
            SpeechActivity(.energyChanged, generation: "capture", utterance: "ongoing", energy: .high)
        ))
    for _ in 0..<500 where adjustments.withLock({ $0.count < 3 }) { try await Task.sleep(for: .milliseconds(2)) }

    if keywordWins {
        try await agent.receive(keywordSignal(keywordUtterance, inferenceDuration: .milliseconds(23)))
    } else {
        await classifier.release()
    }
    for _ in 0..<500 where await interrupts.count == 0 { try await Task.sleep(for: .milliseconds(2)) }
    #expect(await interrupts.count == 1)
    try await agent.receive(
        speechSignal(
            SpeechActivity(.energyChanged, generation: "capture", utterance: "ongoing", energy: .low))
    )
    try await agent.receive(keywordSignal("ongoing"))
    if order == "late-final" {
        await cleanup.release()
        for _ in 0..<500 where !log.decisions.contains(where: { $0.route == .keyword }) {
            try await Task.sleep(for: .milliseconds(2))
        }
        try #require(log.decisions.contains { $0.route == .keyword && $0.signalStatus == "interrupted" })
    }
    let text = keywordWins && keywordUtterance == "ongoing" ? "Stop now" : ""
    let finalSpeech = InputPayload.observation(SpeechRecognition(.final, text: text, generation: "capture").message())
    try await agent.receive(
        .init(
            id: "ongoing-final", sessionID: "s", payload: finalSpeech,
            metadata: .init(payload: finalSpeech, source: "speechPerception", origin: .agent, rootID: "ongoing-final"),
            turn: .init(id: "ongoing", ordinal: 2)))
    try await agent.receive(.init(id: "follow-up", sessionID: "s", payload: .text("Tell me something else")))
    try await finishVADWindow(agent)
    await cleanup.release()

    for _ in 0..<500 {
        if log.decisions.count >= (keywordWins ? 2 : 1), await main.requests.count == 2 { break }
        try await Task.sleep(for: .milliseconds(2))
    }
    #expect(await classifier.requests.count == 1)
    #expect(await interrupts.count == 1)
    #expect(adjustments.withLock({ $0.count }) == 3)
    #expect(volumeCalls.withLock({ $0.count }) == 2)
    let keyword = log.decisions.first { $0.route == .keyword }
    let model = log.decisions.first { $0.id == "command-final" }
    if keywordWins {
        #expect(keyword?.inputText == "stop")
        #expect(keyword?.signalStatus == "interrupted")
        #expect(keyword?.modelName == "Keyword Fixture" && keyword?.modelID == "fixture-kws")
        #expect(keyword?.duration == .milliseconds(220) && keyword?.inferenceDuration == .milliseconds(23))
        #expect(model?.signalStatus == "interrupt_superseded")
    } else {
        #expect(keyword == nil)
        #expect(model?.booleanResult == true && model?.signalStatus == "interrupted")
    }
    let followUp = await main.requests.last?.messages.map(\.content).joined(separator: "\n") ?? ""
    #expect(followUp.contains("Stop the story") && followUp.contains("Tell me something else"))
    let reopened = AssistantHistoryStore(records: records)
    let history = try await reopened.readCurrent().current
    let triggerID = keywordWins && keywordUtterance == "ongoing" ? "ongoing-final" : "command-final"
    let expectedRoute = keywordWins ? DecisionLogItem.Route.keyword.rawValue : "cloud:decision"
    let triggerRoute = try database.database.read {
        try String.fetchOne(
            $0,
            sql: """
                SELECT json_extract(user_input_json, '$.coordination.route')
                FROM assistant_messages
                WHERE input_key = ? AND json_extract(user_input_json, '$.coordination.interrupt') = 1
                UNION ALL
                SELECT json_extract(member.value, '$.route')
                FROM assistant_messages, json_each(user_input_json, '$.coordination.members') AS member
                WHERE input_key = 'command-final' AND json_extract(member.value, '$.id') = ?
                  AND json_extract(member.value, '$.interrupt') = 1
                LIMIT 1
                """, arguments: [triggerID, triggerID])
    }
    #expect(triggerRoute == expectedRoute)
    let page = try await reopened.page(history.id)
    let ui = try JSONDecoder().decode(HistoryConversation.self, from: JSONEncoder().encode(page))
    let row = try #require(ConversationHistoryPresentation.turns(ui).first { $0.ownerInputID == "command-final" })
    #expect(row.coordination?.effectiveInterrupt == true)
    let detail = try await reopened.message(try #require(row.messageID))
    let detailUI = try JSONDecoder().decode(HistoryConversation.self, from: JSONEncoder().encode(detail))
    let presented = try #require(ConversationHistoryPresentation.turns(detailUI).first)
    #expect(presented.coordination?.effectiveInterrupt == true)
    if triggerID != "command-final" {
        #expect(presented.coordination?.interruptingMember?.id == triggerID)
        #expect(presented.coordination?.interruptingMember?.route == expectedRoute)
    } else {
        #expect(presented.coordination?.route == expectedRoute)
    }
    await agent.stop()
    await decision.stop()
}

@MainActor private final class BinaryLogProbe {
    var statuses: [String: String] = [:]
}
private actor DeferredBooleanChat: ChatCapability {
    let blocksFirst: Bool
    let replyValue: Bool?
    let firstReply: String?
    init(blocksFirst: Bool = false, replyValue: Bool? = nil, firstReply: String? = nil) {
        self.blocksFirst = blocksFirst
        self.replyValue = replyValue
        self.firstReply = firstReply
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
        try pair.emitter.yield(.text((subsequent ? nil : firstReply) ?? (value ? "true" : "false")))
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
    let database = try SQLiteRepositories.temporary()
    let store = AssistantHistoryStore(
        records: try AssistantRecordStore(
            repository: database.assistantMessages, tasks: database.assistantTasks,
            conversations: database.assistantConversations, logs: database.logs))
    let agent = try FixtureNativeAgent(
        inputDecision: service, fullDuplex: true,
        decisionLog: { snapshot, outcome, _ in logs.statuses[snapshot.input.id] = outcome.signalStatus },
        chat: main, conversations: store, context: context)
    _ = try await bindSpeechRequests(agent)
    let pump = Task { for try await _ in FixtureGenerationOutputs(agent: agent) {} }
    let probe = InterruptProbe()
    await agent.bindFixtureInputInterruption { session in
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
    #expect(logs.statuses["interrupt-one"] == "superseded")
    #expect(logs.statuses["interrupt-two"] == "interrupted")
    let history = try await store.readCurrent().current.turns
    #expect(history.first { $0.id == "interrupt-one" }?.coordination?.interrupt == nil)
    #expect(history.first { $0.id == "interrupt-two" }?.coordination?.interrupt == true)
    let request = try #require(await main.requests.last)
    let text = request.messages.map(\.content).joined(separator: "\n")
    #expect(text.contains("Stop and explain B") && text.contains("Stop and explain C"))
    await agent.stop()
    pump.cancel()
    _ = await pump.result
}

private actor PartialReplyChat: ChatCapability {
    var availability: CapabilityAvailability { .available }
    var requests = 0
    func chat(_ request: ChatRequest) async throws -> InferenceSession<ChatEvent> {
        requests += 1
        let pair = InferenceSession<ChatEvent>.make(limits: try StreamLimits(), estimatedBytes: { $0.estimatedBytes })
        try pair.emitter.yield(.text("Part of a long reply"))
        guard requests == 1 else {
            try pair.emitter.yield(.finished(.stop))
            pair.emitter.finish()
            return pair.session
        }
        // The first reply keeps streaming until the interrupt cancels it.
        Task {
            try? await Task.sleep(for: .seconds(30))
            pair.emitter.finish()
        }
        return pair.session
    }
}

@Test(.actionCatalog, .timeLimit(.minutes(1))) @MainActor
func interruptedReplyIsRecordedAsInterruptedAndTheInterruptingInputKeepsItsDecision() async throws {
    let decision = DeferredBooleanChat(blocksFirst: false, replyValue: true)
    let service = AssistantInputDecision(
        local: UnavailableDecision(), configuration: { (false, { decision }) },
        timeout: .seconds(30), localTimeout: .seconds(5))
    let main = PartialReplyChat()
    let context = try AgentContextRepository(
        agent: FixtureNativeChatState.agentID, scope: UUID().uuidString, state: FixtureNativeChatState())
    let database = try SQLiteRepositories.temporary()
    let store = AssistantHistoryStore(
        records: try AssistantRecordStore(
            repository: database.assistantMessages, tasks: database.assistantTasks,
            conversations: database.assistantConversations, logs: database.logs))
    let agent = try FixtureNativeAgent(
        inputDecision: service, fullDuplex: true, chat: main, conversations: store, context: context)
    _ = try await bindSpeechRequests(agent)
    let pump = Task { for try await _ in FixtureGenerationOutputs(agent: agent) {} }
    await agent.bindFixtureInputInterruption { session in
        try await agent.receive(AssistantSessionControl.interruptSession.input(sessionID: session))
    }
    try await agent.start()
    try await agent.receive(.init(id: "original", sessionID: "s", payload: .text("Tell a long story")))
    for _ in 0..<1000 {
        if await main.requests == 1 { break }
        try await Task.sleep(for: .milliseconds(2))
    }
    try await agent.receive(.init(id: "stop", sessionID: "s", payload: .text("Stop")))
    var turns: [AssistantRecord] = []
    for _ in 0..<1000 {
        turns = try await store.readCurrent().current.turns
        if turns.first(where: { $0.id == "original" })?.state == .interrupted, await main.requests == 2 { break }
        try await Task.sleep(for: .milliseconds(2))
    }
    #expect(turns.first { $0.id == "original" }?.state == .interrupted)
    #expect(turns.first { $0.id == "stop" }?.coordination?.interrupt == true)
    await agent.stop()
    pump.cancel()
    _ = await pump.result
}

@Test(.actionCatalog, .timeLimit(.minutes(1)))
func replyFinishedGeneratingButStillPlayingIsRecordedAsInterrupted() async throws {
    let main = DecisionCloudFixture(events: [.text("A long story"), .finished(.stop)])
    let context = try AgentContextRepository(
        agent: FixtureNativeChatState.agentID, scope: UUID().uuidString, state: FixtureNativeChatState())
    let database = try SQLiteRepositories.temporary()
    let store = AssistantHistoryStore(
        records: try AssistantRecordStore(
            repository: database.assistantMessages, tasks: database.assistantTasks,
            conversations: database.assistantConversations, logs: database.logs))
    let agent = try FixtureNativeAgent(fullDuplex: true, chat: main, conversations: store, context: context)
    let speech = try await bindSpeechRequests(agent)
    await speech.setPlaying(true)
    let pump = Task { for try await _ in FixtureGenerationOutputs(agent: agent) {} }
    await agent.bindFixtureInputInterruption { session in
        try await agent.receive(AssistantSessionControl.interruptSession.input(sessionID: session))
    }
    try await agent.start()
    try await agent.receive(.init(id: "story", sessionID: "s", payload: .text("Tell a story")))
    for _ in 0..<1000 {
        if try await store.readCurrent().current.turns.first?.state == .completed { break }
        try await Task.sleep(for: .milliseconds(2))
    }
    #expect(try await agent.requestInterrupt(AssistantInterrupt(), sessionID: "s") == .interrupted)
    let turns = try await store.readCurrent().current.turns
    #expect(turns.first { $0.id == "story" }?.state == .interrupted)
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
    await agent.bindFixtureInputInterruption { session in
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

private func speechSignal(_ activity: SpeechActivity, session: String = "s") -> AgentInput {
    let payload = InputPayload.observation(activity.message())
    let id = UUID().uuidString
    return AgentInput(
        id: id, sessionID: session, payload: payload,
        metadata: InputMetadata(
            payload: payload, source: AgentID.speechPerception.rawValue, incarnation: "i", origin: .agent, rootID: id,
            topic: SpeechActivity.channel))
}

private func finishVADWindow(
    _ agent: FixtureNativeAgent, generation: String = "capture"
) async throws {
    _ = try #require(await agent.interruptionWait)
    try await agent.receive(
        speechSignal(
            SpeechActivity(
                .vadProgress, generation: generation,
                oldestWindow: SpeechSignalClock.offset(at: .now))))
}

private func keywordSignal(
    _ utterance: String, generation: String = "capture", label: String = "en-stop",
    onset: ContinuousClock.Instant = .now, inferenceDuration: Duration? = nil
) -> AgentInput {
    let started = SpeechSignalClock.offset(at: onset)
    let match = SpeechKeywordMatch(
        generation: generation, utterance: utterance, label: label, keyword: "stop",
        onset: started, matchedAt: SpeechSignalClock.offset(at: .now),
        detection: inferenceDuration.map {
            .init(
                modelID: "fixture-kws", modelName: "Keyword Fixture", inferenceDuration: $0,
                completedAt: started + .milliseconds(220))
        })
    let payload = InputPayload.observation(match.message())
    let id = UUID().uuidString
    return AgentInput(
        id: id, sessionID: "s", payload: payload,
        metadata: .init(
            payload: payload, source: "speechPerception", incarnation: "i", origin: .agent, rootID: id,
            topic: SpeechKeywordMatch.channel),
        turn: .init(id: utterance, ordinal: 1))
}

private final class QuietListeningProbe: ListeningControlling, Sendable {
    private let texts = Mutex<[String]>([])
    var received: [String] { texts.withLock { $0 } }
    var isListening: Bool { false }
    func apply(_ listening: Bool, source: AgentStateSource, wakeCondition: String?) async throws {}
    func receiveQuiet(_ text: String, _ input: AgentInput) { texts.withLock { $0.append(text) } }
}

@Test(.actionCatalog, .timeLimit(.minutes(1)))
func speechActivityIsAcceptedOnlyFromTheSubscribedPerceptionAgent() async throws {
    let context = try AgentContextRepository(
        agent: FixtureNativeChatState.agentID, scope: UUID().uuidString, state: FixtureNativeChatState())
    let agent = try FixtureNativeAgent(
        fullDuplex: true, speechSessionID: "s", chat: DeferredBooleanChat(blocksFirst: false), context: context)
    try await agent.start()
    try await agent.receive(speechSignal(SpeechActivity(.captureStarted, generation: "capture")))
    let forged = speechSignal(SpeechActivity(.onsetConfirmed, generation: "capture", utterance: "u"))
    let impostor = AgentInput(
        id: forged.id, sessionID: "s", payload: forged.payload,
        metadata: InputMetadata(
            payload: forged.payload, source: "writer", incarnation: "i", origin: .agent, rootID: forged.id,
            topic: SpeechActivity.channel))
    await #expect(throws: CommunicationError.unauthorized) { try await agent.receive(impostor) }
    try await agent.receive(
        speechSignal(SpeechActivity(.onsetConfirmed, generation: "capture", utterance: "u")))
    #expect(await agent.speechUtterances == ["u"])
    await agent.stop()
}

@Test(.actionCatalog, .timeLimit(.minutes(1)))
func quietFinalSpeechIsJudgedInsteadOfEnteringTheConversation() async throws {
    let main = DeferredBooleanChat(blocksFirst: false)
    let context = try AgentContextRepository(
        agent: FixtureNativeChatState.agentID, scope: UUID().uuidString, state: FixtureNativeChatState())
    let listening = QuietListeningProbe()
    let agent = try FixtureNativeAgent(
        fullDuplex: true, speechSessionID: "s", chat: main, listening: listening, context: context)
    try await agent.start()
    try await agent.receive(speechSignal(SpeechActivity(.captureStarted, generation: "capture")))
    try await agent.receive(
        speechSignal(SpeechActivity(.onsetConfirmed, generation: "capture", utterance: "u")))
    let payload = InputPayload.observation(.transcript("let me think", final: true))
    try await agent.receive(
        AgentInput(
            id: "final", sessionID: "s", payload: payload,
            metadata: .init(payload: payload, source: "speechPerception", origin: .agent, rootID: "final"),
            turn: .init(id: "u", ordinal: 1)))
    #expect(listening.received == ["let me think"])
    #expect(await agent.speechUtterances.isEmpty)
    #expect(await main.requests.isEmpty)
    await agent.stop()
}

@Test(
    .actionCatalog, .timeLimit(.minutes(1)),
    arguments: [
        "noSpeech", "candidate", "candidateClears", "final", "duringCleanup", "twoTurns", "empty",
        "deliveryFailure", "captureClosed",
    ])
func interruptedSpeechWaitsForWindowAndFinalAdmission(scenario: String) async throws {
    let main = DeferredBooleanChat(blocksFirst: true)
    let context = try AgentContextRepository(
        agent: FixtureNativeChatState.agentID, scope: UUID().uuidString, state: FixtureNativeChatState())
    let agent = try FixtureNativeAgent(fullDuplex: true, speechSessionID: "s", chat: main, context: context)
    _ = try await bindSpeechRequests(agent)
    let pump = Task { for try await _ in FixtureGenerationOutputs(agent: agent) {} }
    let generation = UUID().uuidString
    try await agent.receive(speechSignal(SpeechActivity(.captureStarted, generation: generation)))
    await agent.bindFixtureInputInterruption { session in
        if scenario == "duringCleanup" {
            try await agent.receive(
                speechSignal(
                    SpeechActivity(.onsetConfirmed, generation: generation, utterance: "new-turn")))
        }
        try await agent.receive(AssistantSessionControl.interruptSession.input(sessionID: session))
    }
    try await agent.start()
    try await agent.receive(.init(id: "original", sessionID: "s", payload: .text("original")))
    for _ in 0..<1000 {
        if await main.requests.count == 1 { break }
        try await Task.sleep(for: .milliseconds(2))
    }
    try #require(await main.requests.count == 1)
    try await agent.receive(.init(id: "queued", sessionID: "s", payload: .text("stop")))
    if ["final", "twoTurns", "empty", "deliveryFailure"].contains(scenario) {
        try await agent.receive(
            speechSignal(
                SpeechActivity(.onsetConfirmed, generation: generation, utterance: "new-turn")))
    }
    func finalInput(id: String, turn: String, text: String) -> AgentInput {
        let payload = InputPayload.observation(.transcript(text, final: true))
        return AgentInput(
            id: id, sessionID: "s", payload: payload,
            metadata: .init(payload: payload, source: "speechPerception", origin: .agent, rootID: id),
            turn: .init(id: turn, ordinal: 1))
    }
    if scenario == "twoTurns" {
        try await agent.receive(
            speechSignal(
                SpeechActivity(.onsetConfirmed, generation: generation, utterance: "next-turn")))
    }
    #expect(try await agent.requestInterrupt(AssistantInterrupt(), sessionID: "s") == .interrupted)
    #expect(await main.requests.count == 1)
    if scenario == "captureClosed" {
        try await agent.receive(speechSignal(SpeechActivity(.captureStopped, generation: generation)))
        try await agent.receive(speechSignal(SpeechActivity(.captureStarted, generation: "recovered")))
        try await finishVADWindow(agent, generation: generation)
        #expect(await agent.interruptionWait != nil)
    }
    if scenario == "empty" {
        try await agent.receive(finalInput(id: "empty-final", turn: "new-turn", text: ""))
    }
    if scenario == "twoTurns" {
        try await agent.receive(finalInput(id: "early", turn: "new-turn", text: "first addition"))
    }
    if ["candidate", "candidateClears", "noSpeech"].contains(scenario) {
        try await agent.receive(
            speechSignal(
                SpeechActivity(.vadProgress, generation: generation, sequence: 63)))
        #expect(await agent.interruptionWait != nil)
    }
    if ["candidate", "candidateClears"].contains(scenario) {
        try await agent.receive(speechSignal(SpeechActivity(.onsetStarted, generation: generation)))
    }
    #expect(await main.requests.count == 1)
    try await finishVADWindow(
        agent, generation: scenario == "captureClosed" ? "recovered" : generation)
    if ["candidate", "candidateClears"].contains(scenario) {
        #expect(await agent.interruptionWait != nil)
        #expect(await main.requests.count == 1)
        if scenario == "candidate" {
            try await agent.receive(
                speechSignal(
                    SpeechActivity(.onsetConfirmed, generation: generation, utterance: "new-turn")))
            try await agent.receive(finalInput(id: "final", turn: "new-turn", text: "continue speaking"))
        }
        if scenario == "candidateClears" {
            try await agent.receive(
                speechSignal(SpeechActivity(.onsetCleared, generation: generation)))
        }
    }
    if ["final", "duringCleanup", "deliveryFailure", "twoTurns"].contains(scenario) {
        try await agent.receive(finalInput(id: "stale-final", turn: "stale-turn", text: ""))
        let turn = scenario == "twoTurns" ? "next-turn" : "new-turn"
        let input = finalInput(id: "final", turn: turn, text: "continue speaking")
        if scenario != "deliveryFailure" {
            try await agent.receive(input)
        } else {
            await agent.speechPublicationFailed(input, reason: "rejected")
        }
    }
    for _ in 0..<2000 {
        if await main.requests.count == 2 { break }
        try await Task.sleep(for: .milliseconds(2))
    }
    #expect(await main.requests.count == 2)
    let text = await main.requests.last?.messages.map(\.content).joined(separator: "\n") ?? ""
    #expect(text.contains("stop"))
    if ["candidate", "final", "duringCleanup", "twoTurns"].contains(scenario) {
        #expect(text.contains("continue speaking"))
    }
    if scenario == "twoTurns" { #expect(text.contains("first addition")) }
    await agent.stop()
    pump.cancel()
    _ = await pump.result
}

@Test(
    .actionCatalog, .timeLimit(.minutes(1)),
    arguments: ["finalBeforeOnset", "finalBeforeCleanup", "finalAfterCleanup"])
func onsetAfterThe64thWindowStaysOutOfTheRetainedBatch(order: String) async throws {
    let main = DeferredBooleanChat(blocksFirst: true)
    let agent = try FixtureNativeAgent(
        fullDuplex: true, speechSessionID: "s", chat: main,
        context: AgentContextRepository(
            agent: FixtureNativeChatState.agentID, scope: UUID().uuidString, state: FixtureNativeChatState()))
    _ = try await bindSpeechRequests(agent)
    let pump = Task { for try await _ in FixtureGenerationOutputs(agent: agent) {} }
    let cleanupStarted = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    let cleanupDone = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    defer {
        cleanupDone.continuation.finish()
        pump.cancel()
    }
    await agent.bindFixtureInputInterruption { session in
        try await agent.receive(AssistantSessionControl.interruptSession.input(sessionID: session))
        cleanupStarted.continuation.yield(())
        var done = cleanupDone.stream.makeAsyncIterator()
        _ = await done.next()
    }
    try await agent.start()
    try await agent.receive(speechSignal(SpeechActivity(.captureStarted, generation: "capture")))
    try await agent.receive(.init(id: "original", sessionID: "s", payload: .text("original")))
    for _ in 0..<400 where await main.requests.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
    try #require(await main.requests.count == 1)
    try await agent.receive(.init(id: "retained", sessionID: "s", payload: .text("retained request")))

    let cancellation = Task { try await agent.requestInterrupt(.init(), sessionID: "s") }
    var started = cleanupStarted.stream.makeAsyncIterator()
    _ = try #require(await started.next())
    try await finishVADWindow(agent)
    let proof = SpeechSignalClock.offset(at: .now)
    let value = SpeechRecognition(
        .final, text: "late request", generation: "capture", oldestWindowBeforeOnset: proof)
    let payload = InputPayload.observation(value.message())
    let final = AgentInput(
        id: "late-final", sessionID: "s", payload: payload,
        metadata: .init(payload: payload, source: "speechPerception", origin: .agent, rootID: "late-final"),
        turn: .init(id: "late", ordinal: 1))
    if order == "finalBeforeOnset" { try await agent.receive(final) }
    try await agent.receive(
        speechSignal(
            SpeechActivity(
                .onsetStarted, generation: "capture", oldestWindowBeforeOnset: proof)))
    try await agent.receive(
        speechSignal(
            SpeechActivity(
                .onsetConfirmed, generation: "capture", utterance: "late",
                oldestWindowBeforeOnset: proof)))
    if order == "finalBeforeCleanup" { try await agent.receive(final) }

    cleanupDone.continuation.yield(())
    #expect(try await cancellation.value == .interrupted)
    for _ in 0..<400 where await main.requests.count < 2 { try await Task.sleep(for: .milliseconds(5)) }
    let second = try #require(await main.requests.dropFirst().first)
    #expect(second.messages.contains { $0.content.contains("retained request") })
    #expect(!second.messages.contains { $0.content.contains("late request") })
    if order == "finalAfterCleanup" { try await agent.receive(final) }
    for _ in 0..<400 where await main.requests.count < 3 { try await Task.sleep(for: .milliseconds(5)) }
    #expect(await main.requests.count == 3)
    #expect(await main.requests.last?.messages.contains { $0.content.contains("late request") } == true)
    await agent.stop()
}

@Test(.actionCatalog, .timeLimit(.minutes(1)), arguments: ["shortSpeech", "longSpeech", "slowCleanup"])
func decisionInterruptKeepsFullWindowForFollowUpSpeech(scenario: String) async throws {
    let main = DeferredBooleanChat(blocksFirst: true)
    let cloud = DecisionCloudFixture(events: [.text("true"), .finished(.stop)])
    let decision = decisionFixture(cloud: cloud)
    let context = try AgentContextRepository(
        agent: FixtureNativeChatState.agentID, scope: UUID().uuidString, state: FixtureNativeChatState())
    let agent = try FixtureNativeAgent(
        inputDecision: decision, fullDuplex: true, speechSessionID: "s", chat: main, context: context)
    _ = try await bindSpeechRequests(agent)
    let pump = Task { for try await _ in FixtureGenerationOutputs(agent: agent) {} }
    defer { pump.cancel() }
    let cleanup = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    await agent.bindFixtureInputInterruption { session in
        try await agent.receive(
            speechSignal(SpeechActivity(.onsetConfirmed, generation: "capture", utterance: "next")))
        try await agent.receive(AssistantSessionControl.interruptSession.input(sessionID: session))
        if scenario == "slowCleanup" {
            try await finishVADWindow(agent)
            #expect(await main.requests.count == 1)
        }
        cleanup.continuation.yield(())
    }
    try await agent.start()
    try await agent.receive(speechSignal(SpeechActivity(.captureStarted, generation: "capture")))
    try await agent.receive(.init(id: "original", sessionID: "s", payload: .text("tell a story")))
    for _ in 0..<400 where await main.requests.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
    try #require(await main.requests.count == 1)

    func final(id: String, turn: String, text: String) -> AgentInput {
        let payload = InputPayload.observation(.transcript(text, final: true))
        return AgentInput(
            id: id, sessionID: "s", payload: payload,
            metadata: .init(payload: payload, source: "speechPerception", origin: .agent, rootID: id),
            turn: .init(id: turn, ordinal: 1))
    }
    try await agent.receive(
        speechSignal(SpeechActivity(.onsetConfirmed, generation: "capture", utterance: "command")))
    try await agent.receive(final(id: "command-final", turn: "command", text: "please stop"))
    var observed = cleanup.stream.makeAsyncIterator()
    _ = try #require(await observed.next())

    if scenario == "longSpeech" {
        try await finishVADWindow(agent)
        #expect(await main.requests.count == 1)
        #expect(await agent.interruptionWait != nil)
    }
    try await agent.receive(final(id: "next-final", turn: "next", text: "tell me something else"))
    if scenario == "shortSpeech" {
        #expect(await agent.interruptionWait != nil)
        try await finishVADWindow(agent)
    }
    for _ in 0..<600 where await main.requests.count < 2 { try await Task.sleep(for: .milliseconds(5)) }
    #expect(await main.requests.count == 2)
    let prompt = await main.requests.last?.messages.map(\.content).joined(separator: "\n") ?? ""
    #expect(prompt.contains("please stop"))
    #expect(prompt.contains("tell me something else"))
    await agent.stop()
    await decision.stop()
}

@Test(.actionCatalog, .timeLimit(.minutes(1)), arguments: [false, true])
func modelInterruptObservesVADWhilePlaybackActionCleansUp(keyword: Bool) async throws {
    let main = DeferredBooleanChat()
    let context = try AgentContextRepository(
        agent: FixtureNativeChatState.agentID, scope: UUID().uuidString, state: FixtureNativeChatState())
    let agent = try FixtureNativeAgent(
        fullDuplex: true, speechSessionID: "s", chat: main, listening: FullKeywordListening(), context: context)
    let nativeStopRequested = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    let nativeStopped = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    let speech = try await bindSpeechRequests(agent)
    let pump = Task { for try await _ in FixtureGenerationOutputs(agent: agent) {} }
    defer {
        nativeStopped.continuation.finish()
        pump.cancel()
    }
    await agent.bindFixtureInputInterruption { session in
        try await agent.receive(
            speechSignal(
                SpeechActivity(
                    .onsetConfirmed, generation: "capture", utterance: "follow-up")))
        try await agent.receive(AssistantSessionControl.interruptSession.input(sessionID: session))
        nativeStopRequested.continuation.yield(())
        var iterator = nativeStopped.stream.makeAsyncIterator()
        _ = await iterator.next()
    }
    try await agent.start()
    try await agent.receive(speechSignal(SpeechActivity(.captureStarted, generation: "capture")))
    try await agent.receive(.init(id: "old-reply", sessionID: "s", payload: .text("Tell a story")))
    for _ in 0..<400 {
        if await main.requests.count == 1, await agent.worker == nil { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    try #require(await main.requests.count == 1)
    try #require(await agent.worker == nil)
    await speech.setPlaying(true)
    let target = try #require(await agent.currentReplyID(sessionID: "s"))
    if keyword {
        try await agent.receive(
            speechSignal(SpeechActivity(.onsetConfirmed, generation: "capture", utterance: "keyword"))
        )
    }
    let interruption = Task {
        if keyword {
            try await agent.receive(keywordSignal("keyword"))
            return AssistantInterruptResult.interrupted
        }
        return try await agent.requestInterrupt(
            AssistantInterrupt(target: .reply(target)), sessionID: "s", source: "decision")
    }
    defer { interruption.cancel() }
    var stopRequests = nativeStopRequested.stream.makeAsyncIterator()
    _ = try #require(await stopRequests.next())
    if keyword {
        try await agent.receive(
            .init(
                id: "empty-keyword-final", sessionID: "s",
                payload: .observation(.transcript("", final: true)),
                turn: .init(id: "keyword", ordinal: 1)))
    }
    let payload = InputPayload.observation(.transcript("tell me something else", final: true))
    try await agent.receive(
        .init(
            id: "follow-up-final", sessionID: "s", payload: payload,
            metadata: .init(payload: payload, source: "speechPerception", origin: .agent, rootID: "follow-up-final"),
            turn: .init(id: "follow-up", ordinal: 1)))
    try await finishVADWindow(agent)
    #expect(await main.requests.count == 1)

    await speech.setPlaying(false)
    nativeStopped.continuation.yield(())
    #expect(try await interruption.value == .interrupted)
    for _ in 0..<600 where await main.requests.count < 2 { try await Task.sleep(for: .milliseconds(5)) }
    let followUp = await main.requests.last?.messages
    #expect(followUp?.contains(where: { $0.content.contains("tell me something else") }) == true)
    await agent.stop()
}

@Test(.actionCatalog, .timeLimit(.minutes(1)), arguments: [false, true], [false, true])
func interruptedReplyPersistsCompletedActionsAcrossTracks(keepCompleted: Bool, keyword: Bool) async throws {
    let expression = "<express emotion='happy'/>"
    let omitted = "删掉 &amp; missed."
    let captionText = "保留 &amp; kept."
    let original = expression + omitted + expression + captionText
    let main = DeferredBooleanChat(firstReply: original)
    let classifier = DeferredBooleanChat(replyValue: true)
    let decision = AssistantInputDecision(local: UnavailableDecision(), configuration: { (false, { classifier }) })
    let database = try SQLiteRepositories.temporary()
    let records = try AssistantRecordStore(
        repository: database.assistantMessages, tasks: database.assistantTasks,
        conversations: database.assistantConversations, logs: database.logs)
    let store = AssistantHistoryStore(records: records)
    let context = try AgentContextRepository(
        agent: FixtureNativeChatState.agentID, scope: UUID().uuidString, state: FixtureNativeChatState())
    let agent = try FixtureNativeAgent(
        inputDecision: decision, fullDuplex: true, speechSessionID: "s", chat: main,
        conversations: store, listening: FullKeywordListening(), context: context)
    _ = try await bindSpeechRequests(agent)
    let calls = AsyncStream<OutputEnvelope>.makeStream(bufferingPolicy: .bufferingOldest(16))
    let pump = Task {
        for await envelope in fixtureOutputs(agent) where envelope.inputID == "first-reply" {
            calls.continuation.yield(envelope)
            if case .roundFinished = envelope.output { break }
        }
        calls.continuation.finish()
    }
    defer { pump.cancel() }
    try await agent.start()
    try await agent.receive(.init(id: "first-reply", sessionID: "s", payload: .text("Tell a story")))
    var sent: [OutputEnvelope] = []
    var sealed: OutputEnvelope?
    for await envelope in calls.stream {
        switch envelope.output {
        case .actionCall: sent.append(envelope)
        case .roundFinished: sealed = envelope
        default: break
        }
    }
    let actions = sent
    let seal = try #require(sealed)
    let round = try #require(seal.roundID)
    try #require(actions.count == 6)

    @Sendable func feedback(_ payload: InputPayload, from envelope: OutputEnvelope) async throws {
        try await agent.receive(
            .init(
                id: UUID().uuidString, sessionID: envelope.sessionID, payload: payload,
                metadata: .init(
                    payload: payload, source: "runtime", origin: .runtime,
                    rootID: envelope.inputMetadata.rootID, parentID: envelope.inputID),
                turn: envelope.turn))
    }

    @Sendable func complete(_ envelope: OutputEnvelope, status: ActionResult.Status) async throws {
        guard case .actionCall(let call) = envelope.output else { throw HarnessError.unsupportedInput }
        let receipt = ActionResult(
            executionID: UUID().uuidString,
            owner: .init(agent: envelope.source, incarnation: "fixture", sessionID: envelope.sessionID),
            path: call.actionPath, causality: SignalCausality(envelope: envelope), status: status,
            effect: status == .succeeded ? .contractCompleted : .unknown, completion: .completed,
            callID: envelope.callID, roundID: round)
        try await feedback(.executionFeedback(.actionFinished(receipt)), from: envelope)
    }

    let success: ActionResult.Status = keepCompleted ? .succeeded : .cancelled
    // The Display track completes before the earlier Expression track.
    try await complete(actions[5], status: success)
    try await complete(actions[0], status: success)
    try await complete(actions[1], status: .failed)
    try await complete(actions[2], status: .cancelled)
    await agent.bindFixtureInputInterruption { session in
        // A valid terminal delivered during cleanup still contributes to the settled reply.
        try await complete(actions[3], status: success)
        try await complete(actions[4], status: success)
        try await feedback(.executionFeedback(.roundFinished(.init(id: round, reason: .interrupted))), from: seal)
        try await agent.receive(AssistantSessionControl.interruptSession.input(sessionID: session))
    }
    let interrupt =
        keyword
        ? keywordSignal("stop")
        : AgentInput(id: "interrupt", sessionID: "s", payload: .text("Stop"))
    try await agent.receive(interrupt)
    for _ in 0..<500 {
        if try await store.readCurrent().current.turns.first?.modelRequests?.last?.replyTruncation != nil { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    let recovered = try await AssistantHistoryStore(records: records).readCurrent()
    let request = try #require(recovered.current.turns.first?.modelRequests?.last)
    let expected = keepCompleted ? expression + expression + captionText : ""
    #expect(request.response == expected)
    #expect(request.generatedResponse == original)
    let marker = try #require(request.replyTruncation)
    #expect(marker.cause?.inputID == interrupt.id)
    #expect(marker.cause?.route == (keyword ? DecisionLogItem.Route.keyword.rawValue : "cloud:decision"))
    #expect(marker.markerText == "{\"replyInterrupted\":true}")
    let page = try await store.page(recovered.current.id)
    let ui = try JSONDecoder().decode(HistoryConversation.self, from: JSONEncoder().encode(page))
    let row = try #require(ConversationHistoryPresentation.turns(ui).first { $0.id == request.id })
    #expect(row.replyTruncation?.cause?.inputID == interrupt.id)
    let detail = try await store.message(try #require(row.messageID))
    let detailUI = try JSONDecoder().decode(HistoryConversation.self, from: JSONEncoder().encode(detail))
    let presented = try #require(ConversationHistoryPresentation.turns(detailUI).first)
    #expect(presented.displayedResponse == (expected.isEmpty ? "" : expected + "\n") + "{\"replyInterrupted\":true}")
    #expect(
        request.replyTruncation?.completedCallIDs
            == (keepCompleted ? [0, 3, 4, 5].compactMap { actions[$0].callID } : []))

    let templates = try AgentPrompts.load(named: "Assistant")
    let messages = try AssistantHistoryProjection.messages(for: request, templates: templates)
    let projected = try #require(messages.first { $0.role == .assistant }?.content)
    #expect(projected == expected + "\n{\"replyInterrupted\":true}")
    await agent.stop()
    await decision.stop()
}

@Test(.actionCatalog, .timeLimit(.minutes(1)), arguments: ["decision", "speechPerception"], [false, true])
func modelInterruptKeepsOnsetCandidateReceivedBeforeSignal(source: String, confirms: Bool) async throws {
    let main = DeferredBooleanChat(blocksFirst: true)
    let context = try AgentContextRepository(
        agent: FixtureNativeChatState.agentID, scope: UUID().uuidString, state: FixtureNativeChatState())
    let agent = try FixtureNativeAgent(
        fullDuplex: true, speechSessionID: "s", chat: main, listening: FullKeywordListening(), context: context)
    _ = try await bindSpeechRequests(agent)
    let pump = Task { for try await _ in FixtureGenerationOutputs(agent: agent) {} }
    defer { pump.cancel() }
    await agent.bindFixtureInputInterruption { session in
        try await agent.receive(AssistantSessionControl.interruptSession.input(sessionID: session))
    }
    try await agent.start()
    try await agent.receive(speechSignal(SpeechActivity(.captureStarted, generation: "capture")))
    try await agent.receive(.init(id: "original", sessionID: "s", payload: .text("Tell a story")))
    for _ in 0..<400 where await main.requests.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
    let target = try #require(await agent.currentReplyID(sessionID: "s"))

    func final(id: String, turn: String, text: String) -> AgentInput {
        let payload = InputPayload.observation(.transcript(text, final: true))
        return AgentInput(
            id: id, sessionID: "s", payload: payload,
            metadata: .init(payload: payload, source: "speechPerception", origin: .agent, rootID: id),
            turn: .init(id: turn, ordinal: 1))
    }
    try await agent.receive(
        speechSignal(SpeechActivity(.onsetConfirmed, generation: "capture", utterance: "command")))
    if source == "decision" {
        try await agent.receive(final(id: "command-final", turn: "command", text: "stop"))
    }
    try await agent.receive(speechSignal(SpeechActivity(.onsetStarted, generation: "capture")))
    if source == "speechPerception" {
        try await agent.receive(keywordSignal("command"))
    } else {
        #expect(
            try await agent.requestInterrupt(.init(target: .reply(target)), sessionID: "s", source: source)
                == .interrupted)
    }
    if source == "speechPerception" {
        try await agent.receive(final(id: "command-final", turn: "command", text: "stop"))
    }

    // Only the candidate is outstanding when the window elapses. No second onsetStarted will arrive.
    try await finishVADWindow(agent)
    #expect(await main.requests.count == 1)
    #expect(await agent.interruptionWait != nil)
    if confirms {
        try await agent.receive(
            speechSignal(
                SpeechActivity(.onsetConfirmed, generation: "capture", utterance: "follow-up")))
        #expect(await agent.interruptionWait != nil)
        #expect(await main.requests.count == 1)
        try await agent.receive(final(id: "follow-up-final", turn: "follow-up", text: "continue speaking"))
    } else {
        try await agent.receive(speechSignal(SpeechActivity(.onsetCleared, generation: "capture")))
    }
    for _ in 0..<400 where await main.requests.count < 2 { try await Task.sleep(for: .milliseconds(5)) }
    #expect(await main.requests.count == 2)
    let prompt = await main.requests.last?.messages.map(\.content).joined(separator: "\n") ?? ""
    #expect(prompt.contains("continue speaking") == confirms)
    await agent.stop()
}

@Test(.actionCatalog, .timeLimit(.minutes(1)), arguments: [false, true])
func interruptedSpeechCleanupCannotRearmRetiredWait(stop: Bool) async throws {
    let main = DeferredBooleanChat(blocksFirst: true)
    let context = try AgentContextRepository(
        agent: FixtureNativeChatState.agentID, scope: UUID().uuidString, state: FixtureNativeChatState())
    let agent = try FixtureNativeAgent(fullDuplex: true, speechSessionID: "s", chat: main, context: context)
    _ = try await bindSpeechRequests(agent)
    let pump = Task { for try await _ in FixtureGenerationOutputs(agent: agent) {} }
    let entered = AsyncStream<Void>.makeStream()
    let release = AsyncStream<Void>.makeStream()
    await agent.bindFixtureInputInterruption { session in
        try await agent.receive(AssistantSessionControl.interruptSession.input(sessionID: session))
        entered.continuation.yield(())
        var iterator = release.stream.makeAsyncIterator()
        _ = await iterator.next()
    }
    try await agent.start()
    try await agent.receive(.init(id: "original", sessionID: "s", payload: .text("original")))
    for _ in 0..<1000 {
        if await main.requests.count == 1 { break }
        try await Task.sleep(for: .milliseconds(2))
    }
    try #require(await main.requests.count == 1)
    try await agent.receive(.init(id: "queued", sessionID: "s", payload: .text("stop")))
    let interruption = Task { try await agent.requestInterrupt(AssistantInterrupt(), sessionID: "s") }
    var iterator = entered.stream.makeAsyncIterator()
    _ = await iterator.next()
    if stop {
        await agent.stop()
    } else {
        try await agent.pause()
    }
    release.continuation.yield(())
    #expect(try await interruption.value == .interrupted)
    #expect(await agent.interruptionWait == nil)
    #expect(await main.requests.count == 1)
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
    let settlement = DecisionSettlementGate()
    for index in 0..<32 {
        let input = AgentInput(id: "q\(index)", sessionID: "s", payload: .text("hello"))
        try await queue.submit(
            .init(
                snapshot: .init(input: input, text: "hello"), target: nil,
                interrupt: { _, _, _ in
                    Issue.record("Unexpected signal")
                    return .noTarget
                },
                complete: { _, _, _ in
                    await settlement.wait()
                    await completions.record()
                }, updated: {}), using: service)
    }
    #expect(await queue.count == 32)
    let extra = AgentInput(id: "overflow", sessionID: "s", payload: .text("hello"))
    await #expect(throws: CommunicationError.capacityExceeded) {
        try await queue.submit(
            .init(
                snapshot: .init(input: extra, text: "hello"), target: nil,
                interrupt: { _, _, _ in
                    Issue.record("Unexpected signal")
                    return .noTarget
                },
                complete: { _, _, _ in await completions.record() }, updated: {}), using: service)
    }
    let cancellation = Task { await queue.cancelAndWait() }
    await settlement.release()
    await cancellation.value
    #expect(await queue.count == 0)
    #expect(await classifier.requests.count <= 1)
    await service.stop()
}

private actor DecisionSettlementGate {
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func release() {
        released = true
        waiter?.resume()
        waiter = nil
    }
}

@Test(.timeLimit(.minutes(1)))
func unavailableInterruptTargetSkipsDecisionBeforeInference() async throws {
    let classifier = DecisionCloudFixture(events: [.text("true"), .finished(.stop)])
    let service = decisionFixture(cloud: classifier)
    let queue = AssistantDecisionQueue()
    let completion = AsyncStream<InputDecisionOutcome>.makeStream(bufferingPolicy: .bufferingOldest(1))
    let input = AgentInput(id: "queued", sessionID: "s", payload: .text("stop"))
    try await queue.submit(
        .init(
            snapshot: .init(input: input, text: "stop"), target: UUID(),
            interrupt: { _, _, _ in
                Issue.record("An expired reply requested interruption")
                return .targetExpired
            },
            complete: { _, outcome, _ in completion.continuation.yield(outcome) },
            updated: {}, canClassify: { false }), using: service)
    var iterator = completion.stream.makeAsyncIterator()
    let outcome = try #require(await iterator.next())
    #expect(outcome.signalStatus == "interrupt_superseded")
    #expect(outcome.requests.isEmpty && outcome.failure == nil)
    #expect(await classifier.requests.isEmpty)
    await queue.cancelAndWait()
    await service.stop()
}

private actor SlowCleanupDecision: ModelDecisionProviding {
    var availability: CapabilityAvailability { .available }
    private(set) var requests: [String] = []
    private(set) var cleaning = false
    private var cleanupWaiter: CheckedContinuation<Void, Never>?
    private var enteredWaiter: CheckedContinuation<Void, Never>?
    private var cancellationWaiter: CheckedContinuation<Void, Never>?
    private var cancelled = false
    func load() {}
    func warmup() {}
    func warmup(reportLoading: @escaping @Sendable (Bool) async -> Void) {}
    func unload() {}
    func status() -> ModelState { .ready }
    func choice(_ request: DecisionRequest) throws -> InferenceSession<DecisionResult> {
        throw CapabilityError.invalidRequest("Expected noul")
    }
    func noul(_ request: NoulRequest) throws -> InferenceSession<NoulResult> {
        #expect(!cleaning, "Native Decision requests must not overlap cleanup")
        requests.append(request.context.requestID)
        let first = requests.count == 1
        let pair = InferenceSession<NoulResult>.make(
            context: request.context, limits: try StreamLimits(), estimatedBytes: { _ in 16 },
            waitForCompletion: { if first { await self.cleanup() } })
        try pair.emitter.yield(.init(value: true))
        pair.emitter.finish()
        return pair.session
    }
    private func cleanup() async {
        cleaning = true
        enteredWaiter?.resume()
        enteredWaiter = nil
        await withTaskCancellationHandler {
            await withCheckedContinuation { cleanupWaiter = $0 }
        } onCancel: {
            Task { await self.recordCancellation() }
        }
        cleaning = false
    }
    private func recordCancellation() {
        cancelled = true
        cancellationWaiter?.resume()
        cancellationWaiter = nil
    }
    func waitForCleanup() async {
        if !cleaning { await withCheckedContinuation { enteredWaiter = $0 } }
    }
    func waitForCancellation() async {
        if !cancelled { await withCheckedContinuation { cancellationWaiter = $0 } }
    }
    func release() {
        cleanupWaiter?.resume()
        cleanupWaiter = nil
    }
}

private actor LatestDecisionProbe {
    var results: [String: InputDecisionOutcome] = [:]
    var signals = 0
    func complete(_ snapshot: InputDecisionSnapshot, _ result: InputDecisionOutcome) {
        results[snapshot.input.id] = result
    }
    func interrupt() -> AssistantInterruptResult {
        signals += 1
        return .interrupted
    }
}

@Test(.timeLimit(.minutes(1)), arguments: ["Stop!", "停下。", "don't stop", "请解释停下"])
func spokenStopUsesTheDecisionResult(_ transcript: String) async throws {
    let classifier = DecisionCloudFixture(events: [.text("false"), .finished(.stop)])
    let service = AssistantInputDecision(local: UnavailableDecision(), configuration: { (false, { classifier }) })
    let queue = AssistantDecisionQueue()
    let probe = LatestDecisionProbe()
    let completion = AsyncStream.makeStream(of: InputDecisionOutcome.self)
    let input = AgentInput(
        id: "voice-stop", sessionID: "voice", payload: .observation(.transcript(transcript, final: true)))
    let target = UUID()
    try await queue.submit(
        .init(
            snapshot: .init(input: input, text: transcript), target: target,
            interrupt: { signal, session, _ in
                #expect(signal.target == .reply(target))
                #expect(session == "voice")
                return await probe.interrupt()
            },
            complete: { _, outcome, _ in
                completion.continuation.yield(outcome)
                completion.continuation.finish()
            }, updated: {}), using: service)
    var iterator = completion.stream.makeAsyncIterator()
    let outcome = try #require(await iterator.next())
    #expect(outcome.modelResult == false)
    #expect(outcome.signalStatus == "not_requested")
    #expect(await classifier.requests.count == 1)
    #expect(await probe.signals == 0)
    await queue.cancelAndWait()
    await service.stop()
}

@Test(.timeLimit(.minutes(1)))
func latestDecisionCancelsOldRequestWaitsForCleanupAndSkipsIntermediateInput() async throws {
    let native = SlowCleanupDecision()
    let service = AssistantInputDecision(
        local: native, configuration: { (true, nil) }, timeout: .seconds(30), localTimeout: .seconds(15))
    let queue = AssistantDecisionQueue()
    let probe = LatestDecisionProbe()
    func submit(_ id: String) async throws {
        let input = AgentInput(id: id, sessionID: "s", payload: .text(id))
        try await queue.submit(
            .init(
                snapshot: .init(input: input, text: id), target: UUID(),
                interrupt: { _, _, _ in await probe.interrupt() },
                complete: { snapshot, result, _ in await probe.complete(snapshot, result) },
                updated: {}), using: service)
    }
    try await submit("old")
    await native.waitForCleanup()
    try await submit("middle")
    await native.waitForCancellation()
    try await submit("latest")
    #expect(await native.requests == ["old.decision"])
    await native.release()
    for _ in 0..<1000 {
        if await queue.count == 0 { break }
        try await Task.sleep(for: .milliseconds(2))
    }
    #expect(await queue.count == 0)
    #expect(await native.requests == ["old.decision", "latest.decision"])
    #expect(await probe.signals == 1)
    let results = await probe.results
    #expect(results.count == 3)
    for id in ["old", "middle"] {
        #expect(results[id]?.signalStatus == "superseded")
        #expect(results[id]?.modelResult == nil)
        #expect(results[id]?.failure == nil)
    }
    #expect(results["latest"]?.modelResult == true)
    await queue.cancelAndWait()
    await service.stop()
}

@Test(.timeLimit(.minutes(1)))
func latestDecisionRetiresSupersededAttemptAndCancelsClosedSession() async throws {
    let native = SlowCleanupDecision()
    let service = AssistantInputDecision(
        local: native, configuration: { (true, nil) }, timeout: .seconds(30), localTimeout: .seconds(15))
    func snapshot(_ id: String) -> InputDecisionSnapshot {
        .init(input: .init(id: id, sessionID: "s", payload: .text(id)), text: id)
    }
    let old = Task { await service.classify(snapshot("old")) }
    await native.waitForCleanup()
    let replacement = Task { await service.classify(snapshot("replacement")) }
    await native.waitForCancellation()
    #expect(await old.value.signalStatus == "superseded")
    replacement.cancel()
    #expect(await replacement.value.modelResult == nil)

    let queue = AssistantDecisionQueue()
    let probe = LatestDecisionProbe()
    try await queue.submit(
        .init(
            snapshot: snapshot("closed"), target: UUID(),
            interrupt: { _, _, _ in await probe.interrupt() },
            complete: { snapshot, result, _ in await probe.complete(snapshot, result) },
            updated: {}), using: service)
    await queue.remove(sessionID: "s")
    await native.release()
    await queue.cancelAndWait()
    #expect(await probe.results.isEmpty)
    #expect(await probe.signals == 0)
    let latest = await service.classify(snapshot("latest"))
    #expect(latest.modelResult == true)
    #expect(await native.requests == ["old.decision", "latest.decision"])
    await service.stop()
}

extension LiveRuntimeTests {
    @Test
    func latestDecisionCleanupWaitTimesOutWithoutReentryAndRecoversAfterExit() async throws {
        let native = SlowCleanupDecision()
        let service = AssistantInputDecision(
            local: native, configuration: { (true, nil) }, timeout: .seconds(5),
            localTimeout: .milliseconds(100))
        func snapshot(_ id: String) -> InputDecisionSnapshot {
            .init(input: .init(id: id, sessionID: "s", payload: .text(id)), text: id)
        }
        let first = Task { await service.classify(snapshot("old")) }
        await native.waitForCleanup()
        #expect(await first.value.failure == .timedOut)
        let waiting = await service.classify(snapshot("waiting"))
        #expect(waiting.failure == .timedOut)
        #expect(waiting.requests.isEmpty)
        #expect(await native.requests == ["old.decision"])
        let latest = Task { await service.classify(snapshot("latest")) }
        await native.release()
        let recovered = await latest.value
        #expect(recovered.modelResult == true)
        #expect(recovered.failure == nil)
        #expect(await native.requests == ["old.decision", "latest.decision"])
        await service.stop()
    }
}

@Test(.actionCatalog, .timeLimit(.minutes(1)))
func unifiedInterruptGatewayRequiresDeclaredSenderPermission() async throws {
    func configuration(_ id: String, allowed: Bool = false) throws -> AgentConfiguration {
        try AgentConfiguration(
            contracts: AgentContracts.communication,
            data: JSONSerialization.data(withJSONObject: [
                "version": 9, "category": "cognition", "id": id, "actions": [String: [String]](), "tools": [],
                "signals": [
                    "requests": [], "feedback": [],
                    "subscriptions": id == "assistant"
                        ? [
                            [
                                "channel": "agent.interruption", "protocol": AssistantInterrupt.contract,
                                "sources": ["producer"],
                            ]
                        ] : [],
                    "publications": allowed
                        ? [["channel": "agent.interruption", "protocol": AssistantInterrupt.contract]] : [],
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
    let agent = try FixtureNativeAgent(
        fullDuplex: true, chat: model, configuration: configuration("assistant"), context: context)
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
    try await port.publish(AssistantInterrupt().message(), parent: parent)
    await input.flushPublications()
    await #expect(throws: CommunicationError.unauthorized) {
        try await forbidden.publish(AssistantInterrupt().message(), parent: parent)
    }
    #expect(await model.requests.isEmpty)
    await manager.stopAll()
}

private struct FullKeywordListening: ListeningControlling {
    var isListening: Bool { true }
    func apply(_ listening: Bool, source: AgentStateSource, wakeCondition: String?) async throws {}
    func receiveQuiet(_ text: String, _ input: AgentInput) {}
}

@Test(
    .actionCatalog, .timeLimit(.minutes(1)),
    arguments: [
        "finalFirst", "stale", "unlisted", "command", "beforeVAD", "continuation", "sameTurnContinuation",
        "duringCleanup",
    ])
func keywordAndFinalOrderingPreservesSpeechWithoutDuplicateDecision(scenario: String) async throws {
    let confirm = !["stale", "unlisted"].contains(scenario)
    let beforeReply = ContinuousClock.now
    let main = DeferredBooleanChat(blocksFirst: true)
    let cloud = DecisionCloudFixture(events: [.text("false"), .finished(.stop)])
    let decision = decisionFixture(cloud: cloud)
    let context = try AgentContextRepository(
        agent: FixtureNativeChatState.agentID, scope: UUID().uuidString, state: FixtureNativeChatState())
    let agent = try FixtureNativeAgent(
        inputDecision: decision, fullDuplex: true, speechSessionID: "s", chat: main,
        listening: FullKeywordListening(), context: context)
    _ = try await bindSpeechRequests(agent)
    let pump = Task { for try await _ in FixtureGenerationOutputs(agent: agent) {} }
    let probe = InterruptProbe()
    let text = scenario == "sameTurnContinuation" ? "please stop, tell me something else" : "please stop"
    let payload = InputPayload.observation(SpeechRecognition(.final, text: text, generation: "capture").message())
    let command = AgentInput(
        id: "final", sessionID: "s", payload: payload,
        metadata: .init(payload: payload, source: "speechPerception", origin: .agent, rootID: "final"),
        turn: .init(id: "utterance", ordinal: 1))
    await agent.bindFixtureInputInterruption { session in
        await probe.record()
        if scenario == "duringCleanup" { try await agent.receive(command) }
        try await agent.receive(AssistantSessionControl.interruptSession.input(sessionID: session))
    }
    try await agent.start()
    try await agent.receive(speechSignal(SpeechActivity(.captureStarted, generation: "capture")))
    try await agent.receive(keywordSignal("idle"))
    #expect(await agent.interruptionWait == nil)
    try await agent.receive(.init(id: "reply", sessionID: "s", payload: .text("Tell a story")))
    for _ in 0..<200 where await main.requests.isEmpty {
        try await Task.sleep(for: .milliseconds(5))
    }
    _ = try #require(await agent.currentReplyID(sessionID: "s"))
    if scenario == "finalFirst" { try await agent.receive(command) }
    if scenario != "beforeVAD" {
        try await agent.receive(
            speechSignal(
                SpeechActivity(.onsetConfirmed, generation: "capture", utterance: "utterance")))
    }
    let keyword = keywordSignal(
        "utterance", label: scenario == "unlisted" ? "hello" : "en-stop",
        onset: scenario == "stale" ? beforeReply : .now)
    try await agent.receive(keyword)
    try await agent.receive(keyword)
    if scenario == "finalFirst" { #expect(await agent.speechUtterances.isEmpty) }

    if confirm { #expect(await agent.interruptionWait != nil) }
    if scenario == "sameTurnContinuation" {
        try await finishVADWindow(agent)
        #expect(await agent.interruptionWait != nil)
        #expect(await main.requests.count == 1)
    }
    if !["duringCleanup", "finalFirst"].contains(scenario) { try await agent.receive(command) }
    if scenario == "continuation" {
        try await agent.receive(speechSignal(SpeechActivity(.onsetStarted, generation: "capture")))
        try await finishVADWindow(agent)
        #expect(await main.requests.count == 1)
        try await agent.receive(
            speechSignal(SpeechActivity(.onsetConfirmed, generation: "capture", utterance: "next")))
        #expect(await agent.interruptionWait != nil)
        let continuation = InputPayload.observation(.transcript("tell me something else", final: true))
        try await agent.receive(
            .init(
                id: "next-final", sessionID: "s", payload: continuation,
                metadata: .init(
                    payload: continuation, source: "speechPerception", origin: .agent, rootID: "next-final"),
                turn: .init(id: "next", ordinal: 2)))
    }
    if scenario == "beforeVAD" {
        try await agent.receive(
            speechSignal(
                SpeechActivity(.onsetConfirmed, generation: "capture", utterance: "utterance")))
        #expect(await agent.speechUtterances.isEmpty)
    }
    if confirm && !["continuation", "sameTurnContinuation"].contains(scenario) {
        try await finishVADWindow(agent)
    }
    for _ in 0..<500 {
        let received = confirm ? await main.requests.count > 1 : await !cloud.requests.isEmpty
        if received { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(await probe.count == (confirm ? 1 : 0))
    if scenario == "finalFirst" {
        #expect(await cloud.requests.count <= 1)
    } else {
        #expect(await cloud.requests.count == (confirm ? 0 : 1))
    }
    if confirm {
        #expect(await main.requests.count == 2)
        #expect(await main.requests.last?.messages.contains(where: { $0.content.contains("please stop") }) == true)
        if scenario == "continuation" || scenario == "sameTurnContinuation" {
            #expect(
                await main.requests.last?.messages.contains(where: { $0.content.contains("tell me something else") })
                    == true)
        }
    }
    await agent.stop()
    await decision.stop()
    pump.cancel()
    _ = await pump.result
}
