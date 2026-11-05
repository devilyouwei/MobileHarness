#if os(iOS)

    import Actions
    import Agents
    import Foundation
    import Observation
    import SwiftUI
    import UI

    private enum ApplicationPresentationError: Error { case missingBootstrap }

    /// Adapts domain-owned feature controls to UI-owned request ports; App performs no conversions.
    @available(iOS 27, *)
    @MainActor @Observable public final class ApplicationPresentation: ApplicationRootProviding {
        private let features: AgentContainer
        private let home: UIHomeContainer
        public let web: WebPageContainer
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
        public init(
            features: AgentContainer, home: UIHomeContainer, web: WebPageContainer,
        ) {
            self.features = features
            self.home = home
            self.web = web
            features.onModelConfigurationChanged = { [weak self] in self?.onPreparationRequested?() }
        }
        @ObservationIgnored private var sessionPresentation: SessionPresentation?
        public var session: (any ApplicationSessionProviding)? {
            guard let source = features.speechPerception.presentation else {
                sessionPresentation = nil
                return nil
            }
            if sessionPresentation?.source !== source {
                sessionPresentation = SessionPresentation(source: source)
            }
            return sessionPresentation
        }
        public var windows: WindowState { features.windows }
        public var island: IslandState { features.island }
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
        public var album: UIAlbumContainer { features.album }
        public var recordDestinations: [AgentRecordDestination] {
            let state = features.memory.historyState
            let controls = features.memory.history
            var destinations = [
                AgentRecordDestination(
                    id: "assistant", name: "My Assistant",
                    summary: "对话、Task 摘要与完整请求记录"
                ) {
                    ConversationHistoryView(state: state, controls: controls)
                }
            ]
            if let artifacts = features.writer.artifacts {
                destinations.append(
                    AgentRecordDestination(id: "writer", name: "My Writer", summary: "委托任务、对话与作品文件") {
                        WriterRecordsView(controls: self.features.writer, artifacts: artifacts)
                    })
            }
            return destinations
        }
        public func navigate(_ destination: AppDestination?) { features.navigate(destination) }
        public func cameraPreview() -> AnyView {
            AnyView(
                CameraFrameView(state: features.photographer.cameraState, showsPose: false).id(
                    features.photographer.cameraState.videoGeneration))
        }
        public func navigationChanged() {
            onHomeVisibilityChanged?(features.navigation.path.isEmpty)
        }
        public func prepare(progress: @MainActor (String) -> Void) async throws {
            if let startupFailure { throw startupFailure }
            guard let bootstrap else { throw ApplicationPresentationError.missingBootstrap }
            try await bootstrap()
        }
        public func reportStartupFailure(_ error: any Error) { startupFailure = error }
        public func retry() { onRetry?() }
    }

    @available(iOS 27, *)
    @MainActor private final class SessionPresentation: ApplicationSessionProviding {
        let source: SpeechSessionPresentation
        let conversation: ConversationState
        let actionActivity: ActionActivityState
        let audioDetectionState: AudioDetectionState
        let listeningRequests: UIRequests<ListeningInput, Void>
        let audioDetectionRequests: UIRequests<AudioDetectionInput, Void>
        private let diagnosticState: SpeechDiagnosticState
        private let diagnostic: any SpeechDiagnosticControlling
        init(source: SpeechSessionPresentation) {
            self.source = source
            conversation = source.conversation
            actionActivity = source.actionActivity
            audioDetectionState = source.audioDetectionState
            listeningRequests = source.listeningRequests
            audioDetectionRequests = source.detectionRequests
            diagnosticState = source.diagnosticState
            diagnostic = source.diagnostic
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
                        try await source.validateVoiceModels()
                    }))
            #else
                AnyView(EmptyView())
            #endif
        }
    }
#endif
