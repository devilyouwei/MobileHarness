import SwiftUI

@main
@MainActor
struct MobileHarnessApp: App {
    @State private var container: AppContainer?
    @State private var startupError: String?
    @State private var startupStatus = "正在准备…"
    @State private var startupAttempt = 0
    var body: some Scene {
        WindowGroup {
            Group {
                if isVisualPreview {
                    ConversationVisualPreview()
                } else if isDiagnostic {
                    startupContent
                } else {
                    CameraScene { startupContent }
                }
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
        return arguments.contains("-kokoro-benchmark")
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
        if ProcessInfo.processInfo.arguments.contains("-kokoro-benchmark") {
            container.makeKokoroValidationView()
        } else {
            ConversationView(runtime: container.conversation)
        }
    }

}
