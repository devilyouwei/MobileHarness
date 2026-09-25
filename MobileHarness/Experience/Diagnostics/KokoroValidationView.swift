import AVFAudio
import ModelKit
import SwiftUI

/// Explicit model validation mode. Does not submit Agent input or run a conversation.
@MainActor
struct KokoroValidationView: View {
    @State private var text = "The quick brown fox jumps over the lazy dog."
    @State private var report = "英语 · af_heart · 本地验证，非多语言验收"
    @State private var task: Task<Void, Never>?
    @State private var player: AVAudioPlayer?
    let provider: any SpeechSynthesisCapability
    let load: @Sendable () async throws -> Void
    let unload: @Sendable () async throws -> Void
    @State private var session: InferenceSession<SynthesisEvent>?
    @State private var file: URL?
    @State private var stopping = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Kokoro 本地语音验证") {
                    Text("此版本仅验证美式英语。首次加载包含文件校验与模型编译。")
                    TextEditor(text: $text).frame(minHeight: 100).disabled(task != nil)
                    Button("合成并试听") { start() }.disabled(task != nil || stopping)
                    Button("停止并卸载") { stop() }.disabled(stopping)
                }
                Section("测量结果") { Text(report).textSelection(.enabled) }
                Text("首段为 PCM 生成时间；内存和发热请配合 Instruments 测量。声音自然度需人工试听。")
                    .font(.footnote)
            }
            .navigationTitle("Kokoro 验证")
            .onDisappear { stop() }
            .task {
                if ProcessInfo.processInfo.arguments.contains("-kokoro-autorun") { start() }
            }
        }
    }

    private func start() {
        player?.stop()
        task = Task {
            defer { task = nil }
            do {
                #if targetEnvironment(simulator)
                    throw CapabilityError.unavailable("请使用 iOS 27 真机运行 KokoroValidation")
                #else
                    let clock = ContinuousClock()
                    let loadStart = clock.now
                    report = "正在加载本地模型…"
                    try await load()
                    let loadTime = seconds(loadStart.duration(to: clock.now))
                    let start = clock.now
                    let output = try await provider.synthesize(SpeechSynthesisRequest(text: text, locale: "en-US"))
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
                    let duration = Double(samples.count) / 24_000
                    report = String(
                        format: "加载 %.2f 秒\n首段 PCM %.2f 秒\n总合成 %.2f 秒\n音频 %.2f 秒\n实时率 %.2f（越低越快）\n热状态：%@", loadTime,
                        first ?? elapsed, elapsed, duration, elapsed / duration,
                        String(describing: ProcessInfo.processInfo.thermalState))
                    if ProcessInfo.processInfo.arguments.contains("-kokoro-autorun") {
                        saveAutomaticReport(report)
                    } else {
                        try play(samples)
                    }
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
        guard ProcessInfo.processInfo.arguments.contains("-kokoro-autorun"),
            let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        else { return }
        try? report.write(to: folder.appendingPathComponent("kokoro-validation.txt"), atomically: true, encoding: .utf8)
    }

    private func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    private func play(_ samples: [Float]) throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1),
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
            let destination = buffer.floatChannelData?[0]
        else { throw CapabilityError.unavailable("无法创建播放缓冲") }
        buffer.frameLength = buffer.frameCapacity
        samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress { destination.update(from: base, count: source.count) }
        }
        if let file { try? FileManager.default.removeItem(at: file) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kokoro-\(UUID().uuidString).wav")
        file = url
        do {
            let audio = try AVAudioFile(forWriting: url, settings: format.settings)
            try audio.write(from: buffer)
        }
        try AVAudioSession.sharedInstance().setCategory(.playback)
        try AVAudioSession.sharedInstance().setActive(true)
        player = try AVAudioPlayer(contentsOf: url)
        guard player?.play() == true else { throw CapabilityError.unavailable("无法开始播放") }
    }

    private func stop() {
        guard !stopping else { return }
        stopping = true
        session?.cancel()
        task?.cancel()
        player?.stop()
        player = nil
        let pending = task
        Task {
            await pending?.value
            #if !targetEnvironment(simulator)
                try? await unload()
            #endif
            if let file {
                try? FileManager.default.removeItem(at: file)
                self.file = nil
            }
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            report = "已停止并卸载"
            stopping = false
        }
    }
}
