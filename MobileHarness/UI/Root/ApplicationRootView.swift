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
                                blocksNewActions: container == nil || assembly.startupIssue != nil,
                                openSettings: {
                                    assembly.navigate(.settings)
                                }
                            ) {
                                startupContent
                            }
                            .overlay {
                                if let session = container, session.conversation.showsModelRetry {
                                    HomeModelPreparationRetry(retry: assembly.retryHomePreparation)
                                }
                            }
                        }
                    }
                    .background {
                        LinearGradient(
                            colors: [Color(red: 0.08, green: 0.20, blue: 0.32), .black],
                            startPoint: .top, endPoint: .bottom
                        )
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    }
                    .navigationContext(.home, content: .ready)
                    .overlay { windowOverlay }
                } destination: { destination in
                    destinationView(destination)
                        .navigationContext(destination.contextPage)
                        .id(assembly.navigation.generation)
                }
                .environment(\.navigationContext, assembly.navigation)
                .onChange(of: assembly.navigation.path, initial: true) { _, path in
                    assembly.cameraState.windows = assembly.windows
                    assembly.cameraState.faceVisible = path.isEmpty
                    assembly.navigationChanged()
                }
                .onChange(of: container?.conversation.hasActiveInteraction) { _, _ in
                    assembly.interactionActivityChanged()
                }
                .background { IslandHost(state: assembly.island).allowsHitTesting(false) }
                .statusBarHidden(assembly.island.replacesSystemStatusBar)
                .onChange(of: assembly.cameraState.photoAspect) { _, aspect in
                    if let item = assembly.windows.windows.first(where: { $0.content == WindowContent.camera.rawValue })
                    {
                        assembly.windows.resizeContent(item.id, sizing: .image(aspect: aspect, controlsHeight: 140))
                    }
                }
                .onChange(of: assembly.cameraState.perceptionEnabled) { _, _ in
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

        private var windowOverlay: some View {
            WindowHost(
                state: assembly.windows, topBoundary: assembly.island.localFrame.map { Double($0.maxY) }
            ) { item in
                if item.content == WindowContent.camera.rawValue {
                    AnyView(
                        CameraWindowContent(
                            camera: assembly.cameraState, controls: assembly.cameraControls,
                            rendersPreview: !assembly.windows.isCovered(item.id)
                        ) { assembly.cameraPreview() })
                } else if item.content == WindowContent.artifact.rawValue {
                    AnyView(
                        Group {
                            if let page = assembly.web.sessions[item.id] {
                                WebPageView(page: page, subtitle: item.subtitle)
                            } else {
                                ProgressView()
                            }
                        })
                } else if item.content == WindowContent.web.rawValue {
                    AnyView(WebPageView(page: assembly.web))
                } else {
                    AnyView(Text("窗口内容不可用").foregroundStyle(.white))
                }
            }
            .ignoresSafeArea(.container)
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
            case .album: AlbumView(album: assembly.album)
            case .assistantHistory, .writerHistory:
                let id = destination == .assistantHistory ? "assistant" : "writer"
                Group {
                    if let record = assembly.recordDestinations.first(where: { $0.id == id }) {
                        record.makeView().environment(\.recordContextID, id).navigationContext(
                            .agentRecords, itemID: id)
                    } else {
                        Text("记录服务暂不可用")
                    }
                }
            case .recognition, .synthesis, .vision:
                ModelResourcesView(
                    state: assembly.modelResources, controls: assembly.modelResourceControls,
                    group: destination == .recognition
                        ? .recognition : (destination == .synthesis ? .synthesis : .vision),
                    audioDetection: destination == .recognition ? container?.audioDetectionState : nil,
                    audioDetectionRequests: destination == .recognition ? container?.audioDetectionRequests : nil)
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
                    listeningRequests: container.listeningRequests)
            }
        }

    }

#endif
