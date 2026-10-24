#if os(iOS)
    import AgentCore
    import Foundation
    import Observation
    import UI
    import Actions

    @available(iOS 27, *)
    @MainActor @Observable
    public final class ApplicationControlContainer {
        @ObservationIgnored private var session: ApplicationControlExecutionSession?
        @ObservationIgnored private var closed = false
        private let settingsUI: UISettingsContainer
        private let resourcesUI: UIModelResourcesContainer
        private let devicesUI: UIDeviceSettingsContainer
        private let diagnosticsUI: UIDiagnosticsContainer
        private let navigationUI: UINavigationContainer
        private let bluetooth: BluetoothWorkflow
        private let failures: ContainerFailureChannel
        init(
            settings: UISettingsContainer, resources: UIModelResourcesContainer, diagnostics: UIDiagnosticsContainer,
            devices: UIDeviceSettingsContainer, navigation: UINavigationContainer, bluetooth: BluetoothWorkflow,
            failures: ContainerFailureChannel
        ) {
            diagnosticsUI = diagnostics
            settingsUI = settings
            resourcesUI = resources
            devicesUI = devices
            navigationUI = navigation
            self.bluetooth = bluetooth
            self.failures = failures
        }
        public var devices: BluetoothSettingsState { devicesUI.state }
        public var navigation: NavigationState { navigationUI.state }

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
        @ObservationIgnored lazy var modelResourcesWorkflow = makeModelResourcesWorkflow()
        private func makeModelResourcesWorkflow() -> ModelResourcesClient {
            ModelResourcesClient(
                read: { [resourcesUI] generation in
                    guard case .snapshot(let value) = try await resourcesUI.requests.submit(.refresh(generation)) else {
                        throw UIRequestError.stale
                    }
                    return value
                },
                restore: { [resourcesUI] in
                    guard case .source(let value) = try await resourcesUI.requests.submit(.restore) else {
                        throw UIRequestError.stale
                    }
                    return value
                },
                save: { [resourcesUI] draft in
                    guard case .source(let value) = try await resourcesUI.requests.submit(.save(draft)) else {
                        throw UIRequestError.stale
                    }
                    return value
                },
                download: { [resourcesUI] id, draft in _ = try await resourcesUI.requests.submit(.download(id, draft))
                },
                cancel: { [resourcesUI] id in _ = try await resourcesUI.requests.submitControl(.cancel(id)) },
                remove: { [resourcesUI] id in _ = try await resourcesUI.requests.submit(.remove(id)) })
        }
        public var modelResources: ModelResourcesState { resourcesUI.state }
        @ObservationIgnored public lazy var modelResourceControls = ModelResourceInteractionWorkflow(
            state: resourcesUI.presentation, operations: modelResourcesWorkflow)
        @ObservationIgnored lazy var settingsWorkflow = ProviderSettingsClient(
            provider: SettingsProviderOperations(
                initial: SettingsProviderAdapter.initial,
                restore: { [settingsUI] in
                    guard case .draft(let value) = try await settingsUI.requests.submit(.restore) else {
                        throw UIRequestError.stale
                    }
                    return value
                },
                discover: { [settingsUI] draft in
                    guard case .models(let values) = try await settingsUI.requests.submit(.discover(draft)) else {
                        throw UIRequestError.stale
                    }
                    return values
                }, save: { [settingsUI] draft in _ = try await settingsUI.requests.submit(.save(draft)) },
                errorMessage: { SettingsProviderAdapter.errorMessage($0) }), presentsResults: true)

        public var settings: SettingsState { settingsUI.state }
        @ObservationIgnored public lazy var settingsControls = SettingsFormController(
            state: settingsUI.presentation, operations: settingsWorkflow,
            defaultModel: SettingsProviderAdapter.initial.model)
        @ObservationIgnored lazy var deviceControl = NexArmDeviceAdapter(bluetooth: bluetooth)
        @ObservationIgnored public lazy var bluetoothControls = makeBluetoothControls()
        private func makeBluetoothControls() -> BluetoothInteractionWorkflow {
            BluetoothInteractionWorkflow(
                state: devicesUI.presentation,
                initialFence: deviceControl.fence, fenceStop: { [deviceControl] in deviceControl.stopFence() },
                pageVisibility: { [bluetooth] visible in
                    if visible { bluetooth.openPage() } else { bluetooth.closePage() }
                }, openSettings: { [bluetooth] in bluetooth.openSystemSettings() },
                perform: { [weak self] intent in
                    guard let self else { throw CancellationError() }
                    if ["stopScan", "disconnect", "forget"].contains(intent["operation"] ?? "") {
                        try await self.devicesUI.requests.submitControl(DeviceInput(intent))
                    } else {
                        try await self.devicesUI.requests.submit(DeviceInput(intent))
                    }
                })
        }

    }
#endif
