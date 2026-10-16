import ActionBindings
import Actions
import AgentBindings
import AgentCore
import Agents
import ExecutionRuntime
import Foundation
import FunctionContracts
import Gateway
import PlatformKit
import StorageCore
import StorageState
import Testing

private enum PresentationFixtureError: Error { case queryFailure, snapshotFailure, failurePresentation }
private actor PresentedInventoryFixture: ModelResourceInventoryCapability {
    var reads = 0
    var fails = false
    var large = false
    func useLargeInventory() { large = true }
    func failNext() { fails = true }
    func snapshotResources() throws -> [ModelResourceFact] {
        reads += 1
        if fails {
            fails = false
            throw PresentationFixtureError.queryFailure
        }
        if large {
            return (0..<22).map { index in
                .init(
                    id: index == 0 ? "nemotron" : "model\(index)", name: String(repeating: "a", count: 256),
                    revision: String(repeating: "b", count: 512), license: String(repeating: "c", count: 512),
                    bytes: 100, completedBytes: 42, phase: .installed, failure: String(repeating: "d", count: 1024))
            }
        }
        return [.init(id: "nemotron", name: "ASR", bytes: 100, completedBytes: 42, phase: .installed)]
    }
}
private actor ResourcePresentationFixture: ResourcePresentationCapability {
    var snapshots: [UInt64] = []
    var errors: [String] = []
    var failSnapshot = false
    var failError = false
    func failures(snapshot: Bool = false, error: Bool = false) {
        failSnapshot = snapshot
        failError = error
    }
    func presentResources(_ inventory: ModelResourceInventory, generation: UInt64, invocation: any FunctionInput)
        throws
    {
        if failSnapshot { throw PresentationFixtureError.snapshotFailure }
        #expect(inventory.items[0].progress == 0.42)
        #expect(inventory.installedGroups == [.recognition])
        snapshots.append(generation)
    }
    func presentResourcePreferenceFailure(
        _ reason: ResourcePreferenceFailureReason, message: String, invocation: any FunctionInput
    ) async throws {
        throw CancellationError()
    }
    func presentResourceOperationFailure(_ message: String, invocation: any FunctionInput) async throws {
        throw CancellationError()
    }
    func presentResourceFailure(_ message: String, generation: UInt64, invocation: any FunctionInput) throws {
        if failError { throw PresentationFixtureError.failurePresentation }
        errors.append(message)
    }
}
@Test(.actionCatalog) func resourceRefreshPresentsOnceThroughGatewayAndReportsQueryFailureBeforeTerminalCompletion()
    async throws
{
    let inventory = PresentedInventoryFixture()
    let presentation = ResourcePresentationFixture()
    let runtime = try resourceRuntime(UnusedModelResourceCapability(), inventory: inventory, presentation: presentation)
    let raw = try await runtime.presentInventory(generation: 1)
    #expect(try ModelResourceInventory.decode(raw).installedGroups == [.recognition])
    #expect(await presentation.snapshots == [1])
    #expect(await inventory.reads == 1)
    await inventory.failNext()
    do {
        _ = try await runtime.presentInventory(generation: 2)
        Issue.record("Failed query must terminate as failure after error presentation")
    } catch ApplicationControlIntentFailure.presented(let message) {
        #expect(message.contains("queryFailure"))
    }
    #expect(await presentation.errors.count == 1)
    #expect(await presentation.errors.first?.contains("queryFailure") == true)
    _ = try await runtime.presentInventory(generation: 3)
    #expect(await presentation.snapshots == [1, 3])
    #expect(await inventory.reads == 3)
    #expect(await runtime.agent.status().queuedInputs == 0)
    await runtime.shutdown()
}
@Test(.actionCatalog) func resourcePresentationFailureRetainsBothCausesAndDoesNotBlockNextRefresh() async throws {
    let inventory = PresentedInventoryFixture()
    let presentation = ResourcePresentationFixture()
    let runtime = try resourceRuntime(UnusedModelResourceCapability(), inventory: inventory, presentation: presentation)
    await presentation.failures(snapshot: true, error: true)
    do {
        _ = try await runtime.presentInventory(generation: 1)
        Issue.record("Both presentation failures must be surfaced")
    } catch ApplicationControlIntentFailure.execution(let message) {
        #expect(message.contains("snapshotFailure"))
        #expect(message.contains("failurePresentation"))
    }
    #expect(await presentation.snapshots.isEmpty)
    #expect(await presentation.errors.isEmpty)
    #expect(await inventory.reads == 1)
    await presentation.failures()
    _ = try await runtime.presentInventory(generation: 2)
    #expect(await presentation.snapshots == [2])
    #expect(await runtime.agent.status().queuedInputs == 0)
    await runtime.shutdown()
}
@Test(.actionCatalog) func zeroRefreshGenerationRejectsBeforeResourceOrPresentationEffects() async throws {
    let inventory = PresentedInventoryFixture()
    let presentation = ResourcePresentationFixture()
    let runtime = try resourceRuntime(UnusedModelResourceCapability(), inventory: inventory, presentation: presentation)
    await #expect(throws: (any Error).self) { _ = try await runtime.presentInventory(generation: 0) }
    #expect(await inventory.reads == 0)
    #expect(await presentation.snapshots.isEmpty)
    #expect(await presentation.errors.isEmpty)
    await runtime.shutdown()
}

@Test(.actionCatalog) func resourcePresentationRejectsUnknownKeysAndOversizedMessagesBeforeEndpoints() async throws {
    let inventory = PresentedInventoryFixture()
    let presentation = ResourcePresentationFixture()
    for parameters in [["generation": "1", "unknown": "value"], ["generation": "0"]] {
        let invocation = FunctionInvocation(
            call: FunctionRequest(
                actionPath: ActionIdentifier(domain: "UI", module: "ResourcePresentation", function: "showResources"),
                parameters: parameters),
            context: ActionExecutionContext(
                source: "fixture", sessionID: UUID().uuidString, inputID: UUID().uuidString),
            executionID: UUID().uuidString,
            results: ActionReportStore())
        await #expect(throws: (any Error).self) {
            _ = try await UIActions.showResources(invocation: invocation, inventory: inventory, using: presentation)
        }
    }
    let failure = FunctionInvocation(
        call: FunctionRequest(
            actionPath: ActionIdentifier(domain: "UI", module: "ResourcePresentation", function: "showResourceFailure"),
            parameters: ["generation": "1", "message": String(repeating: "x", count: 2049)]),
        context: ActionExecutionContext(
            source: "fixture", sessionID: UUID().uuidString, inputID: UUID().uuidString),
        executionID: UUID().uuidString,
        results: ActionReportStore())
    await #expect(throws: ActionArguments.ValidationError.self) {
        _ = try await UIActions.showResourceFailure(invocation: failure, using: presentation)
    }
    #expect(await inventory.reads == 0)
    #expect(await presentation.snapshots.isEmpty)
    #expect(await presentation.errors.isEmpty)
}

@Test(.actionCatalog) func registeredResourcePresentationReturnsLargeInventoryWithoutPuttingItInCallArguments()
    async throws
{
    let inventory = PresentedInventoryFixture()
    await inventory.useLargeInventory()
    let presentation = ResourcePresentationFixture()
    let runtime = try resourceRuntime(UnusedModelResourceCapability(), inventory: inventory, presentation: presentation)
    let raw = try await runtime.presentInventory(generation: 1)
    #expect(raw.utf8.count > 48 * 1024)
    #expect(try ModelResourceInventory.decode(raw).items.count == 22)
    #expect(await inventory.reads == 1)
    #expect(await presentation.snapshots == [1])
    await runtime.shutdown()
}

@Test(.actionCatalog) func unavailableErrorPresentationRetainsPrimaryFailureAndAllowsNextRead() async throws {
    let inventory = PresentedInventoryFixture()
    let presentation = ResourcePresentationFixture()
    let runtime = try resourceRuntime(
        UnusedModelResourceCapability(), inventory: inventory, presentation: presentation,
        includeFailurePresentation: false)
    await inventory.failNext()
    do {
        _ = try await runtime.presentInventory(generation: 1)
        Issue.record("Unavailable presentation must fail this request")
    } catch ApplicationControlIntentFailure.execution(let message) {
        #expect(message.contains("queryFailure"))
        #expect(message.contains("Unknown tool"))
    }
    _ = try await runtime.presentInventory(generation: 2)
    #expect(await presentation.snapshots == [2])
    #expect(await runtime.agent.status().queuedInputs == 0)
    await runtime.shutdown()
}
@Test(.actionCatalog) func applicationControlAgentBoundsCombiningCharacterFailureBeforeConstructingPresentationCall()
    async throws
{
    let session = UUID().uuidString
    let agent = try ApplicationControlAgent(
        sessionID: session,
        context: try AgentContextRepository(
            agent: AgentID(rawValue: "applicationControl"), scope: UUID().uuidString,
            state: ApplicationControlContextState(), stateScope: StateContainer().makeScope())
    )
    try await agent.start()
    let request = try ModelResourceIntent.refreshPresentation(generation: 1).input(sessionID: session)
    try await agent.receive(request)
    var iterator = agent.outputs.makeAsyncIterator()
    let first = try #require(await iterator.next())
    guard case .toolCall(let call) = first.output else {
        Issue.record("Expected refresh call")
        return
    }
    let raw = "e" + String(repeating: "\u{0301}", count: 3000)
    let payload = InputPayload.toolResult(ToolResult(callID: call.id, value: raw, isError: true))
    try await agent.receive(
        AgentInput(
            id: UUID().uuidString,
            sessionID: session, payload: payload,
            metadata: InputMetadata(
                payload: payload, source: "runtime", origin: .runtime, rootID: UUID().uuidString)))
    let failure = try #require(await iterator.next())
    guard case .toolCall(let presentation) = failure.output else {
        Issue.record("Expected failure presentation")
        return
    }
    let message = try #require(presentation.arguments["message"])
    #expect(message.utf8.count <= 2048)
    #expect(raw.utf8.starts(with: message.utf8))
    #expect(presentation.toolPath == "UI.ResourcePresentation.showResourceFailure")
    await agent.stop()
}

private enum CommandFailureFixtureError: Error { case nativeCommand, operationPresentation }
private actor FailingResourceCommands: ModelResourceCapability {
    var calls: [String] = []
    var fails = true
    func recover() { fails = false }
    func configureSpeech(recognition: Bool, synthesis: Bool) throws { throw CancellationError() }
    private func run(_ operation: String) throws {
        calls.append(operation)
        if fails { throw CommandFailureFixtureError.nativeCommand }
    }
    func download(_ id: String, endpoint: String, allowsCellular: Bool) throws { try run("download") }
    func cancel(_ id: String) throws { try run("cancel") }
    func remove(_ id: String) throws { try run("remove") }
}
private actor OperationFailurePresentation: ResourcePresentationCapability {
    var errors: [String] = []
    var fails = false
    func fail() { fails = true }
    func presentResources(_ inventory: ModelResourceInventory, generation: UInt64, invocation: any FunctionInput)
        throws
    { throw CancellationError() }
    func presentResourceFailure(_ message: String, generation: UInt64, invocation: any FunctionInput) throws {
        throw CancellationError()
    }
    func presentResourcePreferenceFailure(
        _ reason: ResourcePreferenceFailureReason, message: String, invocation: any FunctionInput
    ) async throws {
        throw CancellationError()
    }
    func presentResourceOperationFailure(_ message: String, invocation: any FunctionInput) throws {
        errors.append(message)
        if fails { throw CommandFailureFixtureError.operationPresentation }
    }
}
@Test(.actionCatalog) func resourceCommandFailuresPresentThroughGatewayWithoutReplayingNativeCommands() async throws {
    let native = FailingResourceCommands()
    let presentation = OperationFailurePresentation()
    let runtime = try resourceRuntime(native, presentation: presentation)
    for intent in [
        ModelResourceIntent.download(id: "model", endpoint: "https://huggingface.co", allowsCellular: false),
        .cancel("model"), .remove("model"),
    ] {
        do {
            try await runtime.perform(intent)
            Issue.record("Failed command must remain failed after successful error presentation")
        } catch ApplicationControlIntentFailure.presented(let message) {
            #expect(message.contains("nativeCommand"))
        }
    }
    #expect(await native.calls == ["download", "cancel", "remove"])
    #expect(await presentation.errors.count == 3)
    #expect(await presentation.errors.allSatisfy { $0.contains("nativeCommand") })
    #expect(await runtime.agent.status().queuedInputs == 0)
    await native.recover()
    try await runtime.perform(.remove("model"))
    #expect(await native.calls == ["download", "cancel", "remove", "remove"])
    #expect(await presentation.errors.count == 3)
    await runtime.shutdown()
}
@Test(.actionCatalog) func resourceCommandPresentationFailureRetainsBothCausesAndDoesNotRecurse() async throws {
    let native = FailingResourceCommands()
    let presentation = OperationFailurePresentation()
    await presentation.fail()
    let runtime = try resourceRuntime(native, presentation: presentation)
    do {
        try await runtime.perform(.cancel("model"))
        Issue.record("Failed presentation must not claim accepted error state")
    } catch ApplicationControlIntentFailure.execution(let message) {
        #expect(message.contains("nativeCommand") && message.contains("operationPresentation"))
    }
    #expect(await native.calls == ["cancel"])
    #expect(await presentation.errors.count == 1)
    #expect(await runtime.agent.status().queuedInputs == 0)
    await native.recover()
    try await runtime.perform(.cancel("model"))
    #expect(await native.calls == ["cancel", "cancel"])
    #expect(await presentation.errors.count == 1)
    await runtime.shutdown()
}
@Test(.actionCatalog) func unavailableResourceCommandPresentationRetainsCauseAndReleasesAgentRequest() async throws {
    let native = FailingResourceCommands()
    let presentation = OperationFailurePresentation()
    let runtime = try resourceRuntime(native, presentation: presentation, includeOperationFailurePresentation: false)
    do {
        try await runtime.perform(.remove("model"))
        Issue.record("Unavailable presentation must fail explicitly")
    } catch ApplicationControlIntentFailure.execution(let message) {
        #expect(message.contains("nativeCommand") && message.contains("Unknown tool"))
    }
    #expect(await native.calls == ["remove"])
    #expect(await presentation.errors.isEmpty)
    #expect(await runtime.agent.status().queuedInputs == 0)
    await native.recover()
    try await runtime.perform(.remove("model"))
    await runtime.shutdown()
}
@Test(.actionCatalog) func operationFailureFunctionRejectsInvalidArgumentsAndReturnsEndpointAcknowledgment()
    async throws
{
    let presentation = OperationFailurePresentation()
    func invocation(_ parameters: [String: String]) -> FunctionInvocation {
        FunctionInvocation(
            call: FunctionRequest(
                actionPath: ActionIdentifier(
                    domain: "UI", module: "ResourcePresentation", function: "showResourceOperationFailure"),
                parameters: parameters),
            context: ActionExecutionContext(
                source: "fixture", sessionID: UUID().uuidString, inputID: UUID().uuidString),
            executionID: UUID().uuidString,
            results: ActionReportStore())
    }
    for arguments in [
        ["message": ""], ["message": "   "], ["message": String(repeating: "x", count: 2049)],
        ["message": "failure", "generation": "1"],
    ] {
        await #expect(throws: ActionArguments.ValidationError.self) {
            _ = try await UIActions.showResourceOperationFailure(invocation: invocation(arguments), using: presentation)
        }
    }
    #expect(await presentation.errors.isEmpty)
    let acknowledgment = try await UIActions.showResourceOperationFailure(
        invocation: invocation(["message": "native failure"]), using: presentation)
    #expect(acknowledgment == "presented")
    #expect(await presentation.errors == ["native failure"])
    #expect(
        ApplicationControlIntentFailure.execution("primary; presentation: secondary").localizedDescription
            == "primary; presentation: secondary")
}
