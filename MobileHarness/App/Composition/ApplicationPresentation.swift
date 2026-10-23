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
        private let features: AgentApplication
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
        public init(features: AgentApplication, home: UIHomeContainer) {
            self.features = features
            self.home = home
            features.onModelConfigurationChanged = { [weak self] in self?.onPreparationRequested?() }
        }
        @ObservationIgnored private var sessionPresentation: SessionPresentation?
        public var session: (any ApplicationSessionProviding)? {
            guard let source = features.container else {
                sessionPresentation = nil
                return nil
            }
            if sessionPresentation?.source !== source {
                sessionPresentation = SessionPresentation(source: source)
            }
            return sessionPresentation
        }
        public var navigation: NavigationState { features.navigation }
        public var cameraState: CameraState { features.cameraState }
        public var cameraControls: any CameraControlling { features.cameraControls }
        public var bluetoothState: BluetoothSettingsState { features.devicesUI.state }
        public var bluetoothControls: any BluetoothControlling { features.bluetoothControls }
        public var settings: SettingsState { features.settings }
        public var settingsControls: any SettingsControlling { features.settingsControls }
        public var modelResources: ModelResourcesState { features.modelResources }
        public var modelResourceControls: any ModelResourcesControlling { features.modelResourceControls }
        public var recordDestinations: [AgentRecordDestination] {
            let state = features.historyState
            let controls = features.history
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
            AnyView(CameraFrameView(state: features.cameraState).id(features.cameraState.videoGeneration))
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
            try await features.prepare(progress: progress)
        }
        public func reportStartupFailure(_ error: any Error) { startupFailure = error }
        public func retry() { onRetry?() }
    }

    @available(iOS 27, *)
    @MainActor private final class SessionPresentation: ApplicationSessionProviding {
        let source: VoiceInteractionSession
        init(source: VoiceInteractionSession) { self.source = source }
        var conversation: ConversationState { source.conversation }
        var actionActivity: ActionActivityState { source.actionActivity }
        var audioDetectionState: AudioDetectionState { source.audioDetectionState }
        var listeningRequests: UIRequests<ListeningInput, Void> { source.listeningRequests }
        public var audioDetectionRequests: UIRequests<AudioDetectionInput, Void> { source.detectionRequests }
        public func speechValidationContent() -> AnyView {
            AnyView(
                MossValidationView(
                    state: source.diagnosticState, controls: source.diagnostic,
                    autorun: ProcessInfo.processInfo.arguments.contains("-moss-autorun")))
        }
        public func chatValidationContent() -> AnyView {
            #if DEBUG
                AnyView(ChatValidationView(validate: source.validateVoiceModels))
            #else
                AnyView(EmptyView())
            #endif
        }
    }
#endif
