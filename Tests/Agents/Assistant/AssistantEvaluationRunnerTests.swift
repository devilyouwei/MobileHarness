import Actions
import AgentCore
import CallRuntime
import ExecutionRuntime
import Foundation
import FunctionContracts
import Gateway
@_spi(ModelManagement) import ModelKit
import ModelKitOpenAI
import StorageChat
import Testing

@testable import Agents

@Test(.actionCatalog, arguments: ["valid", "nested", "shared", "label", "missing", "root", "order", "silent"])
func qwenExpressionSequenceScoringRejectsBrokenGroups(variant: String) async throws {
    let first = "<express emotion=\"happy\"/>这是开心。"
    let second = "<express emotion=\"thinking\"/>这是思考。"
    let valid = "<wait>\(first)</wait><wait>\(second)</wait>"
    let samples: [String: (String, String?)] = [
        "valid": (valid, nil), "nested": ("<wait>\(valid)</wait>", nil),
        "shared": ("<wait>\(first)\(second)</wait>", "expressionNeedsSeparateWaitGroups"),
        "label": (valid.replacingOccurrences(of: "这是思考", with: "这是开心"), "expressionSpeechLabel:thinking"),
        "missing": ("<wait>\(first)</wait>", "expressionSequence:"),
        "root": ("\(first)\(second)", "expressionNeedsSeparateWaitGroups"),
        "order": ("<wait>\(second)</wait><wait>\(first)</wait>", "expressionSequence:"),
        "silent": ("<express emotion=\"happy\"/><express emotion=\"thinking\"/>", nil),
    ]
    let sample = try #require(samples[variant])
    let expected = QwenTurn(
        user: "Synthetic offline fixture", expressionSequence: ["happy", "thinking"],
        expressionSpeech: variant != "silent")
    let scenario = QwenCase(id: "offline", category: "expression-sequence", turns: [expected])
    let effects = QwenEffects(scenario: scenario, facts: try QwenFacts(scenario: scenario))
    let config = try AgentConfigurations.load(named: "Assistant")
    let catalog = try AgentSkillLoader.registry(
        AgentConfigurations.baseSkills(named: "Assistant"), fixed: config.capabilities)
    var trace = GenerationTrace(capabilities: catalog, textMapping: AssistantAgent.mapText)
    try trace.append(sample.0)
    trace.finish()
    try #require(trace.parserError == nil)
    let input = AgentInput(id: "offline", sessionID: "offline", payload: .text(expected.user))
    for event in trace.events {
        let output: AgentOutput
        switch event {
        case .action(let call), .runtimeAction(let call): output = .actionCall(call)
        default:
            Issue.record("Unexpected fixture event")
            continue
        }
        await effects.record(
            OutputEnvelope(
                source: .assistant, context: input.context, output: output, roundID: "offline",
                taskScope: input.taskScope), aliases: [:])
    }
    let issues = qwenExpressionIssues(expected, calls: await effects.calls)
    if let issue = sample.1 {
        #expect(issues.contains { $0.hasPrefix(issue) })
    } else {
        #expect(issues.isEmpty)
    }
}

@Test(.actionCatalog) func qwenRobotSequenceScoringRejectsWrongAxisOrderAndExtraMoves() {
    let expected = QwenTurn(
        user: "synthetic",
        robotSequence: [
            .init(alias: "moveMotor", parameters: ["motor": "1", "deltaDegrees": "90"]),
            .init(alias: "moveMotor", parameters: ["motor": "1", "deltaDegrees": "-45"]),
        ])
    func call(_ motor: String, _ degrees: String) -> QwenCall {
        QwenCall(
            alias: "moveMotor", path: "NexArm.Motion.moveMotor", kind: "action",
            parameters: ["motor": motor, "deltaDegrees": degrees], channel: "Robot",
            round: "fixture", input: "fixture", waitPath: [])
    }
    let valid = [call("1", "90"), call("1", "-45")]
    #expect(qwenIssues(expected, calls: valid, skills: .init()).isEmpty)
    for invalid in [Array(valid.reversed()), [call("5", "90"), valid[1]], valid + [valid[0]], [valid[0]]] {
        #expect(!qwenIssues(expected, calls: invalid, skills: .init()).isEmpty)
    }
}

/// One model and one input; verifies the real Assistant/Gateway round trip, not answer quality.
@Test(.actionCatalog, .enabled(if: ProcessInfo.processInfo.environment["MH_ASSISTANT_SMOKE"] == "1"))
func assistantSingleModelRequestCompletesThroughGateway() async throws {
    let env = ProcessInfo.processInfo.environment
    let context = try ModelContext(loadGate: ModelLoadGate(maximumConcurrentLoads: 1), maximumLoadWaiters: 4)
    do {
        let provider = try OpenAIChat(
            context: context,
            configuration: OpenAIChatConfiguration(
                baseURL: OpenAIChatConfiguration.endpoint(try #require(env["MH_SMOKE_API_URL"])),
                apiKey: try #require(env["MH_SMOKE_API_KEY"]), model: try #require(env["MH_SMOKE_MODEL"]), timeout: 90))
        let scenario = QwenCase(
            id: "assistant-smoke", category: "communication", turns: [.init(user: "Say hello briefly.")])
        let result = try await qwenRun(scenario, provider: provider, requestLimit: 8)
        #expect(result.runtimeIssues.isEmpty)
        #expect(result.turns.count == 1)
        #expect(result.passed)
        try await context.unload()
    } catch {
        try await context.unload()
        throw error
    }
}
