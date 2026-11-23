import AgentCore
import Foundation
import ModelKit
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

private func tier(_ name: String, _ chat: ScriptedChat) -> QuietModelTier {
    QuietModelTier(name: name, modelID: name + "-model", chat: { chat })
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

@Test(arguments: [("exit", QuietJudgement.Decision.exit), ("  STAY  ", .stay)])
func exitAnswersAcceptOnlyTheVerdict(answer: String, decision: QuietJudgement.Decision) throws {
    #expect(try QuietExitJudge.parse(answer) == decision)
}

@Test(arguments: ["", "maybe", "I think exit", "1", "exit 用户未明确允许开口，仅询问身份", "stay."])
func anythingElseIsNotAnAnswer(answer: String) {
    #expect(throws: QuietExitError.invalidAnswer) { try QuietExitJudge.parse(answer) }
}

@Test(.actionCatalog) func judgeFallsThroughTiersInOrderAndReportsTheOneThatAnswered() async throws {
    let judge = QuietExitJudge(tiers: [
        tier("system", ScriptedChat([.success("exit 用户未明确允许开口")])),
        tier("configured", ScriptedChat([.success("stay")])),
    ])
    let result = try await judge.judge("好了，你可以说话了")
    #expect(result.decision == .stay && result.tier == "configured" && result.modelID == "configured-model")
}

@Test(.actionCatalog) func judgeFailsWhenEveryTierFailsOrAnswersBadly() async throws {
    let judge = QuietExitJudge(tiers: [
        tier("system", ScriptedChat([.success("hmm")])), tier("configured", ScriptedChat([.failure(.failed)])),
    ])
    do {
        _ = try await judge.judge("x")
        Issue.record("Expected failure")
    } catch QuietExitError.unavailable(let failures) {
        #expect(failures.count == 2)
    }
}

@Test(.actionCatalog) func judgeTimesOutASlowTierAndTriesTheNext() async throws {
    let judge = QuietExitJudge(
        tiers: [
            tier("system", ScriptedChat([.success("exit")], delay: .seconds(30))),
            tier("configured", ScriptedChat([.success("stay")])),
        ], timeout: .milliseconds(100))
    #expect(try await judge.judge("x").tier == "configured")
}

private final class ModeWrites: Sendable {
    private let values = Mutex<[ListeningMode]>([])
    var modes: [ListeningMode] { values.withLock { $0 } }
    func record(_ mode: ListeningMode) { values.withLock { $0.append(mode) } }
}

@Test(.actionCatalog, .timeLimit(.minutes(1)))
func quietEpisodeEndsOnExitReturnsToThePreviousModeAndRecordsEveryJudgment() async throws {
    let repositories = try SQLiteRepositories.temporary()
    let chat = ScriptedChat([.success("stay"), .success("exit")])
    let coordinator = ListeningCoordinator(
        judge: QuietExitJudge(tiers: [tier("system", chat)]), dialogs: repositories.listeningDialogs, sessionID: "s")
    let writes = ModeWrites()
    let published = ModeWrites()
    let released = Mutex<[String]>([])
    let cancels = Mutex(0)
    coordinator.bind(
        cancelReply: { cancels.withLock { $0 += 1 } },
        writeMode: { [coordinator] mode in
            writes.record(mode)
            try await coordinator.apply(mode, source: .host)
        },
        publishMode: { published.record($0) },
        release: { input in released.withLock { $0.append(input.id) } })
    try await coordinator.apply(.full, source: .model)
    try await coordinator.apply(.quiet, source: .host)
    #expect(coordinator.mode == .quiet && cancels.withLock { $0 } == 1)
    coordinator.receiveQuiet("我想一想", try quietInput())
    try await until { (try? await repositories.listeningDialogs.recentListeningDialogs(limit: 10).count) == 1 }
    #expect(coordinator.mode == .quiet && writes.modes.isEmpty)
    let inviting = try quietInput()
    coordinator.receiveQuiet("好了，你可以跟我说话了", inviting)
    try await until { coordinator.mode == .full }
    #expect(writes.modes == [.full])
    // The sentence that ended quiet is admitted as ordinary speech, and every mode change was published.
    try await until { released.withLock { $0 } == [inviting.id] }
    #expect(published.modes == [.full, .quiet, .full])
    let rows = try await repositories.listeningDialogs.recentListeningDialogs(limit: 10).reversed()
    #expect(rows.map(\.decision) == [.stay, .exit])
    #expect(Set(rows.map(\.episodeID)).count == 1 && rows.allSatisfy { $0.modelTier == "system" })
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
    let judge = ScriptedChat([.success("stay"), .success("exit")])
    let coordinator = ListeningCoordinator(
        judge: QuietExitJudge(tiers: [tier("system", judge)]),
        dialogs: repositories.listeningDialogs, sessionID: "s")
    let context = try AgentContextRepository(
        agent: .assistant, scope: UUID().uuidString, state: AssistantContextState())
    let model = ScriptedChat([
        .success(
            "Okay. <state.set name=\"listening\" value=\"quiet\" wakeCondition=\"\(condition)\"/> This should stay silent."
        ),
        .success("I can speak again."),
    ])
    let agent = try AssistantAgent(
        stateContext: try publicStateFixture(), fullDuplex: true, speechSessionID: "s",
        chat: model, listening: coordinator, context: context)
    let speech = try await bindSpeechRequests(agent)
    let interruptions = Mutex(0)
    coordinator.bind(
        cancelReply: { interruptions.withLock { $0 += 1 } },
        writeMode: { [weak agent] mode in
            try await agent?.setHostState("listening", to: mode.rawValue)
        },
        release: { [weak agent] in try await agent?.receive($0) })
    try await agent.start()
    let pump = Task { for try await _ in FixtureGenerationOutputs(agent: agent) {} }
    defer { pump.cancel() }

    try await agent.receive(.init(id: "enter", sessionID: "s", payload: .text("Listen quietly.")))
    try await until { (try? await context.snapshot().work["enter"]?.state) == .completed }
    try #require(coordinator.mode == .quiet)
    #expect(try await context.snapshot().work["enter"]?.state == .completed)
    #expect(try await context.snapshot().state.history.current.turns.last?.modelRequests?.last?.state == .completed)
    #expect(try await context.snapshot().state.variables.value("listening") == "quiet")
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
    #expect(
        try JSONDecoder().decode([String: String].self, from: Data(beforeJSON.utf8))
            == ["mode": "quiet", "wakeCondition": condition])
    try await receive("你是谁？", id: "greeting")
    try await until { (try? await repositories.listeningDialogs.recentListeningDialogs(limit: 10).count) == 1 }
    #expect(coordinator.mode == .quiet)
    #expect(try await context.snapshot().work["greeting"] == nil)
    try await receive("秦始皇", id: "wake")
    try await until { (try? await context.snapshot().work["wake"]?.state) == .completed }
    #expect(try await context.snapshot().work["wake"]?.state == .completed)
    let rows = try await repositories.listeningDialogs.recentListeningDialogs(limit: 10)
    #expect(rows.map(\.decision) == [.exit, .stay])
    #expect(rows.map(\.modelTier) == (literal ? ["literal", "literal"] : ["system", "system"]))
    #expect(judge.requests.count == (literal ? 0 : 2))
    for (request, text) in zip(judge.requests, ["你是谁？", "秦始皇"]) {
        #expect(request.messages.map(\.role) == [.system, .user])
        #expect(request.messages.first?.content.contains("satisfies the agreement") == true)
        let user = try #require(request.messages.last?.content)
        let fields = try JSONDecoder().decode([String: String].self, from: Data(user.utf8))
        #expect(fields == ["wakeCondition": condition, "latestUtterance": text])
    }
    let afterWake = await agent.stateVariables().first { $0.path == "agents.assistant.listening" }
    let afterJSON = try #require(afterWake?.value)
    let fields = try JSONDecoder().decode([String: String?].self, from: Data(afterJSON.utf8))
    #expect(fields == ["mode": "full", "wakeCondition": nil])
    #expect(coordinator.mode == .full)
    #expect(await speech.requests.values.contains("I can speak again."))
    await agent.stop()
    try await pump.value
}

@Test(.actionCatalog, .timeLimit(.minutes(1)))
func aNewerUtteranceReplacesAnUnfinishedJudgment() async throws {
    let repositories = try SQLiteRepositories.temporary()
    let coordinator = ListeningCoordinator(
        judge: QuietExitJudge(tiers: [
            tier("system", ScriptedChat([.success("stay"), .success("stay")], delay: .milliseconds(300)))
        ]),
        dialogs: repositories.listeningDialogs, sessionID: "s")
    coordinator.bind(cancelReply: {}, writeMode: { _ in })
    try await coordinator.apply(.quiet, source: .model)
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
        judge: QuietExitJudge(tiers: [tier("system", ScriptedChat([]))]), dialogs: repositories.listeningDialogs,
        sessionID: "s", report: { message in reports.withLock { $0.append(message) } })
    coordinator.bind(cancelReply: {}, writeMode: { _ in })
    try await coordinator.apply(.quiet, source: .host)
    for index in 0..<ListeningCoordinator.maximumConsecutiveFailures + 1 {
        coordinator.receiveQuiet("句子\(index)", try quietInput())
        try await until {
            (try? await repositories.listeningDialogs.recentListeningDialogs(limit: 10).count) == index + 1
        }
    }
    #expect(coordinator.mode == .quiet)
    #expect(reports.withLock { $0.count } == 1)
    let rows = try await repositories.listeningDialogs.recentListeningDialogs(limit: 10)
    #expect(rows.allSatisfy { $0.decision == .error && $0.error != nil })
}

@Test(.actionCatalog) func unavailableFullDuplexReturnsToHalfExplicitly() async throws {
    let reports = Mutex<[String]>([])
    let coordinator = ListeningCoordinator(
        judge: nil, dialogs: nil, sessionID: "s", report: { message in reports.withLock { $0.append(message) } })
    let writes = ModeWrites()
    coordinator.bind(
        cancelReply: {},
        writeMode: { [coordinator] mode in
            writes.record(mode)
            try await coordinator.apply(mode, source: .host)
        })
    // No capture has reported yet, so `full` is accepted and re-checked when one does.
    try await coordinator.apply(.full, source: .model)
    await coordinator.captureDuplex(false)
    #expect(coordinator.mode == .half && writes.modes == [.half] && reports.withLock { $0.count } == 1)
    await #expect(throws: AgentStateError.self) { try await coordinator.apply(.full, source: .model) }
    #expect(coordinator.mode == .half)
    // An explicit half is never overridden; a fallback is undone when a capture supports echo cancellation.
    await coordinator.captureDuplex(true)
    #expect(coordinator.mode == .full && writes.modes == [.half, .full] && reports.withLock { $0.count } == 1)
    try await coordinator.apply(.half, source: .model)
    await coordinator.captureDuplex(true)
    #expect(coordinator.mode == .half)
}

@Test(.actionCatalog, .timeLimit(.minutes(1)))
func endingTheSessionCancelsTheJudgmentAndReturnsToTheDefaultMode() async throws {
    let repositories = try SQLiteRepositories.temporary()
    let coordinator = ListeningCoordinator(
        judge: QuietExitJudge(tiers: [tier("system", ScriptedChat([.success("stay")], delay: .seconds(30)))]),
        dialogs: repositories.listeningDialogs, sessionID: "s")
    let writes = ModeWrites()
    coordinator.bind(
        cancelReply: {},
        writeMode: { [coordinator] mode in
            writes.record(mode)
            try await coordinator.apply(mode, source: .host)
        })
    try await coordinator.apply(.quiet, source: .model)
    coordinator.receiveQuiet("还没说完", try quietInput())
    await coordinator.perceptionEnded()
    #expect(coordinator.mode == .full && writes.modes == [.full])
    try await Task.sleep(for: .milliseconds(100))
    #expect(try await repositories.listeningDialogs.recentListeningDialogs(limit: 10).isEmpty)
}
