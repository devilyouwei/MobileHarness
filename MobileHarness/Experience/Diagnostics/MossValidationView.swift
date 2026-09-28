import AVFAudio
import ModelKit
import PlatformKit
import SwiftUI

/// Explicit model validation mode. Does not submit Agent input or run a conversation.
@MainActor
struct MossValidationView: View {
    @State private var text = "你好，Hello world，欢迎使用本地语音助手。"
    @State private var report = "中英双语 · Core ML · MOSS Nano Beta · zh_1 / en_2"
    @State private var task: Task<Void, Never>?
    @State private var player = AppleAudioIO()
    let provider: any SpeechSynthesisCapability
    let load: @Sendable () async throws -> Void
    let unload: @Sendable () async throws -> Void
    @State private var session: InferenceSession<SynthesisEvent>?
    @State private var stopping = false

    var body: some View {
        NavigationStack {
            Form {
                Section("MOSS 本地语音验证") {
                    Text("支持中文、英语及混读。首次加载包含本地资源检查与模型编译。")
                    TextEditor(text: $text).frame(minHeight: 100).disabled(task != nil)
                    Button("合成并试听") { start() }.disabled(task != nil || stopping)
                    Button("停止并卸载") { stop() }.disabled(stopping)
                }
                Section("测量结果") { Text(report).textSelection(.enabled) }
                Text("首段为 PCM 生成时间；内存和发热请配合 Instruments 测量。声音自然度需人工试听。")
                    .font(.footnote)
            }
            .navigationTitle("MOSS 验证")
            .onDisappear { stop() }
            .task {
                if ProcessInfo.processInfo.arguments.contains("-moss-autorun") { start() }
            }
        }
    }

    private func start() {
        player.stop()
        task = Task {
            defer { task = nil }
            do {
                #if targetEnvironment(simulator)
                    throw CapabilityError.unavailable("请使用 iOS 27 真机运行 MossValidation")
                #else
                    let clock = ContinuousClock()
                    let loadStart = clock.now
                    report = "正在加载并预热本地模型…"
                    try await load()
                    let loadTime = seconds(loadStart.duration(to: clock.now))
                    let start = clock.now
                    let output = try await provider.synthesize(SpeechSynthesisRequest(text: text, locale: "auto"))
                    session = output
                    defer {
                        output.cancel()
                        session = nil
                    }
                    var samples: [Float] = []
                    var first: Double?
                    var finished = false
                    for try await event in output.events {
                        try Task.checkCancellation()
                        switch event {
                        case .audio(let frame):
                            if first == nil { first = seconds(start.duration(to: clock.now)) }
                            samples += frame.data.withUnsafeBytes { bytes in
                                (0..<frame.sampleCount).map {
                                    bytes.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self)
                                }
                            }
                        case .finished: finished = true
                        }
                    }
                    try Task.checkCancellation()
                    guard finished, !samples.isEmpty else { throw CapabilityError.unavailable("没有生成音频") }
                    let elapsed = seconds(start.duration(to: clock.now))
                    let duration = Double(samples.count) / 48_000
                    report = String(
                        format: "加载及预热 %.2f 秒\n首段 PCM %.2f 秒\n总合成 %.2f 秒\n音频 %.2f 秒\n实时率 %.2f（越低越快）\n热状态：%@", loadTime,
                        first ?? elapsed, elapsed, duration, elapsed / duration,
                        String(describing: ProcessInfo.processInfo.thermalState))
                    let automatic = ProcessInfo.processInfo.arguments.contains("-moss-autorun")
                    if !automatic || ProcessInfo.processInfo.arguments.contains("-moss-playback") {
                        try await play(samples)
                        report += "\n扬声器播放完成（AppleAudioIO）"
                    }
                    saveAutomaticReport(report)
                #endif
            } catch is CancellationError {
                report = "已停止"
            } catch {
                report = "验证失败：\(error)"
                saveAutomaticReport(report)
            }
        }
    }

    private func saveAutomaticReport(_ report: String) {
        guard ProcessInfo.processInfo.arguments.contains("-moss-autorun"),
            let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        else { return }
        try? report.write(to: folder.appendingPathComponent("moss-validation.txt"), atomically: true, encoding: .utf8)
    }

    private func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    private func play(_ samples: [Float]) async throws {
        try AVAudioSession.sharedInstance().setCategory(.playback)
        try AVAudioSession.sharedInstance().setActive(true)
        var offset = 0
        try await player.playStream {
            guard offset < samples.count else { return nil }
            let end = min(offset + 4096, samples.count)
            defer { offset = end }
            return PlaybackPCM(samples: Array(samples[offset..<end]), sampleRate: 48_000)
        }
    }

    private func stop() {
        guard !stopping else { return }
        stopping = true
        session?.cancel()
        task?.cancel()
        player.stop()
        let pending = task
        Task {
            await pending?.value
            #if !targetEnvironment(simulator)
                try? await unload()
            #endif
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            report = "已停止并卸载"
            stopping = false
        }
    }
}
