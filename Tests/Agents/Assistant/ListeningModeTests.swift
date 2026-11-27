import AgentCore
import Foundation
import ModelKit
import ModelKitDefaults
import ModelKitRuntime
import StorageSQLite
import StorageTasks
import Synchronization
import Testing

@testable import Agents

/// Answers each request with the next scripted reply; an `Error` entry fails that request.
private final class ScriptedChat: ChatCapability, Sendable {
    private let script: Mutex<[Result<String, QuietTestFailure>]>
    private let received = Mutex<[ChatRequest]>([])
    private let delay: Duration
    init(_ script: [Result<String, QuietTestFailure>], delay: Duration = .zero) {
        self.script = Mutex(script)
        self.delay = delay
    }
    var availability: CapabilityAvailability { .available }
    var requests: [ChatRequest] { received.withLock { $0 } }
    func chat(_ request: ChatRequest) async throws -> InferenceSession<ChatEvent> {
        received.withLock { $0.append(request) }
        let next = script.withLock { $0.isEmpty ? .failure(.exhausted) : $0.removeFirst() }
        if delay > .zero { try await Task.sleep(for: delay) }
        let text = try next.get()
        let pair = InferenceSession<ChatEvent>.make(
            context: request.context, limits: try StreamLimits(), estimatedBytes: { $0.estimatedBytes })
        try pair.emitter.yield(.text(text))
        try pair.emitter.yield(.finished(.stop))
        pair.emitter.finish()
        return pair.session
    }
}
private enum QuietTestFailure: Error { case failed, exhausted }

private final class ScriptedDecision: ModelDecisionProviding, Sendable {
    private let script: Mutex<[Result<Bool, QuietTestFailure>]>
    private let received = Mutex<[NoulRequest]>([])
    private let delay: Duration

    init(_ script: [Result<Bool, QuietTestFailure>], delay: Duration = .zero) {
        self.script = Mutex(script)
        self.delay = delay
    }

    var requests: [NoulRequest] { received.withLock { $0 } }
    var availability: CapabilityAvailability { .available }
    func load() {}
    func warmup() {}
    func warmup(reportLoading: @escaping @Sendable (Bool) async -> Void) {}
    func unload() {}
    func status() -> ModelState { .ready }
    func choice(_ request: DecisionRequest) throws -> InferenceSession<DecisionResult> {
        throw CapabilityError.invalidRequest("Expected a boolean Decision request")
    }
    func noul(_ request: NoulRequest) async throws -> InferenceSession<NoulResult> {
        received.withLock { $0.append(request) }
        let next = script.withLock { $0.isEmpty ? .failure(.exhausted) : $0.removeFirst() }
        if delay > .zero { try await Task.sleep(for: delay) }
        let pair = InferenceSession<NoulResult>.make(
            context: request.context, limits: try StreamLimits(), estimatedBytes: { _ in 16 })
        try pair.emitter.yield(NoulResult(value: next.get()))
        pair.emitter.finish()
        return pair.session
    }
}

private func localDecision(_ model: ScriptedDecision, cloud: ScriptedChat? = nil, timeout: Duration = .seconds(2))
    -> AssistantInputDecision
{
    AssistantInputDecision(
        local: model, configuration: { (true, cloud.map { chat in { @Sendable in chat } }) },
        timeout: timeout, localTimeout: timeout)
}

private func quietInput() throws -> AgentInput {
    AgentInput(
        id: UUID().uuidString, sessionID: "s",
        payload: .audio(try syntheticAudioInput(samples: Data(count: 8), sampleRate: 16000, sequence: 0, timestamp: 0)))
}

private func until(_ condition: @Sendable () async -> Bool) async throws {
    for _ in 0..<500 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Timed out waiting for a condition")
}

@Test(.actionCatalog) func quietAndInterruptReadTheSameDecisionSelection() async throws {
    let first = ScriptedDecision([.success(false), .success(true)])
    let second = ScriptedDecision([.success(false), .success(false)])
    let selected = Mutex("first")
    let service = AssistantInputDecision(
        localModel: { $0 == "first" ? first : second },
        selectedConfiguration: { (selected.withLock { $0 }, nil) }, timeout: .seconds(8), localTimeout: .seconds(8))
    let judge = QuietExitJudge(decision: service)
    let input = try quietInput()

    for (id, expected) in [("first", QuietJudgement.Decision.exit), ("second", .stay)] {
        selected.withLock { $0 = id }
        let interrupt = await service.classify(
            InputDecisionSnapshot(input: input, text: "Hold on.", currentAssistantReply: "My answer is…"))
        #expect(interrupt.route == .local(modelID: id) && interrupt.modelResult == false)
        let awake = try await judge.judge("Go ahead.", context: .init(requestID: id + ".awake"))
        #expect(awake.decision == expected && awake.tier == "local" && awake.modelID == id)
    }
    for model in [first, second] {
        try #require(model.requests.count == 2)
        #expect(model.requests[0].text == "You are saying “My answer is…” when the user says to you “Hold on.”\n")
        #expect(model.requests[0].instructions == "Does the user intend to interrupt you?")
        #expect(model.requests[1].text == "Go ahead.")
        #expect(model.requests[1].instructions.contains("inviting you to talk again"))
    }
    await service.stop()
}

@Test(.actionCatalog) func quietUsesTheSelectedCloudDecision() async throws {
    let cloud = ScriptedChat([.success("true")])
    let service = AssistantInputDecision(
        local: UnavailableDecision(), configuration: { (false, { cloud }) },
        timeout: .seconds(8), localTimeout: .seconds(8))
    let judge = QuietExitJudge(decision: service)
    let result = try await judge.judge("Go ahead.", context: .init(requestID: "cloud.awake"))
    #expect(result.tier == "cloud" && result.decision == .exit)
    let request = try #require(cloud.requests.first)
    #expect(request.context.requestID == "cloud.awake")
    #expect(request.messages.first?.content.contains("Return only the JSON boolean true or false.") == true)
    await service.stop()
}

@Test(.actionCatalog, arguments: [false, true])
func quietFailureOrTimeoutDoesNotTryAnotherModel(timesOut: Bool) async throws {
    let local = ScriptedDecision(
        [.failure(.failed)], delay: timesOut ? .seconds(30) : .zero)
    let cloud = ScriptedChat([.success("true")])
    let service = localDecision(local, cloud: cloud, timeout: .milliseconds(300))
    let judge = QuietExitJudge(decision: service)
    await #expect(throws: CapabilityError.self) {
        try await judge.judge("Go ahead.", context: .init(requestID: "failure.awake"))
    }
    #expect(local.requests.count == 1 && cloud.requests.isEmpty)
    await service.stop()
}

private final class ListeningWrites: Sendable {
    private let values = Mutex<[Bool]>([])
    var valuesWritten: [Bool] { values.withLock { $0 } }
    func record(_ mode: Bool) { values.withLock { $0.append(mode) } }
}

@Test(.actionCatalog, .timeLimit(.minutes(1)))
func quietEpisodeEnablesListeningOnExitAndRecordsEveryJudgment() async throws {
    let repositories = try SQLiteRepositories.temporary()
    let decision = ScriptedDecision([.success(false), .success(true)])
    let coordinator = ListeningCoordinator(
        judge: QuietExitJudge(decision: localDecision(decision)), dialogs: repositories.listeningDialogs, sessionID: "s"
    )
    let writes = ListeningWrites()
    let released = Mutex<[String]>([])
    let cancels = Mutex(0)
    coordinator.bind(
        cancelReply: { cancels.withLock { $0 += 1 } },
        enableListening: { [coordinator] in
            writes.record(true)
            try await coordinator.apply(true, source: .host)
        },
        release: { input in released.withLock { $0.append(input.id) } })
    try await coordinator.apply(true, source: .model)
    try await coordinator.apply(false, source: .host)
    #expect(!coordinator.isListening && cancels.withLock { $0 } == 1)
    coordinator.receiveQuiet("我想一想", try quietInput())
    try await until { (try? await repositories.listeningDialogs.recentListeningDialogs(limit: 10).count) == 1 }
    #expect(!coordinator.isListening && writes.valuesWritten.isEmpty)
    let inviting = try quietInput()
    coordinator.receiveQuiet("好了，你可以跟我说话了", inviting)
    try await until { coordinator.isListening }
    #expect(writes.valuesWritten == [true])
    try await until { released.withLock { $0 } == [inviting.id] }
    let rows = try await repositories.listeningDialogs.recentListeningDialogs(limit: 10).reversed()
    #expect(rows.map(\.decision) == [.stay, .exit])
    #expect(Set(rows.map(\.episodeID)).count == 1)
    #expect(rows.allSatisfy { $0.modelTier == "local" && $0.modelID == "d3-edge" })
    #expect(rows.map(\.text) == ["我想一想", "好了，你可以跟我说话了"])
    // Speech after the episode no longer reaches the judge.
    coordinator.receiveQuiet("还在吗", try quietInput())
    try await Task.sleep(for: .milliseconds(100))
    #expect(try await repositories.listeningDialogs.recentListeningDialogs(limit: 10).count == 2)
}

@Test(.actionCatalog, .timeLimit(.minutes(1)), arguments: [false, true])
func modelCanEnterQuietAndSettleBeforeTheNextSpeechInput(literal: Bool) async throws {
    let condition = literal ? "literal:秦始皇" : "Wait for 秦始皇"
    let repositories = try SQLiteRepositories.temporary()
    let judge = ScriptedDecision([.success(false), .success(true)])
    let decision = localDecision(judge)
    let coordinator = ListeningCoordinator(
        judge: QuietExitJudge(decision: decision),
        dialogs: repositories.listeningDialogs, sessionID: "s")
    let context = try AgentContextRepository(
        agent: .assistant, scope: UUID().uuidString, state: AssistantContextState())
    let model = ScriptedChat([
        .success(
            "Okay. <state.set name=\"listening\" value=\"false\" wakeCondition=\"\(condition)\"/> This should stay silent."
        ),
        .success("I can speak again."),
    ])
    let agent = try AssistantAgent(
        stateContext: try publicStateFixture(), inputDecision: decision, fullDuplex: true, speechSessionID: "s",
        chat: model, listening: coordinator, context: context)
    let speech = try await bindSpeechRequests(agent)
    let interruptions = Mutex(0)
    coordinator.bind(
        cancelReply: { interruptions.withLock { $0 += 1 } },
        enableListening: { [weak agent] in
            try await agent?.setHostState("listening", to: "true")
        },
        release: { [weak agent] in try await agent?.receiveAwakeningSpeech($0) })
    try await agent.start()
    let pump = Task { for try await _ in FixtureGenerationOutputs(agent: agent) {} }
    defer { pump.cancel() }

    try await agent.receive(.init(id: "enter", sessionID: "s", payload: .text("Listen quietly.")))
    try await until { (try? await context.snapshot().work["enter"]?.state) == .completed }
    try #require(!coordinator.isListening)
    #expect(try await context.snapshot().work["enter"]?.state == .completed)
    #expect(try await context.snapshot().state.history.current.turns.last?.modelRequests?.last?.state == .completed)
    #expect(try await context.snapshot().state.variables.value("listening") == "false")
    #expect(interruptions.withLock { $0 } == 0)
    #expect(await speech.cancelledInputs.contains("enter"))
    #expect(await speech.requests.values.allSatisfy { !$0.contains("stay silent") })

    func receive(_ text: String, id: String) async throws {
        let payload = InputPayload.observation(.transcript(text, final: true))
        try await agent.receive(
            .init(
                id: id, sessionID: "s", payload: payload,
                metadata: .init(payload: payload, source: "speechPerception", origin: .agent, rootID: id)))
    }
    let beforeWake = await agent.stateVariables().first { $0.path == "agents.assistant.listening" }
    let beforeJSON = try #require(beforeWake?.value)
    let state = try #require(JSONSerialization.jsonObject(with: Data(beforeJSON.utf8)) as? [String: Any])
    #expect(state["listening"] as? Bool == false)
    #expect(state["wakeCondition"] as? String == condition)
    try await receive("你是谁？", id: "greeting")
    try await until { (try? await repositories.listeningDialogs.recentListeningDialogs(limit: 10).count) == 1 }
    #expect(!coordinator.isListening)
    #expect(try await context.snapshot().work["greeting"] == nil)
    try await receive("秦始皇", id: "wake")
    try await until { (try? await context.snapshot().work["wake"]?.state) == .completed }
    #expect(try await context.snapshot().work["wake"]?.state == .completed)
    let rows = try await repositories.listeningDialogs.recentListeningDialogs(limit: 10)
    #expect(rows.map(\.decision) == [.exit, .stay])
    #expect(rows.map(\.modelTier) == ["local", "local"])
    #expect(judge.requests.count == 2)
    for (request, text) in zip(judge.requests, ["你是谁？", "秦始皇"]) {
        #expect(request.instructions.contains("satisfy the agreement"))
        let fields = try JSONDecoder().decode([String: String].self, from: Data(request.text.utf8))
        #expect(
            fields == [
                "wakeCondition": literal ? "The user must say this exact phrase: 秦始皇" : condition,
                "latestUtterance": text,
            ])
    }
    let afterWake = await agent.stateVariables().first { $0.path == "agents.assistant.listening" }
    let afterJSON = try #require(afterWake?.value)
    let awakenedState = try #require(JSONSerialization.jsonObject(with: Data(afterJSON.utf8)) as? [String: Any])
    #expect(awakenedState["listening"] as? Bool == true)
    #expect(awakenedState["wakeCondition"] is NSNull)
    #expect(coordinator.isListening)
    #expect(await speech.requests.values.contains("I can speak again."))
    await agent.stop()
    try await pump.value
}

@Test(.actionCatalog, .timeLimit(.minutes(1)))
func aNewerUtteranceReplacesAnUnfinishedJudgment() async throws {
    let repositories = try SQLiteRepositories.temporary()
    let coordinator = ListeningCoordinator(
        judge: QuietExitJudge(
            decision: localDecision(ScriptedDecision([.success(false), .success(false)], delay: .milliseconds(300)))),
        dialogs: repositories.listeningDialogs, sessionID: "s")
    coordinator.bind(cancelReply: {}, enableListening: {})
    try await coordinator.apply(false, source: .model)
    coordinator.receiveQuiet("第一句", try quietInput())
    try await Task.sleep(for: .milliseconds(50))
    coordinator.receiveQuiet("第二句", try quietInput())
    try await until { (try? await repositories.listeningDialogs.recentListeningDialogs(limit: 10).count) == 1 }
    try await Task.sleep(for: .milliseconds(500))
    let rows = try await repositories.listeningDialogs.recentListeningDialogs(limit: 10)
    #expect(rows.map(\.text) == ["第二句"])
}

@Test(.actionCatalog, .timeLimit(.minutes(1)))
func judgeFailuresStayInQuietAreRecordedAndSurfacedOnce() async throws {
    let repositories = try SQLiteRepositories.temporary()
    let reports = Mutex<[String]>([])
    let coordinator = ListeningCoordinator(
        judge: QuietExitJudge(decision: localDecision(ScriptedDecision([]))), dialogs: repositories.listeningDialogs,
        sessionID: "s", report: { message in reports.withLock { $0.append(message) } })
    coordinator.bind(cancelReply: {}, enableListening: {})
    try await coordinator.apply(false, source: .host)
    for index in 0..<ListeningCoordinator.maximumConsecutiveFailures + 1 {
        coordinator.receiveQuiet("句子\(index)", try quietInput())
        try await until {
            (try? await repositories.listeningDialogs.recentListeningDialogs(limit: 10).count) == index + 1
        }
    }
    #expect(!coordinator.isListening)
    #expect(reports.withLock { $0.count } == 1)
    let rows = try await repositories.listeningDialogs.recentListeningDialogs(limit: 10)
    #expect(rows.allSatisfy { $0.decision == .error && $0.error != nil })
}

@Test(.actionCatalog, arguments: ["quiet", "full", "half"])
func assistantDecodesLegacyListeningState(value: String) throws {
    let data = try JSONEncoder().encode(AssistantContextState())
    var archive = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    archive["variables"] = ["entries": ["listening": ["value": value, "writtenAt": 0, "sequence": 1]], "sequence": 1]
    if value == "quiet" { archive["listeningWakeCondition"] = "literal:继续" }
    let restored = try JSONDecoder().decode(
        AssistantContextState.self, from: JSONSerialization.data(withJSONObject: archive))
    try restored.validateContextState()
    #expect(restored.variables.value("listening") == String(value != "quiet"))
    #expect(restored.listeningWakeCondition == (value == "quiet" ? "literal:继续" : nil))
}

@Test(.actionCatalog, .timeLimit(.minutes(1)))
func cancellingWakeJudgmentPreservesQuietState() async throws {
    let repositories = try SQLiteRepositories.temporary()
    let coordinator = ListeningCoordinator(
        judge: QuietExitJudge(decision: localDecision(ScriptedDecision([.success(false)], delay: .seconds(30)))),
        dialogs: repositories.listeningDialogs, sessionID: "s")
    let writes = ListeningWrites()
    coordinator.bind(
        cancelReply: {},
        enableListening: { [coordinator] in
            writes.record(true)
            try await coordinator.apply(true, source: .host)
        })
    try await coordinator.apply(false, source: .model)
    coordinator.receiveQuiet("还没说完", try quietInput())
    coordinator.cancelJudgment()
    #expect(!coordinator.isListening && writes.valuesWritten.isEmpty)
    try await Task.sleep(for: .milliseconds(100))
    #expect(try await repositories.listeningDialogs.recentListeningDialogs(limit: 10).isEmpty)
}
