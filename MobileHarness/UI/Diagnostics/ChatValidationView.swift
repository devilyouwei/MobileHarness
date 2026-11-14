#if os(iOS)
    #if DEBUG
        import SwiftUI

        /// Explicit launch-only diagnostic; never records audio or executes device Actions.
        @MainActor
        public struct ChatValidationView: View {
            let validate: @Sendable () async throws -> String
            @State private var result = "Loading speech and chat models…"
            @State private var run = 0
            @State private var running = true

            public init(validate: @escaping @Sendable () async throws -> String) { self.validate = validate }

            public var body: some View {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(result).textSelection(.enabled)
                        Button("Validate again") {
                            guard !running, run < Int.max else { return }
                            running = true
                            run += 1
                        }
                        .accessibilityIdentifier("chat.validation.rerun")
                        .disabled(running || run == Int.max)
                    }.padding()
                }
                .task(id: run) {
                    let currentRun = run
                    running = true
                    defer { if currentRun == run { running = false } }
                    result = "Loading speech and chat models…"
                    do {
                        let value = try await validate()
                        try Task.checkCancellation()
                        result = value
                        print("GEMMA_VOICE_VALIDATION_OK \(result)")
                    } catch {
                        result = "Validation failed: \(error)"
                        print("GEMMA_VOICE_VALIDATION_FAILED \(error)")
                    }
                }
            }
        }
    #endif

#endif
