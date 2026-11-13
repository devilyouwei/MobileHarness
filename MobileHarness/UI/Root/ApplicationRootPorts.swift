#if os(iOS)
    import Foundation
    import SwiftUI

    @MainActor
    public protocol ApplicationSessionProviding: AnyObject {
        var conversation: ConversationState { get }
        var homeNotices: HomeNoticeState { get }
        var audioDetectionState: AudioDetectionState { get }
        var audioDetectionRequests: UIRequests<AudioDetectionInput, Void> { get }
        var listeningRequests: UIRequests<ListeningInput, Void> { get }
        func speechValidationContent() -> AnyView
        func chatValidationContent() -> AnyView
    }

    @MainActor
    public protocol ApplicationRootProviding: AnyObject {
        var runtimeLog: RuntimeLogState { get }
        var homePreparation: HomeModelPreparation { get }
        func retryHomePreparation()
        func interactionActivityChanged()
        func modelRequirementsChanged()
        var startupIssue: String? { get }
        func retry()
        var session: (any ApplicationSessionProviding)? { get }
        var windows: WindowState { get }
        var web: WebPageContainer { get }
        var island: IslandState { get }
        var navigation: NavigationState { get }
        var cameraState: CameraState { get }
        var cameraControls: any CameraControlling { get }
        var bluetoothState: BluetoothSettingsState { get }
        var bluetoothControls: any BluetoothControlling { get }
        var settings: SettingsState { get }
        var settingsControls: any SettingsControlling { get }
        var modelResources: ModelResourcesState { get }
        var modelResourceControls: any ModelResourcesControlling { get }
        var album: UIAlbumContainer { get }
        var recordDestinations: [AgentRecordDestination] { get }
        func navigate(_ destination: AppDestination?)
        func cameraPreview() -> AnyView
        func navigationChanged()
        func prepare(progress: @MainActor (String) -> Void) async throws
    }
#endif
