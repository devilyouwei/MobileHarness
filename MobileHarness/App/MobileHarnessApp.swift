import SwiftUI

@main
@MainActor
struct MobileHarnessApp: App {
    @State private var camera = CameraCoordinator()
    @Environment(\.scenePhase) private var scenePhase
    @State private var settings = AppSettings()
    @State private var showingSettings = false
    @State private var container: AppContainer?
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
                            camera: camera,
                            openSettings: {
                                container?.lifecycle.stopVoice()
                                showingSettings = true
                            }
                        ) { startupContent }
                    }
                }
                .navigationTitle("首页")
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(isPresented: $showingSettings) {
                    SettingsView(
                        settings: settings,
                        makeChat: {
                            try await settings.restore()
                            await container?.lifecycle.beginSettingsChange()
                            defer { container?.lifecycle.endSettingsChange() }
                            try Task.checkCancellation()
                            return try await AppContainer.diagnosticChat()
                        }
                    ) {
                        let applied = await settings.save(
                            beginChange: { await container?.lifecycle.beginSettingsChange() },
                            endChange: { container?.lifecycle.endSettingsChange() })
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
                    camera.setForeground(scenePhase == .active && !showingSettings)
                    await camera.observe()
                }
            }
            .onChange(of: showingSettings) { _, showing in
                if !isVisualPreview && !isDiagnostic { camera.setForeground(scenePhase == .active && !showing) }
            }
            .onChange(of: scenePhase) { _, phase in
                if !isVisualPreview && !isDiagnostic { camera.setForeground(phase == .active && !showingSettings) }
            }
            .task(id: container.map { ObjectIdentifier($0) }) {
                if let container, !isDiagnostic { await container.conversation.run() }
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
            try await settings.restore()
            let prepared = try await AppContainer { startupStatus = $0 }
            try Task.checkCancellation()
            container = prepared
        } catch is CancellationError {
            // A disappearing scene must not publish a partially prepared container.
        } catch { startupError = String(describing: error) }
    }
    @ViewBuilder
    private func content(_ container: AppContainer) -> some View {
        #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-qwen35-validation") {
                container.makeQwen35ValidationView()
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
            ConversationView(runtime: container.conversation)
        }
    }

}
