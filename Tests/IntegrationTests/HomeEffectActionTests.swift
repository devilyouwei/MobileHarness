import Actions
import ExecutionRuntime
import Foundation
import FunctionContracts
import StorageCore
import Testing

@testable import Agents

private func effectInput(_ parameters: [String: String]) -> FunctionInvocation {
    .init(
        call: .init(actionPath: .init(domain: "UI", module: "Light", function: "updateLight"), parameters: parameters),
        context: .init(
            source: "assistant", sessionID: UUID().uuidString, inputID: UUID().uuidString),
        executionID: UUID().uuidString, results: ActionReportStore())
}
@Test func independentEffectsRemainCanonicalWithoutAnySkillGrant() throws {
    let skills = try AgentConfigurations.skillRegistries()
    for path in ["UI.Notice.showNotice", "UI.Notice.dismissNotice", "UI.Light.updateLight"] {
        #expect(UIModule.declarations.contains { $0.path.description == path })
        #expect(skills.allSatisfy { skill in !skill.actions.contains { $0.path.description == path } })
    }
}
@Test func independentEffectActionsValidateBeforeCommit() async throws {
    try await UIActions.updateLight(invocation: effectInput(["enabled": "true", "x": "0.2"])) { request, _ in
        #expect(request.enabled && request.x == 0.2 && request.initialOpacity == 0.85 && request.durationMS == 3000)
    }
    try await UIActions.showNotice(invocation: effectInput(["text": "完成", "tone": "info"])) { request, _ in
        #expect(request.text == "完成" && request.tone == .info && request.durationMS == 8000)
    }
    for args in [
        ["enabled": "yes"], ["enabled": "true", "x": "NaN"], ["enabled": "true", "intensity": "2"],
        ["enabled": "true", "durationMS": "0"], ["enabled": "true", "unknown": "1"],
    ] {
        await #expect(throws: (any Error).self) {
            try await UIActions.updateLight(invocation: effectInput(args)) { _, _ in
                Issue.record("invalid light committed")
            }
        }
    }
    await #expect(throws: (any Error).self) {
        try await UIActions.showNotice(invocation: effectInput(["text": " "])) { _, _ in
            Issue.record("blank notice committed")
        }
    }
    await #expect(throws: (any Error).self) {
        try await UIActions.dismissNotice(invocation: effectInput(["text": "x"])) { _ in
            Issue.record("unknown dismissal committed")
        }
    }
}
