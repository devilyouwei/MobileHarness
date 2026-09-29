import AppWorkflows
import SwiftUI
import UI

@main
@MainActor
struct MobileHarnessApp: App {
    @State private var assembly = AppAssembly()
    private var camera: CameraCoordinator { assembly.camera }
    private var container: AppContainer? { assembly.container }
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingSettings = false
    @State private var startupError: String?
    @State private var startupStatus = "正在准备…"
    @State private var startupAttempt = 0
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                Group {
                    if isVisualPreview {
                        ConversationVisualPreview()
                    } else if isDiagnostic {
                        startupContent
                    } else {
                        CameraConversationSurface(
                            camera: camera.state, controls: camera,
                            openSettings: {
                                container?.lifecycle.stopVoice()
                                showingSettings = true
                            }
                        ) {
                            CameraPreviewAdapter(
                                source: camera.preview,
                                facing: camera.state.facing == .front ? .front : .back, skeleton: camera.state.skeleton)
                        } content: {
                            startupContent
                        }
                    }
                }
                .navigationTitle("首页")
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(isPresented: $showingSettings) {
                    SettingsView(
                        settings: assembly.settings, bluetooth: assembly.bluetooth.state,
                        bluetoothControls: assembly.bluetooth, history: assembly.history.state,
                        historyControls: assembly.history
                    ) {
                        let applied = await assembly.settings.save()
                        if applied, container == nil {
                            startupError = nil
                            startupStatus = "正在准备…"
                            startupAttempt += 1
                        }
                        return applied
                    }

                }
            }
            .task {
                if !isVisualPreview && !isDiagnostic {
                    assembly.bluetooth.setForeground(scenePhase == .active)
                    await assembly.bluetooth.run()
                }
            }
            .task {
                if !isVisualPreview && !isDiagnostic {
                    camera.setForeground(scenePhase == .active && !showingSettings)
                    await camera.observe()
                }
            }
            .onChange(of: showingSettings) { _, showing in
                if !isVisualPreview && !isDiagnostic { camera.setForeground(scenePhase == .active && !showing) }
            }
            .onChange(of: scenePhase) { _, phase in
                if !isVisualPreview && !isDiagnostic {
                    camera.setForeground(phase == .active && !showingSettings)
                    assembly.bluetooth.setForeground(phase == .active)
                    if phase == .background { container?.lifecycle.stopVoice(message: "已进入后台，轻触重新开始") }
                }
            }
            .task(id: container.map { ObjectIdentifier($0) }) {
                if let container, !isDiagnostic { await container.lifecycle.run() }
            }
            .task(id: startupAttempt) {
                if !isVisualPreview { await prepare() }
            }
        }
    }

    private var isVisualPreview: Bool {
        #if DEBUG
            ProcessInfo.processInfo.arguments.contains("-conversation-preview")
        #else
            false
        #endif
    }

    private var isDiagnostic: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        #if DEBUG
            if arguments.contains("-qwen35-validation") { return true }
        #endif
        return arguments.contains("-moss-benchmark")
    }

    private var startupContent: some View {
        Group {
            if let container {
                content(container)
            } else {
                ConversationStartupView(status: startupStatus, error: startupError) {
                    startupError = nil
                    startupStatus = "正在准备…"
                    startupAttempt += 1
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
    private func content(_ container: AppContainer) -> some View {
        #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-qwen35-validation") {
                container.makeChatValidationView()
            } else {
                standardContent(container)
            }
        #else
            standardContent(container)
        #endif
    }
    @ViewBuilder
    private func standardContent(_ container: AppContainer) -> some View {
        if ProcessInfo.processInfo.arguments.contains("-moss-benchmark") {
            container.makeMossValidationView()
        } else {
            ConversationView(
                state: container.conversation, robot: assembly.bluetooth.state,
                toggleVoice: container.lifecycle.toggleVoice)
        }
    }

}
