import AVFAudio
import Foundation
import ModelKit
import Synchronization

@MainActor
public final class AppleSpeechSynthesis: SpeechSynthesisCapability {
    private let resource: ModelResource<Void>
    private var activeWorker: (id: UUID, worker: SynthesisWorker)?
    public init(context: ModelContext) throws {
        resource = try context.resource { () }
    }
    public var availability: CapabilityAvailability {
        AVSpeechSynthesisVoice.speechVoices().isEmpty ? .unavailable(reason: "未找到系统语音声音") : .available
    }
    /// The shared speech contract uses auto for Chinese/English conversation replies.
    nonisolated static func language(text: String, locale: String) -> String {
        let normalized = locale.lowercased().replacingOccurrences(of: "_", with: "-")
        switch normalized {
        case "auto":
            let chinese = text.unicodeScalars.contains {
                (0x3400...0x4DBF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value)
                    || (0x20000...0x2FA1F).contains($0.value)
            }
            return chinese ? "zh-CN" : "en-US"
        case "zh", "zh-hans": return "zh-CN"
        case "zh-hant": return "zh-TW"
        case "en": return "en-US"
        default: return locale.replacingOccurrences(of: "_", with: "-")
        }
    }
    public func synthesize(_ request: SpeechSynthesisRequest) async throws -> InferenceSession<SynthesisEvent> {
        try Task.checkCancellation()
        guard request.text.utf8.count <= 2048 else { throw CapabilityError.invalidRequest("单次合成文本过长") }
        let language = Self.language(text: request.text, locale: request.locale)
        guard let voice = AVSpeechSynthesisVoice(language: language) else {
            throw CapabilityError.unavailable("当前系统没有 \(language) 的语音声音，请先在系统设置中添加对应语音")
        }
        guard activeWorker == nil else { throw CapabilityError.inputBusy }
        let lease = try await resource.acquire()
        let token = lease.id
        let resource = resource
        let pair = InferenceSession<SynthesisEvent>.make(
            context: request.context, limits: try StreamLimits(capacity: 256, maximumEventBytes: 16_448),
            estimatedBytes: { $0.estimatedBytes },
            onTermination: { [weak self] _ in
                Task { @MainActor in
                    if let self, self.activeWorker?.id == token {
                        self.activeWorker?.worker.stop()
                        self.activeWorker = nil
                    }
                    await resource.release(token)
                }
            })
        let worker = SynthesisWorker(text: request.text, voice: voice, emitter: pair.emitter)
        activeWorker = (token, worker)
        worker.start()
        await resource.setCancellation(token) { [weak session = pair.session] in session?.cancel() }
        return pair.session
    }
}

@MainActor
private final class SynthesisWorker {
    private let synthesizer = AVSpeechSynthesizer()
    private let utterance: AVSpeechUtterance
    private let emitter: InferenceEmitter<SynthesisEvent>
    private var timeout: Task<Void, Never>?
    init(text: String, voice: AVSpeechSynthesisVoice, emitter: InferenceEmitter<SynthesisEvent>) {
        utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        self.emitter = emitter
    }
    func start() {
        synthesizer.write(utterance, toBufferCallback: Self.handler(emitter: emitter))
        let emitter = emitter
        timeout = Task {
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            emitter.fail(CapabilityError.unavailable("语音合成超时"))
        }
    }
    nonisolated private static func handler(emitter: InferenceEmitter<SynthesisEvent>)
        -> @Sendable (AVAudioBuffer) -> Void
    {
        let accumulator = Mutex(SynthesisPCMAccumulator())
        return { buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer else {
                emitter.fail(CapabilityError.invalidRequest("系统语音返回了非 PCM 音频"))
                return
            }
            do {
                let frame = pcm.frameLength > 0 ? try PCMCodec.encode(pcm, sequence: 0) : nil
                // Serialize callbacks and emission. The termination hook only schedules MainActor cleanup;
                // it does not synchronously re-enter this accumulator.
                try accumulator.withLock { accumulator in
                    if let frame {
                        for chunk in try accumulator.append(frame) { try emitter.yield(.audio(chunk)) }
                    } else {
                        for chunk in try accumulator.finish() { try emitter.yield(.audio(chunk)) }
                        try emitter.yield(.finished)
                        emitter.finish()
                    }
                }
            } catch { emitter.fail(error) }
        }
    }
    func stop() {
        timeout?.cancel()
        timeout = nil
        synthesizer.stopSpeaking(at: .immediate)
    }
}
