#if os(iOS)
    import SwiftUI

    @MainActor
    public struct MossValidationView: View {
        @Bindable var state: SpeechDiagnosticState
        let controls: any SpeechDiagnosticControlling
        let autorun: Bool
        public init(state: SpeechDiagnosticState, controls: any SpeechDiagnosticControlling, autorun: Bool = false) {
            self.state = state
            self.controls = controls
            self.autorun = autorun
        }
        public var body: some View {
            NavigationStack {
                Form {
                    Section("MOSS Local Speech Validation") {
                        Text(
                            "Supports English, Chinese, and mixed text. Initial load checks local resources and compiles the model."
                        )
                        TextEditor(text: $state.text).frame(minHeight: 100)
                            .disabled(state.isRunning || state.isStopping)
                        Button("Synthesize and play") { controls.start() }.disabled(state.isRunning || state.isStopping)
                        Button("Stop and unload") { controls.stop() }.disabled(state.isStopping)
                    }
                    Section("Measurements") { Text(state.report).textSelection(.enabled) }
                    Text(
                        "First chunk measures PCM generation. Use Instruments for memory and thermals, and listen to assess naturalness."
                    )
                    .font(.footnote)
                }
                .navigationTitle("MOSS Validation")
                .onDisappear { controls.stop() }
                .task {
                    if autorun { controls.start() }
                }
            }
        }

    }

#endif
