#if os(iOS)
    import Foundation
    import SwiftUI
    import UIKit

    @MainActor
    public struct ApplicationRootView: View {
        private let assembly: any ApplicationRootProviding
        public init(services: any ApplicationRootProviding) { assembly = services }
        private var container: (any ApplicationSessionProviding)? { assembly.session }
        @Environment(\.scenePhase) private var scenePhase
        @State private var startupError: String?
        @State private var startupStatus = "正在准备…"
        public var body: some View {
            Group {
                PersistentHomeNavigation(
                    path: Binding(get: { assembly.navigation.path }, set: { assembly.navigation.path = $0 })
                ) {
                    Group {
                        if isDiagnostic {
                            startupContent
                        } else {
                            CameraConversationSurface(
                                camera: assembly.cameraState, controls: assembly.cameraControls,
                                blocksNewActions: assembly.homePreparation.blocksNewActions,
                                openSettings: {
                                    assembly.navigate(.settings)
                                }
                            ) {
                                assembly.cameraPreview()
                            } content: {
                                startupContent
                            }
                            .overlay {
                                if let session = container, session.conversation.showsModelRetry {
                                    HomeModelPreparationRetry(retry: assembly.retryHomePreparation)
                                }
                            }
                        }
                    }
                } destination: { destination in
                    destinationView(destination)
                }
                .onChange(of: assembly.navigation.path) { _, path in
                    assembly.navigationChanged()
                }
                .onChange(of: container?.conversation.hasActiveInteraction) { _, _ in
                    assembly.interactionActivityChanged()
                }
                .onChange(of: assembly.cameraState.isEnabled) { _, _ in
                    assembly.modelRequirementsChanged()
                }
                .onChange(of: keepsHomeScreenAwake, initial: true) { _, keepsAwake in
                    UIApplication.shared.isIdleTimerDisabled = keepsAwake
                }
                .task {
                    await prepare()
                }
            }
        }

        @ViewBuilder private func destinationView(_ destination: AppDestination) -> some View {
            switch destination {
            case .settings:
                SettingsView(bluetooth: assembly.bluetoothState) { page in assembly.navigate(page) }
            case .language:
                LanguageModelSettingsView(
                    settings: assembly.settings, settingsControls: assembly.settingsControls,
                    modelResources: assembly.modelResources, modelResourceControls: assembly.modelResourceControls,
                    save: saveSettings)
            case .bluetooth: BluetoothSettingsView(state: assembly.bluetoothState, controls: assembly.bluetoothControls)
            case .history: AgentRecordsView(destinations: assembly.recordDestinations)
            case .recognition, .synthesis, .vision:
                ModelResourcesView(
                    state: assembly.modelResources, controls: assembly.modelResourceControls,
                    group: destination == .recognition
                        ? .recognition : (destination == .synthesis ? .synthesis : .vision),
                    audioDetection: destination == .recognition ? container?.audioDetectionState : nil,
                    audioDetectionControls: destination == .recognition ? container?.audioDetectionControls : nil)
            }
        }
        private func saveSettings() async -> Bool {
            let applied = await assembly.settingsControls.save()
            if applied, container == nil { assembly.retry() }
            return applied
        }

        private var keepsHomeScreenAwake: Bool {
            scenePhase == .active && !isDiagnostic
        }

        private var isDiagnostic: Bool {
            let arguments = ProcessInfo.processInfo.arguments
            #if DEBUG
                if arguments.contains("-gemma4-validation") { return true }
            #endif
            return arguments.contains("-moss-benchmark")
        }

        private var startupContent: some View {
            Group {
                if let issue = assembly.startupIssue {
                    ConversationStartupView(status: startupStatus, error: issue) { assembly.retry() }
                } else if let container {
                    content(container)
                } else {
                    ConversationStartupView(status: startupStatus, error: startupError) {
                        assembly.retry()
                    }
                }
            }
        }

        private func prepare() async {
            guard container == nil, startupError == nil else { return }
            do {
                try await assembly.prepare { startupStatus = $0 }
            } catch is CancellationError {
                // A disappearing scene must not publish a partially prepared container.
            } catch { startupError = String(describing: error) }
        }
        @ViewBuilder
        private func content(_ container: any ApplicationSessionProviding) -> some View {
            #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-gemma4-validation") {
                    container.chatValidationContent()
                } else {
                    standardContent(container)
                }
            #else
                standardContent(container)
            #endif
        }
        @ViewBuilder
        private func standardContent(_ container: any ApplicationSessionProviding) -> some View {
            if ProcessInfo.processInfo.arguments.contains("-moss-benchmark") {
                container.speechValidationContent()
            } else {
                ConversationView(
                    state: container.conversation, activity: container.actionActivity,
                    toggleVoice: container.toggleVoice, voicePressChanged: container.voicePressChanged)
            }
        }

    }

#endif
