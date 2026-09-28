#if DEBUG
    import SwiftUI

    /// Explicit launch-only diagnostic; never records audio or executes device Actions.
    @MainActor
    struct Qwen35ValidationView: View {
        let validate: @Sendable () async throws -> String
        @State private var result = "Loading speech and chat models…"

        var body: some View {
            ScrollView { Text(result).padding().textSelection(.enabled) }
                .task {
                    do {
                        result = try await validate()
                        print("QWEN_VOICE_VALIDATION_OK \(result)")
                    } catch {
                        result = "Validation failed: \(error)"
                        print("QWEN_VOICE_VALIDATION_FAILED \(error)")
                    }
                }
        }
    }
#endif
