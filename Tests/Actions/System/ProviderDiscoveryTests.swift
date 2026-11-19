import Actions
import AgentCore
import ExecutionRuntime
import Foundation
import FunctionContracts
import Gateway
import PlatformKit
import StorageCore
import Testing

@testable import Agents

private actor DiscoveryRecorder {
    var queries = 0
    func query(_ configuration: ProviderDiscoveryConfiguration) -> [String] {
        queries += 1
        return ["chat-small", "chat-large"]
    }
}
private actor DiscoveryNativeFixture: ModelResourceCapability {
    var cancellations = 0
    func cancel(_ id: String) async throws { cancellations += 1 }
    func remove(_ id: String) async throws { throw CancellationError() }
    func download(_ id: String, endpoint: String, allowsCellular: Bool) async throws { throw CancellationError() }
    func configureSpeech(recognition: Bool, synthesis: Bool) async throws { throw CancellationError() }
}
@Test(.actionCatalog) func providerDiscoveryUsesOpaqueIntentAndReturningPipeline() async throws {
    let session = UUID().uuidString
    let recorder = DiscoveryRecorder()
    let requests = ProviderDiscoveryRequests { await recorder.query($0) }
    let native = DiscoveryNativeFixture()
    let runtime = try await resourceRuntime(native, providerDiscovery: requests, sessionID: session)
    let secret = "fixture-private-credential"
    let id = try await requests.stage(.init(url: "https://provider.example", key: secret), sessionID: session)
    let json = String(decoding: try JSONEncoder().encode(ProviderDiscoveryIntent(requestID: id)), as: UTF8.self)
    #expect(!json.contains(secret) && !json.contains("provider.example") && json.contains(id))
    _ = try await requests.discoverModels(requestID: id, sessionID: session)
    await #expect(throws: ProviderDiscoveryError.self) {
        _ = try await requests.discoverModels(requestID: id, sessionID: session)
    }
    let models = try await runtime.discover(
        .init(enabled: true, url: "https://provider.example", key: secret, model: "fixture"))
    #expect(models == ["chat-small", "chat-large"])
    #expect(await recorder.queries == 2)
    try await runtime.perform(.cancel("model"))
    #expect(await native.cancellations == 1)
    #expect(await runtime.agent.status().queuedInputs == 0)
    await runtime.shutdown()
}
private final class DiscoveryClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = ContinuousClock.now
    func now() -> ContinuousClock.Instant { lock.withLock { instant } }
    func advance() { lock.withLock { instant = instant.advanced(by: .seconds(11)) } }
}
@Test(.actionCatalog) func providerDiscoveryStagingRejectsOverflowWrongSessionAndExpiry() async throws {
    let clock = DiscoveryClock()
    let recorder = DiscoveryRecorder()
    let requests = ProviderDiscoveryRequests(clock: { clock.now() }, discover: { await recorder.query($0) })
    let session = UUID().uuidString
    var ids: [String] = []
    for _ in 0..<32 {
        ids.append(try await requests.stage(.init(url: "https://provider.example", key: "fixture"), sessionID: session))
    }
    await #expect(throws: ProviderDiscoveryError.self) {
        _ = try await requests.stage(.init(url: "https://provider.example", key: "fixture"), sessionID: session)
    }
    await #expect(throws: ProviderDiscoveryError.self) {
        _ = try await requests.discoverModels(requestID: ids[0], sessionID: UUID().uuidString)
    }
    _ = try await requests.discoverModels(requestID: ids[0], sessionID: session)
    #expect(await recorder.queries == 1)
    await requests.discard(ids[1], sessionID: UUID().uuidString)
    clock.advance()
    await #expect(throws: ProviderDiscoveryError.self) {
        _ = try await requests.discoverModels(requestID: ids[1], sessionID: session)
    }
    _ = try await requests.stage(.init(url: "https://provider.example", key: "fixture"), sessionID: session)
    #expect(await recorder.queries == 1)
}
private struct SecretDiscoveryFailure: LocalizedError {
    var errorDescription: String? { "fixture-private-credential" }
}
@Test(.actionCatalog) func providerDiscoveryFailureDoesNotLeakCredentialsOrRetry() async throws {
    let requests = ProviderDiscoveryRequests { _ in throw SecretDiscoveryFailure() }
    let runtime = try await resourceRuntime(UnusedModelResourceCapability(), providerDiscovery: requests)
    do {
        _ = try await runtime.discover(
            .init(enabled: true, url: "https://provider.example", key: "fixture-private-credential", model: "fixture"))
        Issue.record("Query should fail")
    } catch let error as ProviderIntentFailure {
        #expect(error.failureCode == "provider.unavailable")
        #expect(!error.message.contains("fixture-private-credential"))
    }
    await runtime.shutdown()
}
private enum InvalidProviderModels: CaseIterable, Sendable {
    case duplicates, blank, oversizedID, excessiveCount, excessiveBytes
    var models: [String] {
        switch self {
        case .duplicates: ["duplicate", "duplicate"]
        case .blank: [" "]
        case .oversizedID: [String(repeating: "界", count: 171)]
        case .excessiveCount: (0..<2049).map { "model-\($0)" }
        case .excessiveBytes: (0..<200).map { String($0) + String(repeating: "x", count: 400) }
        }
    }
}
@Test(.actionCatalog, arguments: InvalidProviderModels.allCases)
private func providerDiscoveryRejectsMalformedModelLists(value: InvalidProviderModels) async throws {
    let models = value.models
    let requests = ProviderDiscoveryRequests { _ in models }
    let runtime = try await resourceRuntime(UnusedModelResourceCapability(), providerDiscovery: requests)
    do {
        _ = try await runtime.discover(
            .init(enabled: true, url: "https://provider.example", key: "fixture", model: "fixture"))
        Issue.record("Malformed list must fail wholly")
    } catch let error as ProviderIntentFailure { #expect(error.failureCode == "provider.models") }
    await runtime.shutdown()
}
@Test(.actionCatalog) func providerDiscoveryFunctionRejectsSecretsInArgumentsBeforeQuery() async throws {
    let recorder = DiscoveryRecorder()
    let requests = ProviderDiscoveryRequests { await recorder.query($0) }
    let invocation = FunctionInvocation(
        call: FunctionRequest(
            actionPath: .init(domain: "System", module: "Provider", function: "discoverModels"),
            parameters: ["requestID": UUID().uuidString, "key": "fixture-secret"]),
        context: .init(
            source: "fixture", sessionID: UUID().uuidString, inputID: UUID().uuidString),
        executionID: UUID().uuidString, results: ActionReportStore())
    await #expect(throws: ActionArguments.ValidationError.self) {
        _ = try await SystemActions.discoverModels(invocation: invocation, using: requests)
    }
    #expect(await recorder.queries == 0)
}

@Test(.actionCatalog) func providerDiscoveryAgentEmitsOnlyOpaqueRequestArgument() async throws {
    let session = UUID().uuidString
    let agent = try ApplicationControlAgent(
        sessionID: session,
        context: try AgentContextRepository(
            agent: AgentID(rawValue: "applicationControl"), scope: UUID().uuidString,
            state: ApplicationControlContextState())
    )
    try await agent.start()
    let intent = ProviderDiscoveryIntent(requestID: UUID().uuidString)
    try await agent.receive(intent.input(sessionID: session))
    var iterator = agent.outputs.makeAsyncIterator()
    guard case .toolCall(let call) = await iterator.next()?.output else {
        Issue.record("Missing discovery call")
        return
    }
    #expect(call.toolPath == "System.Provider.discoverModels")
    #expect(call.arguments == ["requestID": intent.requestID])
    await agent.stop()
}
private actor HeldDiscovery {
    nonisolated let cancellationObserved = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    nonisolated let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    private var waiter: CheckedContinuation<Void, Never>?
    var cancelled = false
    func query(_ configuration: ProviderDiscoveryConfiguration) async -> [String] {
        await withTaskCancellationHandler {
            await withCheckedContinuation {
                waiter = $0
                entered.continuation.yield(())
            }
        } onCancel: {
            cancellationObserved.continuation.yield(())
        }
        cancelled = Task.isCancelled
        return ["chat-small"]
    }
    func release() {
        waiter?.resume()
        waiter = nil
    }
}
@Test(.actionCatalog, .timeLimit(.minutes(1))) func providerDiscoveryPageCancellationCancelsAndJoinsActualQuery()
    async throws
{
    let native = HeldDiscovery()
    let requests = ProviderDiscoveryRequests { await native.query($0) }
    let runtime = try await resourceRuntime(UnusedModelResourceCapability(), providerDiscovery: requests)
    var iterator = native.entered.stream.makeAsyncIterator()
    let caller = Task {
        try await runtime.discover(
            .init(enabled: true, url: "https://provider.example", key: "fixture", model: "fixture"))
    }
    _ = await iterator.next()
    caller.cancel()
    // UI request cancellation crosses an asynchronous MainActor boundary before reaching the native query.
    var cancellation = native.cancellationObserved.stream.makeAsyncIterator()
    _ = await cancellation.next()
    await native.release()
    await #expect(throws: CancellationError.self) { _ = try await caller.value }
    await runtime.shutdown()
    #expect(await native.cancelled)
    #expect(await runtime.agent.status().queuedInputs == 0)
}

@Test(.actionCatalog) func providerDiscoveryPreservesSDKCompatibleLargeLists() async throws {
    let models = (0..<256).map { "model-\($0)" }
    let requests = ProviderDiscoveryRequests { _ in models }
    let runtime = try await resourceRuntime(UnusedModelResourceCapability(), providerDiscovery: requests)
    let actual = try await runtime.discover(
        .init(enabled: true, url: "https://provider.example", key: "fixture", model: "fixture"))
    #expect(actual == models)
    await runtime.shutdown()
}
