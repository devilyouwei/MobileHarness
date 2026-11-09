import Actions
import AgentCore
import AppStorage
import Foundation
import Gateway
import ModelKitDefaults
import PlatformKit
import Storage
import Synchronization
import Testing

@testable import Agents
@testable import UI

private enum ContextFixtureFailure: Error { case encoding }
private struct FailingContext: Encodable, Sendable {
    func encode(to encoder: any Encoder) throws { throw ContextFixtureFailure.encoding }
}

@Test func reflexivitySevenSchemasPreserveTheSameWireContractAndExactCounters() throws {
    let snapshots: [any Encodable & Sendable] = [
        ActionsStateSnapshot(path: "actions", runtime: ["revision": .unsigned(.max)]),
        AgentStateSnapshot(path: "agents", runtime: ["revision": .unsigned(.max)]),
        GatewayStateSnapshot(path: "gateway", runtime: ["revision": .unsigned(.max)]),
        ModelStateSnapshot(path: "model", runtime: ["revision": .unsigned(.max)]),
        PlatformStateSnapshot(path: "platform", runtime: ["revision": .unsigned(.max)]),
        StorageStateSnapshot(path: "storage", runtime: ["revision": .unsigned(.max)]),
        UIStateSnapshot(path: "ui", runtime: ["revision": .unsigned(.max)]),
    ]
    let expected: Set<String> = [
        "path", "business", "runtime", "health", "issues", "children", "collectedAt", "meanings", "units",
        "stateValues",
    ]
    for snapshot in snapshots {
        let data = try JSONEncoder().encode(snapshot)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == expected)
        let decoded = try JSONDecoder().decode(AppStorage.ApplicationStateSnapshot.self, from: data)
        #expect(decoded.runtime["revision"] == .unsigned(UInt64.max))
        #expect(decoded.business.isEmpty && decoded.children.isEmpty && decoded.health == .unknown)
        let roundTrip = try JSONDecoder().decode(
            AppStorage.ApplicationStateSnapshot.self, from: JSONEncoder().encode(decoded))
        #expect(roundTrip.runtime["revision"] == .unsigned(UInt64.max))
    }
}

@Test @MainActor func reflexivityStorageDirectChildrenReturnTheSameClassifiedContractAsTheTree() async throws {
    let location = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let root = ApplicationContainer(root: location).storage()
    let own = try await root.stateSnapshot()
    let readers = try await root.stateReaders()
    #expect(own.children.map(\.path) == ["storage.cache", "storage.files", "storage.database"])
    for reference in own.children {
        let read = try #require(readers[reference.path])
        let child = try await read()
        #expect(child.path == reference.path && child.business.isEmpty && !child.runtime.isEmpty)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(reference)) as? [String: Any]
        #expect(Set(encoded?.keys.map { $0 } ?? []) == ["path"])
    }
    #expect(!FileManager.default.fileExists(atPath: location.path))
}

@Test @MainActor func reflexivityDiagnosticWorkAndConfigurationAreRuntimeWhileMeasurementsAreBusiness() async throws {
    let root = UIContainer()
    try root.start()
    root.diagnostics.speech.presentRunning(true)
    root.diagnostics.speech.presentStopping(true)
    var observation = AudioDetectionSnapshot()
    observation.input = .external
    observation.capture = .spatial
    observation.support = .supported
    observation.signal = .receiving
    observation.direction = .active
    observation.sampleRate = 48000
    observation.azimuthDegrees = 30
    observation.capturedAt = .now.advanced(by: .seconds(-2))
    observation.directionExpiresAt = .now.advanced(by: .seconds(-1))
    observation.permissionGranted = true
    root.diagnostics.audioDetection.present(.snapshot(observation))
    root.diagnostics.audioDetection.present(.phase(.running))
    let diagnostic = try await root.diagnostics.speech.stateSnapshot()
    let audio = try await root.diagnostics.audioDetection.stateSnapshot()
    #expect(diagnostic.business.isEmpty && diagnostic.runtime["running"] == .flag(true))
    #expect(audio.business["azimuthDegrees"] == .number(30) && audio.business["input"] == .text("external"))
    #expect(audio.runtime["phase"] == .text("running") && audio.runtime["sampleRate"] == .count(48000))
    #expect(audio.business["signalFresh"] == .flag(false) && audio.business["directionFresh"] == .flag(false))
    #expect(root.diagnostics.audioDetection.snapshot.direction == .active)
    #expect(audio.business["capture"] == nil && audio.business["support"] == nil && audio.business["phase"] == nil)
    #expect(audio.stateDescriptor.stateValues["runtime.phase"]?.contains("stopping") == true)
}

@Test @MainActor func reflexivityFormFailureIsABusinessOutcomeRatherThanPresentationHealth() async throws {
    let root = UIContainer()
    try root.start()
    root.settings.state.present(.error("Provider discovery failed"))
    root.modelResources.state.present(.error("Invalid source endpoint"))
    let settings = try await root.settings.stateSnapshot()
    let resources = try await root.modelResources.stateSnapshot()
    #expect(settings.business["problem"] == .text("settingsOperationFailed"))
    #expect(resources.business["problem"] == .text("resourceSettingsOperationFailed"))
    #expect(settings.health == .unknown && resources.health == .unknown)
    #expect(!String(decoding: try JSONEncoder().encode(settings), as: UTF8.self).contains("Provider discovery failed"))
}

@Test func reflexivityMotorBusinessOutcomesDoNotPublishInternalFailureCodes() throws {
    for code in [
        "targetNotReached", "timedOut", "cancelled", "feedbackLost", "disconnected", "sendingFailed", "admissionFailed",
        "feedbackFailed",
    ] {
        let object: [String: Any] = ["step": 0, "motor": 1, "target": 1000, "started": true, "failure": code]
        let result = try JSONDecoder().decode(
            NexArmMotorResult.self, from: JSONSerialization.data(withJSONObject: object))
        switch code {
        case "targetNotReached": #expect(result.outcome == .notReached)
        case "timedOut": #expect(result.outcome == .timedOut)
        case "cancelled": #expect(result.outcome == .cancelled)
        default: #expect(result.outcome == .unconfirmed)
        }
        #expect(result.failure?.rawValue == code)
    }
}

@Test @MainActor func reflexivityInspectionRejectsAmbiguousCategoriesAndInvalidReflectionMetadata() async throws {
    for node in [
        UIStateSnapshot(path: "ui", business: ["phase": .text("visible")], runtime: ["phase": .text("running")]),
        UIStateSnapshot(path: "ui", meanings: ["business.missing": "Undeclared attribute"]),
        UIStateSnapshot(
            path: "ui", runtime: ["phase": .text("typo")], stateValues: ["runtime.phase": ["cold", "running"]]),
    ] {
        let inspection = ApplicationStateInspection()
        try inspection.registerRoot("ui") { node }
        await #expect(throws: StateInspectionError.invalidSnapshot) { try await inspection.snapshot(path: "ui") }
    }
}

@Test func assistantStateBindingsProjectCompleteBusinessWithoutRuntime() async throws {
    let reads = FixtureFactCell([String]())
    let expression = FixtureFactCell("smile")
    let context = AgentStateContext()
    try AssistantStateBindings.register(in: context) { path in
        reads.update { $0.append(path) }
        return AgentStateSnapshot(
            path: path,
            business: [
                "effective": .text(expression.read()), "base": .text("smile"),
                "operation": .text("hiddenLegacyAlbumOperation"),
                "rendererAvailable": .text("hiddenBusinessField"),
                "current": .object([
                    "page": .text("albumPhoto"), "itemID": .text("photo1"), "queue": .text("hiddenNestedField"),
                ]),
            ],
            runtime: ["effective": .text("hiddenRuntime"), "queue": .count(123)],
            health: .fault, issues: [.init(code: "hiddenHealth", impact: "hiddenImpact")],
            children: [.init(path: path + ".hiddenChild")], meanings: ["business.effective": "hiddenMetadata"])
    }
    try context.open(session: "assistant")
    let first = try await context.snapshot(session: "assistant", names: ["ui.home.expression"])
    #expect(first.contains("\"effective\":\"smile\""))
    #expect(
        first.contains("hiddenBusinessField") && !first.contains("hiddenRuntime") && !first.contains("hiddenHealth"))
    expression.update { $0 = "sad" }
    let second = try await context.snapshot(session: "assistant", names: ["ui.home.expression", "ui.navigation"])
    #expect(second.contains("\"effective\":\"sad\"") && second.contains("\"itemID\":\"photo1\""))
    #expect(second.contains("hiddenNestedField") && !second.contains("hiddenRuntime"))
    #expect(reads.read() == ["ui.home.expression", "ui.home.expression", "ui.navigation"])
}

@Test func assistantStateBindingsPreserveUnknownAndDoNotTurnDiagnosticsIntoBusinessDamage() async throws {
    let context = AgentStateContext()
    try AssistantStateBindings.register(in: context) { path in
        AgentStateSnapshot(
            path: path, runtime: ["closed": .flag(true), "queue": .count(1)], health: .fault,
            issues: [.init(code: "cleanupFailure", impact: "diagnosticOnly")])
    }
    try context.open(session: "assistant")
    let unknown = try await context.snapshot(session: "assistant", names: ["ui.home.expression"])
    #expect(unknown.contains("\"availability\":\"unknown\""))
    #expect(!unknown.contains("cleanupFailure") && !unknown.contains("closed") && !unknown.contains("diagnosticOnly"))
    #expect(try await context.snapshot(session: "assistant", names: ["system.health"]).contains("unknown"))
}

@Test func assistantStateBindingsSelectParentAndChildIndependently() async throws {
    let reads = FixtureFactCell([String]())
    let context = AgentStateContext()
    try AssistantStateBindings.register(in: context) { path in
        reads.update { $0.append(path) }
        return AgentStateSnapshot(
            path: path, business: ["connected": .flag(true), "targetCounts": .object(["1": .count(1000)])],
            children: [.init(path: path + ".motor1")])
    }
    try context.open(session: "assistant")
    let parent = try await context.snapshot(session: "assistant", names: ["actions.robot"])
    #expect(reads.read() == ["actions.robot"])
    #expect(!parent.contains("motor1") && parent.contains("targetCounts"))
    let motion = try await context.snapshot(session: "assistant", names: ["actions.robot.motion"])
    #expect(motion.contains("1000") && reads.read() == ["actions.robot", "actions.robot.motion"])
}

@Test func assistantStateBindingsIsolateReadFailuresAndRespectSourceSelection() async throws {
    let context = AgentStateContext()
    try AssistantStateBindings.register(in: context) { _ in throw ContextFixtureFailure.encoding }
    try context.open(session: "assistant")
    #expect(try await context.snapshot(session: "assistant", names: []) == "{}")
    #expect(try await context.snapshot(session: "assistant", names: ["actions.robot"]).contains("stateUnavailable"))
}

@Test @MainActor func reflexivityRuntimeCountersRemainAvailableWithoutBusinessClassification() async throws {
    let actions = ActionsContainer()
    let snapshot = try await actions.stateSnapshot()
    #expect(snapshot.business.isEmpty)
    #expect(snapshot.runtime["prepared"] == .count(0) && snapshot.runtime["executing"] == .count(0))
    let ui = UIContainer()
    try ui.start()
    ui.navigation.state.show(.album)
    let navigation = try await ui.navigation.stateSnapshot()
    #expect(navigation.business["operation"] == nil)
    #expect(try await ui.album.stateSnapshot().business["operation"] == .unknown)
    #expect(navigation.business["path"] == .texts(["settings", "album"]))
    #expect(navigation.business["phase"] == .text("transitioning"))
    #expect(navigation.runtime["available"] == .flag(true))
    #expect(try await ui.home.stateSnapshot().business["ready"] == nil)
    await ui.stop()
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
    let before = try await context.snapshot(session: "one", names: ["platform.vision.camera"])
    owner.camera.update { $0.running = true }
    let after = try await context.snapshot(session: "one", names: ["platform.vision.camera"])
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

@Test(.actionCatalog) func skillStatesFollowDependenciesWithoutOwningFacts() async throws {
    let owner = PublicStateFixtureOwner()
    let context = try owner.context()
    try context.open(session: "one")
    let fixed = try AssistantAgent.runtimeCapabilities(AgentConfigurations.load(named: "Assistant").capabilities)
    var skills = AgentTaskSkillState()
    try skills.initialize(fixed: fixed, baseSkills: ["basic-skill"])
    #expect(
        try AgentSkillLoader.useStates(skills.loaded)
            == (FixedPlatformState.sourceNames + [
                "agents.applicationcontrol", "agents.writer", "ui.navigation", "ui.windows",
            ]).sorted())
    _ = try skills.control("loadSkills", arguments: ["skills": "[\"photography\"]"], inputID: "input", fixed: fixed)
    let names = try AgentSkillLoader.useStates(skills.loaded)
    #expect(
        names
            == (FixedPlatformState.sourceNames + [
                "actions.camera", "actions.camera.preview", "agents.applicationcontrol", "agents.writer",
                "platform.vision.camera", "ui.album",
                "ui.camera",
                "ui.navigation", "ui.windows", "ui.island",
            ]).sorted())
    _ = try skills.control("releaseSkills", arguments: ["skills": "[\"photography\"]"], inputID: "input", fixed: fixed)
    owner.camera.update { $0.running = true }
    #expect(
        try AgentSkillLoader.useStates(skills.loaded)
            == (FixedPlatformState.sourceNames + [
                "agents.applicationcontrol", "agents.writer", "ui.navigation", "ui.windows",
            ]).sorted())
    #expect(try await context.snapshot(session: "one", names: ["platform.vision.camera"]).contains("\"running\":true"))
}

@Test(.actionCatalog) func agentTaskContextIsSessionBoundAndHasNoPrivateRegistry() throws {
    var skills = AgentTaskSkillState()
    let fixed = try AssistantAgent.runtimeCapabilities(AgentConfigurations.load(named: "Assistant").capabilities)
    try skills.initialize(fixed: fixed, baseSkills: ["basic-skill"])
    _ = try skills.control(
        "task.start", arguments: ["description": "拍照"], inputID: "input", fixed: fixed,
        sessionID: "one", taskID: try fixtureTaskID())
    let snapshot = skills.contextSnapshot(session: "one")
    #expect(snapshot.task?.goal == "拍照" && snapshot.task?.status == "running")
    #expect(skills.contextSnapshot(session: "two").task == nil)
    let json = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
    #expect(!json.contains("inputIDs") && !json.contains("executor") && !json.contains("taskSkillRoots"))
}

@Test func skillInstructionsRequireExplicitCurrentPaths() throws {
    let skill = try AgentConfigurations.skill("basic-skill")
    var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(skill)) as? [String: Any])
    json.removeValue(forKey: "useInstructions")
    func decode() throws -> AgentConfigurations.Skill {
        try JSONDecoder().decode(AgentConfigurations.Skill.self, from: JSONSerialization.data(withJSONObject: json))
    }
    #expect(throws: DecodingError.self) { try decode() }
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

@Test @MainActor func reflexivityReadsExpressionOwnerAndRestoresBase() async throws {
    let ui = UIContainer()
    try ui.start()
    let home = ui.home
    let read = try #require(try await home.stateReaders()["ui.home.expression"])
    home.conversation.isVoiceActive = true
    home.expressions.setBase(.smile)
    #expect(try await read().business["base"] == .text("smile"))
    #expect(try await read().business["effective"] == .text("smile"))
    home.conversation.expressionRendererAvailable = true
    let performance = Task { try await home.expressions.perform(.sad, owner: "test") }
    while try await read().business["transitioning"] != .flag(true) { await Task.yield() }
    #expect(try await read().business["overridden"] == .flag(true))
    #expect(try await read().business["effective"] == .text("sad"))
    performance.cancel()
    _ = await performance.result
    try await home.expressions.restore(owner: "test", accepts: false)
    #expect(try await read().business["overridden"] == .flag(false))
    #expect(try await read().business["effective"] == .text("smile"))
    let children = try await ui.stateSnapshot().children.map(\.path)
    #expect(children.count == 12 && Set(children).count == 12)
    await ui.stop()
}

@Test @MainActor func reflexivityColdReadsDoNotPrepareModelsOrNativeDrivers() async throws {
    let prepared = FixtureFactCell(0)
    let model = ModelContainer(
        resources: .temporaryDirectory,
        prepareArtifacts: {
            prepared.update { $0 += 1 }
            throw ContextFixtureFailure.encoding
        })
    #expect(try await model.stateSnapshot().children.count == 4)
    #expect(try await model.language.stateSnapshot().runtime["assembled"] == .flag(false))
    _ = try await model.stateReaders()
    #expect(prepared.read() == 0)
    let platform = PlatformContainer()
    #expect(try await platform.stateSnapshot().children.count == 4)
    let reader = try #require(try await platform.stateReaders()["platform.connectivity.nexarm"])
    let arm = try await reader()
    #expect(arm.business["positionsCounts"] == .unknown)
    #expect(arm.business["feedbackFresh"] == .flag(false))
    #expect(platform.connectivity.bluetooth.reflectedState?.snapshot()?.revision == 0)
}

@Test @MainActor func reflexivityTreeBoundsPartialFailureAndExplicitFields() async throws {
    let inspector = ApplicationStateInspection()
    let calls = FixtureFactCell([String]())
    try inspector.registerRoot(
        "ui",
        readers: {
            [
                "ui": { @Sendable in
                    calls.update { $0.append("ui") }
                    return UIStateSnapshot(path: "ui", children: [.init(path: "ui.home")])
                },
                "ui.home": { @Sendable in
                    calls.update { $0.append("ui.home") }
                    return UIStateSnapshot(
                        path: "ui.home", business: ["ready": .flag(true)], children: [.init(path: "ui.home.expression")]
                    )
                },
                "ui.home.expression": { @Sendable in
                    calls.update { $0.append("ui.home.expression") }
                    return UIStateSnapshot(path: "ui.home.expression", business: ["effective": .text("smile")])
                },
            ]
        })
    try inspector.registerRoot("model") { () throws -> UIStateSnapshot in throw ContextFixtureFailure.encoding }
    let leaf = try await inspector.snapshot(path: "ui.home.expression")
    #expect(leaf.business["effective"] == .text("smile"))
    #expect(calls.read() == ["ui.home.expression"])
    let own = try await inspector.snapshot(path: "ui")
    #expect(own.children.map(\.path) == ["ui.home"] && calls.read() == ["ui.home.expression", "ui"])
    let zero = try await inspector.inspectTree(path: "ui.home", depth: 0)
    #expect(zero.children.isEmpty && zero.state.children.count == 1)
    #expect(try await inspector.describe(path: "ui.home").children.first?.path == "ui.home.expression")
    #expect(try await inspector.snapshot(path: "model").readFailure == "ownerReadFailed")
    await #expect(throws: StateInspectionError.missing) { try await inspector.snapshot(path: "ui.missing") }
    await #expect(throws: StateInspectionError.capacityExceeded) {
        try await inspector.inspectTree(path: "ui", depth: 17)
    }
    let tree = try await inspector.inspectTree(path: "ui")
    #expect(tree.nodeCount == 3)
}

@Test @MainActor func reflexivityTreeRejectsOversizeDuplicatePathsAndCancellation() async throws {
    let oversized = ApplicationStateInspection()
    try oversized.registerRoot("ui") {
        UIStateSnapshot(path: "ui", business: ["large": .text(String(repeating: "x", count: 256 * 1024))])
    }
    await #expect(throws: StateInspectionError.capacityExceeded) { try await oversized.snapshot(path: "ui") }
    let duplicate = ApplicationStateInspection()
    try duplicate.registerRoot("ui") {
        UIStateSnapshot(path: "ui", children: [.init(path: "ui.home"), .init(path: "ui.home")])
    }
    await #expect(throws: StateInspectionError.invalidSnapshot) { try await duplicate.snapshot(path: "ui") }
    let cancelled = Task { @MainActor in
        withUnsafeCurrentTask { $0?.cancel() }
        return try await duplicate.snapshot(path: "ui")
    }
    await #expect(throws: CancellationError.self) { try await cancelled.value }
}

@Test(.actionCatalog) func reflexivityDisclosureFollowsEffectiveSkillsAndRelease() async throws {
    let fixed = try AssistantAgent.runtimeCapabilities(AgentConfigurations.load(named: "Assistant").capabilities)
    var skills = AgentTaskSkillState()
    try skills.initialize(fixed: fixed, baseSkills: ["basic-skill"])
    let basic = try AgentSkillLoader.useStates(skills.loaded)
    #expect(!basic.contains("system.health"))
    #expect(
        !basic.contains("ui.home.expression") && !basic.contains("actions.robot")
            && !basic.contains("system.diagnostics"))
    _ = try skills.control(
        "loadSkills", arguments: ["skills": "[\"expression-interaction\"]"], inputID: "input", fixed: fixed)
    #expect(try AgentSkillLoader.useStates(skills.loaded).contains("ui.home.expression"))
    _ = try skills.control(
        "releaseSkills", arguments: ["skills": "[\"expression-interaction\"]"], inputID: "input", fixed: fixed)
    #expect(!((try AgentSkillLoader.useStates(skills.loaded)).contains("ui.home.expression")))
}

@Test @MainActor func reflexivityAllModuleShapesComposeWithoutCreatingStorage() async throws {
    let location = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let registry = ApplicationContainer(root: location)
    let ui = registry.ui()
    let platform = registry.platform()
    let model = registry.model()
    let storage = registry.storage()
    let actions = registry.actions()
    let gateway = registry.gateway()
    let inspector = ApplicationStateInspection()
    try inspector.registerRoot("ui", readers: { try await ui.stateReaders() })
    try inspector.registerRoot("platform", readers: { try await platform.stateReaders() })
    try inspector.registerRoot("model", readers: { try await model.stateReaders() })
    try inspector.registerRoot("storage", readers: { try await storage.stateReaders() })
    try inspector.registerRoot("actions", readers: { try await actions.stateReaders() })
    try inspector.registerRoot("gateway", readers: { try await gateway.stateReaders() })
    try inspector.registerRoot("agents") { AgentStateSnapshot(path: "agents") }
    #expect(inspector.rootPaths.count == 7)
    var all: [AppStorage.ApplicationStateSnapshot] = []
    func nodes(_ tree: ApplicationStateInspection.Tree) -> [AppStorage.ApplicationStateSnapshot] {
        [tree.state] + tree.children.flatMap(nodes)
    }
    for path in inspector.rootPaths { all += nodes(try await inspector.inspectTree(path: path)) }
    #expect(all.allSatisfy { $0.readFailure == nil })
    for node in all where node.path.hasPrefix("gateway") { #expect(node.business.isEmpty && !node.runtime.isEmpty) }
    let cache = try #require(all.first { $0.path == "storage.cache" })
    #expect(cache.business.isEmpty && cache.runtime["maximumBytes"] != nil)
    let language = try #require(all.first { $0.path == "model.language" })
    #expect(language.business.isEmpty && language.runtime["assembled"] == .flag(false))
    let audio = try #require(all.first { $0.path == "platform.audio" })
    #expect(audio.business["microphoneAuthorization"] != nil && audio.business["owner"] == nil)
    #expect(!FileManager.default.fileExists(atPath: location.path))
    #expect(
        try await inspector.describe(path: "ui.home.expression").stateValues["business.effective"]?.contains("smile")
            == true)
}

@Test(.actionCatalog) func singleNodeSkillsDeclareCanonicalChildrenWithoutAncestorOrSummaryGrants() throws {
    #expect(try AgentConfigurations.skill("expression-interaction").useStates == ["ui.home.expression"])
    let robot = try AgentConfigurations.skill("robot-interaction").useStates
    #expect(robot == ["actions.robot", "actions.robot.motion"])
    let skillIDs = try bundledStateSkillIDs()
    let selected = try Set(skillIDs.flatMap { try AgentConfigurations.skill($0).useStates })
    #expect(selected.contains("ui.web"))
    #expect(!selected.contains("ui") && !selected.contains("ui.home"))
    #expect(!selected.contains("system.health") && !selected.contains("system.diagnostics"))
}

@Test @MainActor func singleNodeReaderCapabilitiesDoNotRetainReleasedContainers() async throws {
    func makeReader() -> UIStateSnapshot.Reader {
        let owner = UIContainer()
        return UIStateSnapshot.reader(of: owner) { try await $0.stateSnapshot() }
    }
    let read = makeReader()
    await #expect(throws: UIStateSnapshot.ReadError.self) { try await read() }
}

@Test @MainActor func reflexivitySpeechRoutingPreferencesRemainRuntimeAndDoNotPrepareProviders() async throws {
    let prepared = FixtureFactCell(0)
    let root = ModelContainer(
        resources: .temporaryDirectory,
        prepareArtifacts: {
            prepared.update { $0 += 1 }
            throw ContextFixtureFailure.encoding
        })
    try await root.speech.configure(recognition: true, synthesis: false)
    let first = try await root.speech.stateSnapshot()
    #expect(first.business.isEmpty)
    #expect(first.runtime["preferCustomRecognition"] == .flag(true))
    #expect(first.runtime["preferCustomSynthesis"] == .flag(false))
    try await root.speech.configure(recognition: false, synthesis: true)
    let second = try await root.speech.stateSnapshot()
    #expect(second.business.isEmpty)
    #expect(second.runtime["preferCustomRecognition"] == .flag(false))
    #expect(second.runtime["preferCustomSynthesis"] == .flag(true))
    #expect(prepared.read() == 0)
    try await root.stop()
}

@Test @MainActor func assistantStateSelectionDoesNotAlterTheProducersFullState() async throws {
    let root = UIContainer()
    try root.start()
    root.home.conversation.expressionRendererAvailable = true
    root.home.expressions.setBase(.smile)
    let inspection = ApplicationStateInspection()
    try inspection.registerRoot("ui", readers: { try await root.stateReaders() })
    let full = try await inspection.snapshot(path: "ui.home.expression")
    #expect(full.runtime["rendererAvailable"] == .flag(true))
    let context = AgentStateContext()
    try AssistantStateBindings.register(in: context) { path in try await inspection.snapshot(path: path) }
    try context.open(session: "decoupling")
    let assistant = try await context.snapshot(session: "decoupling", names: ["ui.home.expression"])
    #expect(assistant.contains("smile") && !assistant.contains("rendererAvailable"))
    let after = try await inspection.snapshot(path: "ui.home.expression")
    #expect(after.business == full.business && after.runtime == full.runtime)
    context.close()
    await root.stop()
}

@Test @MainActor func cameraFoundationSnapshotDoesNotCreateOrActivateCamera() async throws {
    let platform = PlatformContainer()
    let before = try await platform.vision.stateSnapshot()
    let first = try await platform.vision.cameraStateSnapshot()
    let second = try await platform.vision.cameraStateSnapshot()
    #expect(first.business["running"] == .flag(false))
    #expect(first.business["phase"] == .text("stopped"))
    #expect(first.business["facing"] == .unknown)
    #expect(first.runtime["created"] == .flag(false) && second.runtime["created"] == .flag(false))
    #expect(before.children.contains { $0.path == "platform.vision.camera" })
    #expect(try await platform.vision.stateSnapshot().runtime == before.runtime)
}

private func bundledStateSkillIDs() throws -> [String] {
    struct Catalog: Decodable { let skills: [String: String] }
    return try JSONDecoder().decode(Catalog.self, from: AgentConfigurations.data("Catalog.json")).skills.keys.sorted()
}

@Test(.actionCatalog) @MainActor func everySharedSkillCanCollectContextAfterLoadingAndRelease() async throws {
    let registry = ApplicationContainer(root: .temporaryDirectory.appendingPathComponent(UUID().uuidString))
    let ui = registry.ui()
    let platform = registry.platform()
    let inspection = ApplicationStateInspection()
    try inspection.registerRoot("ui", readers: { try await ui.stateReaders() })
    try inspection.registerRoot("platform", readers: { try await platform.stateReaders() })
    // iOS-only business and Agent facts are explicit fixtures; UI/Platform readers are real.
    try inspection.registerRoot(
        "actions",
        readers: {
            [
                "actions": { @Sendable in ActionsStateSnapshot(path: "actions") },
                "actions.camera": { @Sendable in ActionsStateSnapshot(path: "actions.camera") },
                "actions.camera.preview": { @Sendable in ActionsStateSnapshot(path: "actions.camera.preview") },
                "actions.robot": { @Sendable in ActionsStateSnapshot(path: "actions.robot") },
                "actions.robot.motion": { @Sendable in ActionsStateSnapshot(path: "actions.robot.motion") },
            ]
        })
    try inspection.registerRoot(
        "agents",
        readers: {
            [
                "agents": { @Sendable in AgentStateSnapshot(path: "agents") },
                "agents.writer": { @Sendable in AgentStateSnapshot(path: "agents.writer") },
                "agents.applicationcontrol": { @Sendable in AgentStateSnapshot(path: "agents.applicationcontrol") },
            ]
        })
    let context = AgentStateContext()
    try AssistantStateBindings.register(in: context) { try await inspection.snapshot(path: $0) }
    try context.open(session: "web-regression")
    let fixed = try AssistantAgent.runtimeCapabilities(AgentConfigurations.load(named: "Assistant").capabilities)
    let base = try AgentConfigurations.baseSkills(named: "Assistant")
    let shared = try bundledStateSkillIDs().filter { try AgentConfigurations.skill($0).owner == nil }
    for id in shared where !base.contains(id) {
        var skills = AgentTaskSkillState()
        try skills.initialize(fixed: fixed, baseSkills: base)
        _ = try skills.control("loadSkills", arguments: ["skills": "[\"\(id)\"]"], inputID: "input", fixed: fixed)
        let names = try AgentSkillLoader.useStates(skills.loaded)
        let snapshot = try await context.snapshot(session: "web-regression", names: names)
        let fields = try #require(JSONSerialization.jsonObject(with: Data(snapshot.utf8)) as? [String: Any])
        #expect(Set(fields.keys) == Set(names))
        #expect(!snapshot.contains("stateUnavailable"))
        if id == "web-browsing" {
            #expect(names.contains("ui.web") && names.contains("ui.windows"))
            #expect(snapshot.contains("empty"))
            #expect(!snapshot.contains("file://"))
        }
        _ = try skills.control("releaseSkills", arguments: ["skills": "[\"\(id)\"]"], inputID: "input", fixed: fixed)
        let released = try AgentSkillLoader.useStates(skills.loaded)
        #expect(!released.contains("ui.web"))
        _ = try await context.snapshot(session: "web-regression", names: released)
    }
    context.close()
    await ui.stop()
}

@Test func skillSelectedNewNodesNeedNoAssistantRegistrationAndFailuresAreIsolated() async throws {
    let context = AgentStateContext()
    let reads = FixtureFactCell([String]())
    try AssistantStateBindings.register(in: context) { path in
        reads.update { $0.append(path) }
        if path == "fixture.missing" { throw ContextFixtureFailure.encoding }
        return AgentStateSnapshot(
            path: path, business: ["nested": .object(["items": .array([.text("kept")])])],
            runtime: ["secret": .text("not-observable")], children: [.init(path: "fixture.child")])
    }
    try context.open(session: "test")
    let result = try await context.snapshot(session: "test", names: ["fixture.new", "fixture.missing"])
    #expect(result.contains("kept") && result.contains("stateUnavailable"))
    #expect(
        result.contains("\"value\":null") && !result.contains("not-observable") && !result.contains("fixture.child"))
    #expect(reads.read() == ["fixture.missing", "fixture.new"])
    context.close()
    await #expect(throws: ContainerContextError.closed) { try await context.snapshot(session: "test", names: []) }
}

@Test(.actionCatalog) @MainActor func assistantDefaultStateSeesSharedArtifactWindowsBeforeLoadingWindowSkills()
    async throws
{
    let ui = UIContainer()
    ui.windows.layout(width: 390, height: 750)
    ui.windows.setAvailable(true)
    let creation = Task { try await ui.windows.present(content: .artifact, title: "Writer shared canvas") }
    let deadline = ContinuousClock.now + .seconds(20)
    while ui.windows.windows.isEmpty {
        guard ContinuousClock.now < deadline else { throw WindowError.unavailable }
        await Task.yield()
    }
    let item = try #require(ui.windows.windows.first)
    ui.windows.complete(item.id, revision: item.revision, generation: ui.windows.generation, success: true)
    let id = try await creation.value
    let inspection = ApplicationStateInspection()
    try inspection.registerRoot("ui", readers: { try await ui.stateReaders() })
    let context = AgentStateContext()
    try AssistantStateBindings.register(in: context) { try await inspection.snapshot(path: $0) }
    try context.open(session: "shared-window")
    let fixed = try AssistantAgent.runtimeCapabilities(AgentConfigurations.load(named: "Assistant").capabilities)
    var skills = AgentTaskSkillState()
    try skills.initialize(fixed: fixed, baseSkills: AgentConfigurations.baseSkills(named: "Assistant"))
    #expect(!skills.loaded.contains("web-browsing") && !skills.loaded.contains("application-control"))
    #expect(try AgentSkillLoader.useStates(skills.loaded).contains("ui.windows"))
    let state = try await context.snapshot(session: "shared-window", names: ["ui.windows"])
    #expect(
        !state.contains(id.uuidString) && state.contains("window_1") && state.contains("Writer shared canvas")
            && state.contains("artifact"))
    _ = try skills.control("loadSkills", arguments: ["skills": "[\"web-browsing\"]"], inputID: "inspect", fixed: fixed)
    let directory = try skills.registry(fixed: fixed)
    let query = try directory.resolveAction("Web.inspect", parameters: ["windowID": "window_1"])
    #expect(query.parameters["windowID"] == "window_1")
    #expect(try AgentSkillLoader.useStates(skills.loaded).contains("ui.web"))
    context.close(session: "shared-window")
    await ui.windows.stop()
}
