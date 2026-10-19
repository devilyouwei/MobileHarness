#if os(iOS)
    import Foundation
    import SwiftUI

    @MainActor
    public protocol ApplicationSessionProviding: AnyObject {
        var conversation: ConversationState { get }
        var actionActivity: ActionActivityState { get }
        var audioDetectionState: AudioDetectionState { get }
        var audioDetectionControls: any AudioDetectionControlling { get }
        func toggleVoice()
        func voicePressChanged(_ pressing: Bool)
        func speechValidationContent() -> AnyView
        func chatValidationContent() -> AnyView
    }

    @MainActor
    public protocol ApplicationRootProviding: AnyObject {
        var homePreparation: HomeModelPreparation { get }
        func retryHomePreparation()
        func interactionActivityChanged()
        func modelRequirementsChanged()
        var startupIssue: String? { get }
        func retry()
        var session: (any ApplicationSessionProviding)? { get }
        var navigation: NavigationState { get }
        var cameraState: CameraState { get }
        var cameraControls: any CameraControlling { get }
        var bluetoothState: BluetoothSettingsState { get }
        var bluetoothControls: any BluetoothControlling { get }
        var settings: SettingsState { get }
        var settingsControls: any SettingsControlling { get }
        var modelResources: ModelResourcesState { get }
        var modelResourceControls: any ModelResourcesControlling { get }
        var recordDestinations: [AgentRecordDestination] { get }
        func navigate(_ destination: AppDestination?)
        func cameraPreview() -> AnyView
        func navigationChanged()
        func prepare(progress: @MainActor (String) -> Void) async throws
    }
#endif
