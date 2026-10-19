#if os(iOS)
    import ActionBindings
    import Foundation
    import Observation
    import SwiftUI
    import UI

    /// Adapts domain-owned feature controls to UI-owned request ports; App performs no conversions.
    @available(iOS 27, *)
    @MainActor @Observable public final class AgentApplicationUI: ApplicationRootProviding {
        private let features: ApplicationFeatures
        private let home: UIHomeContainer
        public var onHomeVisibilityChanged: (@MainActor (Bool) -> Void)?
        public var onPreparationRequested: (@MainActor () -> Void)?
        public var onPreparationCancelled: (@MainActor () -> Void)?
        public var onInteractionActivityChanged: (@MainActor () -> Void)?
        public var preparesHomeModels: Bool { !features.isolatedPresentation }
        public var homePreparation: HomeModelPreparation { home.conversation.modelPreparation }
        public func retryHomePreparation() { onPreparationRequested?() }
        public func cancelHomePreparation() { onPreparationCancelled?() }
        public func interactionActivityChanged() { onInteractionActivityChanged?() }
        public func modelRequirementsChanged() { onPreparationRequested?() }
        public var bootstrap: (@MainActor () async throws -> Void)?
        public var onRetry: (() -> Void)?
        private var startupFailure: (any Error)?
        public var startupIssue: String? { startupFailure.map { String(describing: $0) } }
        public init(features: ApplicationFeatures, home: UIHomeContainer) {
            self.features = features
            self.home = home
            features.onModelConfigurationChanged = { [weak self] in self?.onPreparationRequested?() }
        }
        public var session: (any ApplicationSessionProviding)? { features.container }
        public var navigation: NavigationState { features.navigation }
        public var cameraState: CameraState { features.cameraState }
        public var cameraControls: any CameraControlling { features.cameraControls }
        public var bluetoothState: BluetoothSettingsState { features.devicesUI.state }
        public var bluetoothControls: any BluetoothControlling { features.bluetoothControls }
        public var settings: SettingsState { features.settings }
        public var settingsControls: any SettingsControlling { features.settingsControls }
        public var modelResources: ModelResourcesState { features.modelResources }
        public var modelResourceControls: any ModelResourcesControlling { features.modelResourceControls }
        public var recordDestinations: [AgentRecordDestination] { features.recordDestinations }
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
    extension InteractionServices: ApplicationSessionProviding {
        var audioDetectionState: AudioDetectionState { audioDetection.state }
        var audioDetectionControls: any AudioDetectionControlling { audioDetection }
        func toggleVoice() { if conversation.allowsHomeInteraction { lifecycle.toggleVoice() } }
        func voicePressChanged(_ pressing: Bool) {
            if !pressing || conversation.allowsHomeInteraction { lifecycle.voicePressChanged(pressing) }
        }
        func speechValidationContent() -> AnyView { AnyView(makeMossValidationView()) }
        func chatValidationContent() -> AnyView {
            #if DEBUG
                AnyView(makeChatValidationView())
            #else
                AnyView(EmptyView())
            #endif
        }
    }
#endif
