import AgentCore
import Foundation
import FunctionContracts
import Gateway
import ModelKit
import PlatformKit
import StorageCore
import UI

/// Root-session application operations; shared transaction state with no native or callable implementation imports.
public actor ApplicationControlAgent: Agent {

    // MARK: - Interface

    public nonisolated let descriptor: AgentDescriptor
    public nonisolated let outputs: AsyncStream<OutputEnvelope>

    // MARK: - State and dependencies

    let connectionFacts: (@MainActor @Sendable () throws -> PlatformKit.StateSignalListener<NexArmConnectionFacts>)?
    let resourceChanges: (@MainActor @Sendable () async throws -> ModelKit.StateSignalListener<UInt64>)?
    let observationFailure: @Sendable (any Error) -> Void
    var resourceObservation: ResourceObservationSession?
    let uiDiagnostics: UIDiagnosticsContainer?
    var detection: Task<Void, any Error>?
    let decodeResources: @Sendable (String) throws -> ModelResourceViewSnapshot
    let uiSettings: UISettingsContainer?
    let uiResources: UIModelResourcesContainer?
    let uiWindows: WindowState?
    let uiDevices: UIDeviceSettingsContainer?
    let uiProviderSettings: (any ProviderSettingsStaging)?
    let uiProviderDiscovery: (any ProviderDiscoveryStaging)?
    let uiProviderPresentation: (any ProviderPresentationRegistering)?
    var uiInputs = AgentUIInputs()
    var uiExecution = AgentUIExecution()
    let contextRepository: AgentContextRepository<ApplicationControlContextState>
    let preprocessor = ApplicationControlSignalPreprocessor()
    let contextBuilder = ApplicationControlContextBuilder()

    let continuation: AsyncStream<OutputEnvelope>.Continuation
    let sessionID: String
    var lifecycle = AgentLifecycle.registered
    var lifecycleIsActive: Bool { lifecycle == .running }
    var pending: [String: AgentInput] = [:]
    var inputs: Set<String> = []
    var configurationCall: String?
    var providerSettingsRequest: String?
    var preferenceRequest: String?
    var preferenceCalls: Set<String> = []
    struct PresentationStep {
        let generation: UInt64
        let failure: Bool
        var failureTerminatesRequest = true
    }
    var presentationCalls: [String: PresentationStep] = [:]
    var providerPresentationCalls: [String: Bool] = [:]
    var hostFailureCalls: Set<String> = []
    var terminalFailureCalls: Set<String> = []
    var observationSequence: UInt64 = 0
    var bluetoothState: ApplicationControlBluetoothState?
    var bluetoothPresented: ApplicationControlBluetoothState?
    var bluetoothRevision: UInt64 = 0
    var environment: [AppEnvironmentFact.Category: AppEnvironmentFact] = [:]
    var sequence: UInt64 = 0
    var processed = 0
    var diagnosticCounts: [String: UInt64] = [:]
    var diagnosticOrder: [String] = []
    var windowCalls: Set<String> = []
    var statePresentationCalls: Set<String> = []
    let publishIssue: @MainActor @Sendable (ExecutionIssue, Bool) -> Void
    let diagnosticContracts: Set<String> = [ContainerFailureEvent.contract, RuntimeFailureEvent.contract]

    private var messaging: AgentMessaging?
    let taskCoordinator: AgentFixedTaskCoordinator<ApplicationControlContextState>
    var fixedTaskInputs: [String: AgentInput] = [:]
    let admission = AgentAdmissionGate(capacity: 32)
    var stagedOutputs: [OutputEnvelope]?

    // MARK: - Registration

    public init(
        sessionID: String, configuration: AgentConfiguration? = nil,
        uiSettings: UISettingsContainer? = nil, uiResources: UIModelResourcesContainer? = nil,
        uiDevices: UIDeviceSettingsContainer? = nil, uiDiagnostics: UIDiagnosticsContainer? = nil,
        uiWindows: WindowState? = nil,
        connectionFacts: (@MainActor @Sendable () throws -> PlatformKit.StateSignalListener<NexArmConnectionFacts>)? =
            nil,
        resourceChanges: (@MainActor @Sendable () async throws -> ModelKit.StateSignalListener<UInt64>)? = nil,
        observationFailure: @escaping @Sendable (any Error) -> Void = { _ in },
        uiProviderSettings: (any ProviderSettingsStaging)? = nil,
        uiProviderDiscovery: (any ProviderDiscoveryStaging)? = nil,
        uiProviderPresentation: (any ProviderPresentationRegistering)? = nil,
        decodeResources: @escaping @Sendable (String) throws -> ModelResourceViewSnapshot = { _ in
            throw CommunicationError.invalidPayload
        },
        publishIssue: @escaping @MainActor @Sendable (ExecutionIssue, Bool) -> Void = { _, _ in },
        context: AgentContextRepository<ApplicationControlContextState>
    ) throws {
        self.publishIssue = publishIssue
        self.decodeResources = decodeResources
        self.connectionFacts = connectionFacts
        self.resourceChanges = resourceChanges
        self.observationFailure = observationFailure
        self.uiDiagnostics = uiDiagnostics
        self.uiSettings = uiSettings
        self.uiResources = uiResources
        self.uiDevices = uiDevices
        self.uiWindows = uiWindows
        self.uiProviderSettings = uiProviderSettings
        self.uiProviderDiscovery = uiProviderDiscovery
        self.uiProviderPresentation = uiProviderPresentation
        self.contextRepository = context
        guard contextRepository.agentID == .applicationControl else { throw AgentConfigurationError.identityMismatch }
        let configuration = try configuration ?? AgentConfigurations.load(named: "ApplicationControl")
        guard configuration.agentID == .applicationControl else { throw AgentConfigurationError.identityMismatch }
        descriptor = AgentDescriptor(
            category: configuration.category, publicationChannels: configuration.communication.publicationChannels,
            id: .applicationControl, name: "ApplicationControl",
            inputs: configuration.communication.inputKinds,
            outputs: [.communication, .toolCall, .control],
            capabilities: try CapabilityRegistry(
                internalTools: [
                    InternalTool(path: "Speech.Detection.run"),
                    ApplicationControlFunctions.bluetoothHome,
                    ApplicationControlFunctions.bluetoothSettings, ApplicationControlFunctions.loadingExpression,
                    ApplicationControlFunctions.download, ApplicationControlFunctions.cancellation,
                    ApplicationControlFunctions.removal, ApplicationControlFunctions.speechBinding,
                    ApplicationControlFunctions.restoration, ApplicationControlFunctions.saving,
                    ApplicationControlFunctions.inventory,
                    ApplicationControlFunctions.presentation, ApplicationControlFunctions.failurePresentation,
                    ApplicationControlFunctions.operationFailurePresentation,
                    ApplicationControlFunctions.preferenceFailurePresentation,
                    ApplicationControlFunctions.providerDiscovery, ApplicationControlFunctions.providerRestoration,
                    ApplicationControlFunctions.providerSaving, ApplicationControlFunctions.providerPresentation,
                    ApplicationControlFunctions.deviceControl, ApplicationControlFunctions.navigation,
                ] + ApplicationControlFunctions.windows + AgentIslandPublication.permissions))
        taskCoordinator = AgentFixedTaskCoordinator(context: self.contextRepository)
        self.sessionID = sessionID
        let pair = AsyncStream<OutputEnvelope>.makeStream(
            bufferingPolicy: .bufferingOldest(ApplicationControlSignalPreprocessor.outputCapacity))
        outputs = pair.stream
        continuation = pair.continuation
    }

    public func observeEnvironment(_ fact: AppEnvironmentFact) async throws {
        try fact.validate()
        try await receive(fact.input(sessionID: sessionID))
    }
    public func observeResource(_ fact: ModelResourceObservation, sequence: UInt64) async throws {
        try fact.validate()
        guard sequence > 0 else { throw CommunicationError.invalidPayload }
        try await receive(fact.input(sessionID: sessionID, sequence: sequence))
    }
    let island = AgentIslandPublication()
    private var islandExpiry: Task<Void, Never>?
    private var islandConnectionRevision: UInt64 = 0
    public func finishPresentation() async { await island.stop() }
    public var presentationFailure: String? { get async { await island.lastFailure } }
    private var islandConnectionState: ApplicationControlBluetoothState?
    func updateConnectionIsland() async {
        guard let state = bluetoothPresented, state != islandConnectionState else { return }
        islandConnectionState = state
        await presentConnectionIsland(state)
    }
    private func presentConnectionIsland(_ state: ApplicationControlBluetoothState) async {
        islandConnectionRevision += 1
        let revision = islandConnectionRevision
        let previous = islandExpiry
        previous?.cancel()
        await previous?.value
        guard revision == islandConnectionRevision else { return }
        await island.submit(Self.connectionContent(state, temporary: true))
        islandExpiry = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            await self?.expireConnectionIsland(state, revision: revision)
        }
    }
    private func expireConnectionIsland(_ state: ApplicationControlBluetoothState, revision: UInt64) async {
        guard !Task.isCancelled, revision == islandConnectionRevision else { return }
        await island.submit(Self.connectionContent(state, temporary: false))
    }
    static func connectionContent(_ state: ApplicationControlBluetoothState, temporary: Bool) -> IslandContent? {
        if state == .disconnected && !temporary { return nil }
        let title = state == .connected ? "Connected" : state == .connecting ? "Connecting" : "Disconnected"
        return .init(
            title: "Bluetooth", subtitle: title,
            primary: .symbol(
                name: state == .connecting ? "antenna.radiowaves.left.and.right" : "dot.radiowaves.left.and.right"),
            tone: state == .disconnected ? .warning : .blue, priority: temporary ? .high : .background,
            secondary: state == .connecting ? .loading : nil, localizedLabels: true)
    }
    public func observeConnection(_ facts: NexArmConnectionFacts) async throws {
        guard lifecycle == .running || lifecycle == .paused else { throw HarnessError.notRunning }
        let phase: ApplicationControlBluetoothState
        if facts.availability != .available {
            phase = .disconnected
        } else if facts.phase == .connected {
            phase = .connected
        } else if facts.phase == .connecting || [.cleaning, .waiting, .connecting].contains(facts.recovery) {
            phase = .connecting
        } else {
            phase = .disconnected
        }
        bluetoothState = phase
        let context = ProcessingContext(sessionID: sessionID, source: "runtime")
        try presentBluetooth(phase, input: context.input(.event("connection.changed")))
        await updateConnectionIsland()
    }
    public func observeFailure(_ event: ContainerFailureEvent) async throws {
        try event.validate()
        let message = AgentMessage(
            contract: ContainerFailureEvent.contract, content: event, maximumBytes: 8192,
            validate: { try $0.validate() })
        try await receive(
            ProcessingContext(requestID: event.id, sessionID: sessionID, source: "runtime").input(.observation(message))
        )
    }
    public func observeFailure(_ event: RuntimeFailureEvent) async throws {
        try event.validate()
        let message = AgentMessage(
            contract: RuntimeFailureEvent.contract, content: event, maximumBytes: 16384,
            validate: { try $0.validate() })
        try await receive(
            ProcessingContext(requestID: event.id, sessionID: sessionID, source: "runtime").input(.observation(message))
        )
    }
    // MARK: - Lifecycle

    public func receiveRequest(_ request: AgentProtocolRequest) async throws -> AgentRequestReply {
        let input = request.input
        guard case .observation(let message) = input.payload, message.operation == request.operation else {
            throw CommunicationError.invalidPayload
        }
        if request.operation == .status {
            guard let query = message.content(as: AgentTaskQuery.self) else { throw CommunicationError.invalidPayload }
            return try await taskCoordinator.requestStatus(query, input: input)
        }
        if request.operation == .cancel, let query = message.content(as: AgentTaskQuery.self) {
            _ = try await taskCoordinator.requestStatus(query, input: input)
            try await receive(AgentFixedTaskInput.cancellation(query, input: input))
            return AgentRequestReply(requestID: input.id, reference: query.scope.id)
        }
        guard let signal = message.content(as: AgentTaskSignal.self),
            (request.operation == .submit && signal.kind == .request)
                || ([.update, .answer].contains(request.operation) && signal.kind == .input)
                || (request.operation == .cancel && signal.kind == .cancel)
        else { throw CommunicationError.invalidPayload }
        try await receive(input)
        return AgentRequestReply(requestID: input.id, reference: signal.scope.id)
    }
    public func bindMessaging(_ messaging: AgentMessaging) async {
        self.messaging = messaging
        await taskCoordinator.bindMessaging(messaging)
    }
    /// Publishes authorized semantic control; return establishes publication admission, not interruption completion.
    public func publishInterruption(sessionID: String, target: AssistantInterrupt.Target = .current) async throws {
        guard lifecycle == .running, let messaging else { throw CommunicationError.unavailableTarget }
        let signal = AssistantInterrupt(target: target)
        let parent = AgentInput(id: signal.id.uuidString, sessionID: sessionID, payload: .event("interrupt"))
        try await messaging.publish(signal.message(), parent: parent)
    }
    public func start() async throws {
        guard lifecycle == .registered else { throw HarnessError.invalidTransition }
        _ = try await contextRepository.snapshot()
        try await taskCoordinator.start()
        lifecycle = .running

        try await startUIInputs()
    }
    public func pause() async throws {
        await stopUIInputs()
        guard lifecycle == .running else { throw HarnessError.invalidTransition }
        await taskCoordinator.pause()
        lifecycle = .paused
    }
    public func resume() async throws {
        guard lifecycle == .paused else { throw HarnessError.invalidTransition }
        await stopUIInputs()
        await taskCoordinator.resume()
        lifecycle = .running
        try await startUIInputs()
    }
    public func stop() async {
        await stopUIInputs()
        islandExpiry?.cancel()
        await islandExpiry?.value
        islandExpiry = nil
        await island.stop()
        uiExecution.consumer = nil
        admission.close()
        lifecycle = .stopped
        statePresentationCalls.removeAll()
        windowCalls.removeAll()
        diagnosticCounts.removeAll()
        diagnosticOrder.removeAll()
        pending.removeAll()
        environment.removeAll()
        bluetoothState = nil
        bluetoothPresented = nil
        bluetoothRevision = 0
        inputs.removeAll()
        configurationCall = nil
        providerSettingsRequest = nil
        preferenceRequest = nil
        preferenceCalls.removeAll()
        presentationCalls.removeAll()
        hostFailureCalls.removeAll()
        providerPresentationCalls.removeAll()
        terminalFailureCalls.removeAll()
        fixedTaskInputs.removeAll()
        await taskCoordinator.stop()
        continuation.finish()
    }

    // MARK: - Context

    public func completeFixedTask(inputID: String, value: String?, failure: String? = nil) async throws {
        guard let original = fixedTaskInputs.removeValue(forKey: inputID), let scope = original.taskScope else {
            return
        }
        try await taskCoordinator.reportFixedTask(
            scope, input: original,
            result: ToolResult(callID: inputID, value: failure ?? value ?? "Completed", isError: failure != nil))
    }

    // MARK: - Observability

    public func applicationState() throws -> ContainerContextValue<ApplicationStateSnapshot> {
        guard lifecycle == .running || lifecycle == .paused else { throw HarnessError.notRunning }
        return ContainerContextValue(
            ApplicationStateSnapshot(
                scene: environment[.scene]?.value ?? "unknown",
                modelPreparation: environment[.modelPreparation]?.value ?? "unknown",
                sceneSequence: environment[.scene]?.sequence,
                modelPreparationSequence: environment[.modelPreparation]?.sequence))
    }

    public func status() -> AgentStatus {
        AgentStatus(
            lifecycle: lifecycle, queuedInputs: pending.count + statePresentationCalls.count, processedInputs: processed
        )
    }

    /// Passive State reflection, independent of persistence initialization.
    public func residentContext() async -> AgentContext<ApplicationControlContextState>? {
        await contextRepository.residentSnapshot()
    }

    public func contextSnapshot() async throws -> AgentContext<ApplicationControlContextState> {
        try await contextRepository.snapshot()
    }
}
