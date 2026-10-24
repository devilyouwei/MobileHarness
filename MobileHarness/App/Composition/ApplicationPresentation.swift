#if os(iOS)

    import Actions
    import Agents
    import Foundation
    import Observation
    import SwiftUI
    import UI

    /// Adapts domain-owned feature controls to UI-owned request ports; App performs no conversions.
    @available(iOS 27, *)
    @MainActor @Observable public final class ApplicationPresentation: ApplicationRootProviding {
        private let features: AgentContainer
        private let home: UIHomeContainer
        public var onHomeVisibilityChanged: (@MainActor (Bool) -> Void)?
        public var onPreparationRequested: (@MainActor () -> Void)?
        public var onInteractionActivityChanged: (@MainActor () -> Void)?
        public var preparesHomeModels: Bool { !features.isolatedPresentation }
        public var homePreparation: HomeModelPreparation { home.conversation.modelPreparation }
        public func retryHomePreparation() {
            guard homePreparation.showsRetry else { return }
            onPreparationRequested?()
        }
        public func interactionActivityChanged() { onInteractionActivityChanged?() }
        public func modelRequirementsChanged() { onPreparationRequested?() }
        public var bootstrap: (@MainActor () async throws -> Void)?
        public var onRetry: (() -> Void)?
        private var startupFailure: (any Error)?
        public var startupIssue: String? { startupFailure.map { String(describing: $0) } }
        public init(features: AgentContainer, home: UIHomeContainer) {
            self.features = features
            self.home = home
            features.onModelConfigurationChanged = { [weak self] in self?.onPreparationRequested?() }
        }
        @ObservationIgnored private var sessionPresentation: SessionPresentation?
        public var session: (any ApplicationSessionProviding)? {
            guard features.speechPerception.isReady else {
                sessionPresentation = nil
                return nil
            }
            let source = features.speechPerception
            if sessionPresentation?.source !== source {
                sessionPresentation = SessionPresentation(source: source)
            }
            return sessionPresentation
        }
        public var navigation: NavigationState { features.navigation }
        public var cameraState: CameraState { features.photographer.cameraState }
        public var cameraControls: any CameraControlling { features.photographer.cameraControls }
        public var bluetoothState: BluetoothSettingsState { features.applicationControl.devices }
        public var bluetoothControls: any BluetoothControlling { features.applicationControl.bluetoothControls }
        public var settings: SettingsState { features.applicationControl.settings }
        public var settingsControls: any SettingsControlling { features.applicationControl.settingsControls }
        public var modelResources: ModelResourcesState { features.applicationControl.modelResources }
        public var modelResourceControls: any ModelResourcesControlling {
            features.applicationControl.modelResourceControls
        }
        public var recordDestinations: [AgentRecordDestination] {
            let state = features.memory.historyState
            let controls = features.memory.history
            return [
                AgentRecordDestination(
                    id: "assistant", name: "Assistant 聊天记录",
                    summary: "对话、Task 摘要与完整请求记录"
                ) {
                    ConversationHistoryView(state: state, controls: controls)
                }
            ]
        }
        public func navigate(_ destination: AppDestination?) { features.navigate(destination) }
        public func cameraPreview() -> AnyView {
            AnyView(
                CameraFrameView(state: features.photographer.cameraState).id(
                    features.photographer.cameraState.videoGeneration))
        }
        public func navigationChanged() {
            onHomeVisibilityChanged?(features.navigation.path.isEmpty)
            features.updateCameraAvailability()
            features.reportEnvironment(
                .navigation, value: features.navigation.path.map(\.rawValue).joined(separator: "/"))
        }
        public func prepare(progress: @MainActor (String) -> Void) async throws {
            if let startupFailure { throw startupFailure }
            try await bootstrap?()
            try await features.start()
        }
        public func reportStartupFailure(_ error: any Error) { startupFailure = error }
        public func retry() { onRetry?() }
    }

    @available(iOS 27, *)
    @MainActor private final class SessionPresentation: ApplicationSessionProviding {
        let source: SpeechPerceptionContainer
        let conversation: ConversationState
        let actionActivity: ActionActivityState
        let audioDetectionState: AudioDetectionState
        let listeningRequests: UIRequests<ListeningInput, Void>
        let audioDetectionRequests: UIRequests<AudioDetectionInput, Void>
        private let diagnosticState: SpeechDiagnosticState
        private let diagnostic: SpeechDiagnosticWorkflow
        init?(source: SpeechPerceptionContainer) {
            guard let conversation = source.conversation, let activity = source.actionActivity,
                let detection = source.audioDetectionState, let listening = source.listeningRequests,
                let requests = source.detectionRequests, let diagnosticState = source.diagnosticState,
                let diagnostic = source.diagnostic
            else { return nil }
            self.source = source
            self.conversation = conversation
            actionActivity = activity
            audioDetectionState = detection
            listeningRequests = listening
            audioDetectionRequests = requests
            self.diagnosticState = diagnosticState
            self.diagnostic = diagnostic
        }
        public func speechValidationContent() -> AnyView {
            AnyView(
                MossValidationView(
                    state: diagnosticState, controls: diagnostic,
                    autorun: ProcessInfo.processInfo.arguments.contains("-moss-autorun")))
        }
        public func chatValidationContent() -> AnyView {
            #if DEBUG
                AnyView(
                    ChatValidationView(validate: { [source] in
                        guard let validate = await source.validateVoiceModels else {
                            throw AgentContainerError.unavailable
                        }
                        return try await validate()
                    }))
            #else
                AnyView(EmptyView())
            #endif
        }
    }
#endif
