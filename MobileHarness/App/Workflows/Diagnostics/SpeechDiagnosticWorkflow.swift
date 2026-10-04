#if os(iOS)
    import AVFAudio
    import Foundation
    import ModelKit
    import PlatformKit
    import UI

    /// Explicit diagnostic application workflow, separate from the authorized Agent Action path.
    @MainActor
    public final class SpeechDiagnosticWorkflow: SpeechDiagnosticControlling {
        public let state: SpeechDiagnosticState
        private let player: AppleAudioIO
        private let provider: any SpeechSynthesisCapability
        private let load: @Sendable () async throws -> Void
        private let unload: @Sendable () async throws -> Void
        private var task: Task<Void, Never>?
        private var session: InferenceSession<SynthesisEvent>?
        public init(
            state: SpeechDiagnosticState, player: AppleAudioIO, provider: any SpeechSynthesisCapability,
            load: @escaping @Sendable () async throws -> Void, unload: @escaping @Sendable () async throws -> Void
        ) {
            self.state = state
            self.player = player
            self.provider = provider
            self.load = load
            self.unload = unload
        }
        public func start() {
            guard !state.isRunning, !state.isStopping else { return }
            state.isRunning = true
            task = Task {
                await player.stop()
                defer {
                    task = nil
                    state.isRunning = false
                }
                do {
                    try Task.checkCancellation()
                    #if targetEnvironment(simulator)
                        throw CapabilityError.unavailable("请使用 iOS 27 真机运行 MossValidation")
                    #else
                        let clock = ContinuousClock()
                        let loadStart = clock.now
                        state.report = "正在加载并预热本地模型…"
                        try await load()
                        let loadTime = seconds(loadStart.duration(to: clock.now))
                        let start = clock.now
                        let output = try await provider.synthesize(
                            SpeechSynthesisRequest(text: state.text, locale: "auto"))
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
                        state.report = String(
                            format: "加载及预热 %.2f 秒\n首段 PCM %.2f 秒\n总合成 %.2f 秒\n音频 %.2f 秒\n实时率 %.2f（越低越快）\n热状态：%@",
                            loadTime,
                            first ?? elapsed, elapsed, duration, elapsed / duration,
                            String(describing: ProcessInfo.processInfo.thermalState))
                        let automatic = ProcessInfo.processInfo.arguments.contains("-moss-autorun")
                        if !automatic || ProcessInfo.processInfo.arguments.contains("-moss-playback") {
                            try await play(samples)
                            state.report += "\n扬声器播放完成（AppleAudioIO）"
                        }
                        saveAutomaticReport(state.report)
                    #endif
                } catch is CancellationError {
                    state.report = "已停止"
                } catch {
                    state.report = "验证失败：\(error)"
                    saveAutomaticReport(state.report)
                }
            }
        }

        private func saveAutomaticReport(_ report: String) {
            guard ProcessInfo.processInfo.arguments.contains("-moss-autorun"),
                let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            else { return }
            try? report.write(
                to: folder.appendingPathComponent("moss-validation.txt"), atomically: true, encoding: .utf8)
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

        public func stop() {
            guard !state.isStopping else { return }
            state.isStopping = true
            session?.cancel()
            task?.cancel()
            let pending = task
            Task {
                await player.stop()
                await pending?.value
                #if !targetEnvironment(simulator)
                    try? await unload()
                #endif
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                state.report = "已停止并卸载"
                state.isStopping = false
            }
        }
    }
#endif
