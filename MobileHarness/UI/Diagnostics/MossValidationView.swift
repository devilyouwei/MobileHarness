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
                    Section("MOSS 本地语音验证") {
                        Text("支持中文、英语及混读。首次加载包含本地资源检查与模型编译。")
                        TextEditor(text: $state.text).frame(minHeight: 100)
                            .disabled(state.isRunning || state.isStopping)
                        Button("合成并试听") { controls.start() }.disabled(state.isRunning || state.isStopping)
                        Button("停止并卸载") { controls.stop() }.disabled(state.isStopping)
                    }
                    Section("测量结果") { Text(state.report).textSelection(.enabled) }
                    Text("首段为 PCM 生成时间；内存和发热请配合 Instruments 测量。声音自然度需人工试听。")
                        .font(.footnote)
                }
                .navigationTitle("MOSS 验证")
                .onDisappear { controls.stop() }
                .task {
                    if autorun { controls.start() }
                }
            }
        }

    }

#endif
