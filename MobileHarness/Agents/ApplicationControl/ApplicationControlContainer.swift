#if os(iOS)
    import AgentCore
    import Foundation
    import Observation
    import UI
    import FunctionContracts

    @available(iOS 27, *)
    @MainActor @Observable
    public final class ApplicationControlContainer {
        public func stateSnapshot() async throws -> AgentStateSnapshot {
            try Task.checkCancellation()
            let presentationFailure = await session?.agent.presentationFailure
            let status = await session?.agent.status()
            let context = await session?.agent.residentContext()
            let environment = try await contextSnapshotIfAvailable()
            return AgentStateSnapshot(
                path: "agents.applicationcontrol",
                business: [
                    "modelPreparation": environment.map { .text($0.modelPreparation) } ?? .unknown,
                    "taskPhases": context?.state.taskViews.map { .texts($0.values.map { $0.stage.rawValue }.sorted()) }
                        ?? .unknown,
                ],
                runtime: [
                    "presentationFailure": presentationFailure.map { .text($0) } ?? .unknown,
                    "scene": environment.map { .text($0.scene) } ?? .unknown,
                    "sceneSequence": environment?.sceneSequence.map { .unsigned($0) } ?? .unknown,
                    "modelPreparationSequence": environment?.modelPreparationSequence.map { .unsigned($0) }
                        ?? .unknown, "rolePhase": status.map { .text($0.lifecycle.rawValue) } ?? .unknown,
                    "queuedInputs": status.map { .count($0.queuedInputs) } ?? .unknown,
                    "processedInputs": status.map { .count($0.processedInputs) } ?? .unknown,
                    "taskViews": context?.state.taskViews.map { .count($0.count) } ?? .unknown, "closed": .flag(closed),
                    "installed": .flag(session != nil),
                ])
        }

        @ObservationIgnored private var session: ApplicationControlExecutionSession?
        @ObservationIgnored private var closed = false
        private let settingsUI: UISettingsContainer
        private let resourcesUI: UIModelResourcesContainer
        private let devicesUI: UIDeviceSettingsContainer
        private let diagnosticsUI: UIDiagnosticsContainer
        private let navigationUI: UINavigationContainer
        private let facades: AgentUIFacades
        private let failures: ContainerFailureChannel
        init(
            settings: UISettingsContainer, resources: UIModelResourcesContainer, diagnostics: UIDiagnosticsContainer,
            devices: UIDeviceSettingsContainer, navigation: UINavigationContainer, facades: AgentUIFacades,
            failures: ContainerFailureChannel
        ) {
            diagnosticsUI = diagnostics
            settingsUI = settings
            resourcesUI = resources
            devicesUI = devices
            navigationUI = navigation
            self.facades = facades
            self.failures = failures
        }
        public var devices: BluetoothSettingsState { devicesUI.state }
        public var navigation: NavigationState { navigationUI.state }

        private func contextSnapshotIfAvailable() async throws -> ApplicationStateSnapshot? {
            guard !closed, let session else { return nil }
            let status = await session.agent.status()
            guard status.lifecycle == .running || status.lifecycle == .paused else { return nil }
            let value = try await session.agent.applicationState()
            guard !closed else { return nil }
            return value.value
        }

        func setInputAvailable(_ value: Bool) {
            settingsUI.requests.setAvailable(value)
            resourcesUI.requests.setAvailable(value)
            devicesUI.requests.setAvailable(value)
            diagnosticsUI.detectionRequests.setAvailable(value)
        }
        func install(_ session: ApplicationControlExecutionSession) throws {
            guard !closed else { throw AgentContainerError.stopped }
            guard self.session == nil else { throw AgentContainerError.busy }
            self.session = session
        }
        func start() async throws {
            guard !closed else { throw AgentContainerError.stopped }
            guard let session else { throw AgentContainerError.unavailable }
            try await session.prepareForInteraction()
        }
        func setForeground(_ value: Bool) async throws {
            guard !closed else { throw AgentContainerError.stopped }
            guard let session else { return }
            if !value { await session.agent.stopDetection() }
            await session.agent.setResourceObservationForeground(value)
            let state = await session.agent.status().lifecycle
            if value, state == .paused { try await session.agent.resume() }
            if !value, state == .running { try await session.agent.pause() }
        }
        func stop() async throws {
            closed = true
            await environmentInputs.shutdown()
            await session?.shutdown()
            if let failure = await session?.cleanupFailure { throw failure }
        }
        @ObservationIgnored private lazy var environmentInputs: ApplicationEnvironmentInputs = makeEnvironmentInputs()
        private func makeEnvironmentInputs() -> ApplicationEnvironmentInputs {
            ApplicationEnvironmentInputs(
                deliver: { [weak self] fact in
                    guard let self, !self.closed, let session = self.session else { throw CancellationError() }
                    try await session.agent.observeEnvironment(fact)
                },
                failed: { [failures] error in
                    failures.report(
                        module: "agents", component: "applicationControl.environment", operation: "observe",
                        error: error)
                })
        }
        func reportEnvironment(_ category: AppEnvironmentFact.Category, value: String) {
            guard !closed else { return }
            environmentInputs.report(category, value: value)
        }
        var modelResourcesWorkflow: any ModelResourcesOperating { facades.resourceOperations }
        var settingsWorkflow: any SettingsOperating { facades.settingsOperations }
        var modelName: String { facades.modelName() }
        public var modelResources: ModelResourcesState { resourcesUI.state }
        public var modelResourceControls: any ModelResourcesControlling { facades.resources }
        public var settings: SettingsState { settingsUI.state }
        public var settingsControls: any SettingsControlling { facades.settings }
        public var bluetoothControls: any BluetoothControlling { facades.bluetooth }
        func acceptResourceSnapshot() { facades.resourcesPresented() }
    }
#endif
