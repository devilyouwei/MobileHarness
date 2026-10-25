import AgentCore
import Foundation
import Synchronization
import Testing

@testable import Agents

private enum ContextFixtureFailure: Error { case encoding }
private struct FailingContext: Encodable, Sendable {
    func encode(to encoder: any Encoder) throws { throw ContextFixtureFailure.encoding }
}
private actor ContextReadBarrier {
    private var entered = false
    private var release: CheckedContinuation<Void, Never>?
    func read() async -> ContainerContextValue<Bool> {
        entered = true
        await withCheckedContinuation { release = $0 }
        return ContainerContextValue(true)
    }
    func wait() async {
        while !entered { await Task.yield() }
    }
    func resume() {
        release?.resume()
        release = nil
    }
}

@Test func containerContextsReadOwnersWithoutCachingAndRejectInvalidSources() async throws {
    let owner = PublicStateFixtureOwner()
    let context = try owner.context()
    try context.open(session: "one")
    let before = try await context.snapshot(session: "one", names: ["actions.camera"])
    owner.camera.update { $0.running = true }
    let after = try await context.snapshot(session: "one", names: ["actions.camera"])
    #expect(before.contains("\"running\":false") && after.contains("\"running\":true"))
    #expect(throws: ContainerContextError.duplicate) {
        try context.register("actions.camera", source: ContainerContextSource { true })
    }
    await #expect(throws: ContainerContextError.missing) {
        try await context.snapshot(session: "one", names: ["agent.private"])
    }
    await #expect(throws: ContainerContextError.closed) {
        try await context.snapshot(session: "other", names: [])
    }
    context.close()
    #expect(throws: ContainerContextError.closed) { try context.open(session: "one") }
    await #expect(throws: ContainerContextError.closed) { try await context.snapshot(session: "one", names: []) }
}

@Test func containerContextEncodedSourcesPreserveJSONObjectsAndFailures() async throws {
    let data = Data(#"{"available":true,"count":2}"#.utf8)
    let source = ContainerContextSource(encoded: { data })
    #expect(try await source.contextSnapshot() == data)
    let context = AgentStateContext()
    try context.register("fixture.encoded", source: source)
    try context.register(
        "fixture.failure", source: ContainerContextSource(encoded: { throw ContextFixtureFailure.encoding }))
    try context.open(session: "one")
    let collected = try await context.snapshot(session: "one", names: ["fixture.encoded"])
    let object = try #require(JSONSerialization.jsonObject(with: Data(collected.utf8)) as? [String: Any])
    let snapshot = try #require(object["fixture.encoded"] as? [String: Any])
    #expect(snapshot["available"] as? Bool == true)
    #expect(snapshot["count"] as? Int == 2)
    await #expect(throws: ContextFixtureFailure.self) {
        try await context.snapshot(session: "one", names: ["fixture.failure"])
    }
}

@Test func containerContextBudgetsAndEncodingFailureAreExplicit() async throws {
    let context = AgentStateContext()
    try context.open(session: "session")
    for name in ["", "ui..page", ".ui.page", "ui.page.", "UI.page", "ui.*"] {
        #expect(throws: ContainerContextError.invalidName) {
            try context.register(name, source: ContainerContextSource { true })
        }
    }
    try context.register("fixture.large", source: ContainerContextSource { String(repeating: "x", count: 8192) })
    await #expect(throws: ContainerContextError.capacityExceeded) {
        try await context.snapshot(session: "session", names: ["fixture.large"])
    }
    try context.register("fixture.failure", source: ContainerContextSource { FailingContext() })
    await #expect(throws: ContextFixtureFailure.self) {
        try await context.snapshot(session: "session", names: ["fixture.failure"])
    }
    for index in 0..<3 {
        try context.register(
            "fixture.value\(index)", source: ContainerContextSource { String(repeating: "x", count: 6000) })
    }
    await #expect(throws: ContainerContextError.capacityExceeded) {
        try await context.snapshot(session: "session", names: (0..<3).map { "fixture.value\($0)" })
    }
    await #expect(throws: ContainerContextError.capacityExceeded) {
        try await context.snapshot(session: "session", names: ["fixture.failure", "fixture.failure"])
    }
    for index in 0..<251 {
        try context.register("fixture.bound\(index)", source: ContainerContextSource { true })
    }
    #expect(throws: ContainerContextError.capacityExceeded) {
        try context.register("fixture.overflow", source: ContainerContextSource { true })
    }
}

@Test(arguments: [false, true]) func containerContextRejectsReadAfterSessionReplacementOrCancellation(_ cancel: Bool)
    async throws
{
    let context = AgentStateContext()
    let barrier = ContextReadBarrier()
    try context.register("fixture.wait", source: ContainerContextSource { await barrier.read() })
    try context.open(session: "one")
    let read = Task { try await context.snapshot(session: "one", names: ["fixture.wait"]) }
    await barrier.wait()
    if cancel {
        read.cancel()
    } else {
        context.close(session: "one")
        try context.open(session: "one")
    }
    await barrier.resume()
    if cancel {
        await #expect(throws: CancellationError.self) { try await read.value }
    } else {
        await #expect(throws: ContainerContextError.closed) { try await read.value }
    }
}

@Test func skillStatesFollowDependenciesWithoutOwningFacts() async throws {
    let owner = PublicStateFixtureOwner()
    let context = try owner.context()
    try context.open(session: "one")
    let fixed = try AssistantAgent.runtimeCapabilities(AgentConfigurations.load(named: "Assistant").capabilities)
    var skills = AgentTaskSkillState()
    try skills.initialize(fixed: fixed, baseSkills: ["basic-skill"])
    #expect(try AgentSkillLoader.useStates(skills.loaded) == ["ui.navigation"])
    _ = try skills.control("loadSkills", arguments: ["skills": "[\"photography\"]"], inputID: "input", fixed: fixed)
    let names = try AgentSkillLoader.useStates(skills.loaded)
    #expect(names == ["actions.camera", "ui.album", "ui.camera", "ui.navigation"])
    _ = try skills.control("releaseSkills", arguments: ["skills": "[\"photography\"]"], inputID: "input", fixed: fixed)
    owner.camera.update { $0.running = true }
    #expect(try AgentSkillLoader.useStates(skills.loaded) == ["ui.navigation"])
    #expect(try await context.snapshot(session: "one", names: ["actions.camera"]).contains("\"running\":true"))
}

@Test func agentTaskContextIsSessionBoundAndHasNoPrivateRegistry() throws {
    var skills = AgentTaskSkillState()
    let fixed = try AssistantAgent.runtimeCapabilities(AgentConfigurations.load(named: "Assistant").capabilities)
    try skills.initialize(fixed: fixed, baseSkills: ["basic-skill"])
    _ = try skills.control(
        "startTask", arguments: ["goal": "拍照"], inputID: "input", fixed: fixed,
        sessionID: "one", taskID: try fixtureTaskID())
    let snapshot = skills.contextSnapshot(session: "one")
    #expect(snapshot.task?.goal == "拍照" && snapshot.task?.status == "running")
    #expect(skills.contextSnapshot(session: "two").task == nil)
    let json = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
    #expect(!json.contains("inputIDs") && !json.contains("executor") && !json.contains("taskSkillRoots"))
}

@Test func skillInstructionsDefaultOrderAndPathValidation() throws {
    let skill = try AgentConfigurations.skill("basic-skill")
    var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(skill)) as? [String: Any])
    json.removeValue(forKey: "useInstructions")
    func decode() throws -> AgentConfigurations.Skill {
        try JSONDecoder().decode(AgentConfigurations.Skill.self, from: JSONSerialization.data(withJSONObject: json))
    }
    #expect(try decode().useInstructions == ["Instructions.md"])
    json["useInstructions"] = ["Second.md", "First.md"]
    #expect(try decode().useInstructions == ["Second.md", "First.md"])
    json["useInstructions"] = []
    #expect(try decode().useInstructions.isEmpty)
    for name in ["../Outside.md", "/Outside.md", "a\\b.md", "a//b.md", "note.txt"] {
        json["useInstructions"] = [name]
        #expect(throws: AgentConfigurationError.self) { try decode() }
    }
    json["version"] = 2
    #expect(throws: AgentConfigurationError.self) { try decode() }
}
