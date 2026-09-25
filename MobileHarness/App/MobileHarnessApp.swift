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
            .task(id: startupAttempt) {
                guard container == nil, startupError == nil else { return }
                do {
                    let prepared = try await AppContainer { startupStatus = $0 }
                    try Task.checkCancellation()
                    container = prepared
                } catch is CancellationError {
                    // A disappearing scene must not publish a partially prepared container.
                } catch { startupError = String(describing: error) }
            }
        }
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
