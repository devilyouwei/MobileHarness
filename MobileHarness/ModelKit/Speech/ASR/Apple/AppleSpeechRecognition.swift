@preconcurrency import AVFAudio
import Foundation
import ModelKit
import Speech
import Synchronization

/// On-device SpeechTranscriber. Microphone permission/capture remain App-owned.
@available(iOS 26, macOS 26, *)
public actor AppleSpeechRecognition: SpeechRecognitionCapability {
    private let resource: ModelResource<Locale>
    private let locale: String
    public init(context: ModelContext, locale: String = "zh-CN") throws {
        self.locale = locale
        resource = try context.resource {
            guard SpeechTranscriber.isAvailable,
                let supported = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: locale))
            else { throw CapabilityError.unavailable("On-device speech recognition is unsupported for this locale") }
            let module = SpeechTranscriber(locale: supported, preset: .progressiveTranscription)
            if let installation = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                try await installation.downloadAndInstall()
            }
            try Task.checkCancellation()
            return supported
        }
    }
    public var availability: CapabilityAvailability {
        get async {
            guard SpeechTranscriber.isAvailable,
                await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: locale)) != nil
            else {
                return .unavailable(reason: "On-device speech recognition is unavailable for this device or locale")
            }
            return .available
        }
    }
    public func warmup() async throws {
        let lease = try await resource.acquire()
        await resource.release(lease.id)
    }
    public func transcribe(_ request: SpeechRecognitionRequest) async throws -> SpeechRecognitionSession {
        guard request.locale == locale || request.locale == "auto", request.format.channels == 1,
            request.format.encoding == .float32, request.format.sampleRate == 16000
        else {
            throw CapabilityError.invalidRequest("Apple recognition requires 16 kHz mono PCM and the configured locale")
        }
        let lease = try await resource.acquire()
        do {
            let module = SpeechTranscriber(locale: lease.model, preset: .progressiveTranscription)
            let detector = SpeechDetector(detectionOptions: .init(sensitivityLevel: .medium), reportResults: false)
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module, detector]) else {
                throw CapabilityError.unavailable("No compatible speech analyzer audio format is available")
            }
            let resource = resource
            let worker = try AnalyzerWorker(
                module: module, detector: detector, format: format, release: { await resource.release(lease.id) })
            let pair = InferenceSession<TranscriptionEvent>.make(
                context: request.context, limits: try StreamLimits(capacity: 128, maximumEventBytes: 65600),
                estimatedBytes: { $0.estimatedBytes }, onTermination: { _ in Task { await worker.stop() } })
            try await worker.start(emitter: pair.emitter)
            await resource.setCancellation(lease.id) { [weak session = pair.session] in session?.cancel() }
            return SpeechRecognitionSession(
                output: pair.session, format: request.format,
                sendAudio: { try await worker.send($0) }, finishInput: { try await worker.finish() })
        } catch {
            await resource.release(lease.id)
            throw error
        }
    }
}

@available(iOS 26, macOS 26, *)
private actor AnalyzerWorker {
    private let module: SpeechTranscriber
    private let detector: SpeechDetector
    private let analyzer: SpeechAnalyzer
    private let format: AVAudioFormat
    private let converter: AVAudioConverter
    private let release: @Sendable () async -> Void
    private let inputs: (session: InferenceSession<AnalyzerInput>, emitter: InferenceEmitter<AnalyzerInput>)
    private var reader: Task<Void, Never>?
    private var emitter: InferenceEmitter<TranscriptionEvent>?
    private var closed = false
    private var finishing = false
    private var busy = false
    private var closing: Task<Void, Never>?
    private var samples = 0
    private struct Piece {
        let end: Double
        let text: String
    }
    private var pieces: [Double: Piece] = [:]
    private let segment = UUID().uuidString
    private var revision: UInt64 = 0
    init(
        module: SpeechTranscriber, detector: SpeechDetector, format: AVAudioFormat,
        release: @escaping @Sendable () async -> Void
    ) throws {
        self.module = module
        self.detector = detector
        self.format = format
        self.release = release
        inputs = InferenceSession<AnalyzerInput>.make(
            context: InferenceContext(), limits: try StreamLimits(capacity: 4, maximumEventBytes: 1_048_576),
            estimatedBytes: { Int($0.buffer.frameLength) * Int($0.buffer.format.channelCount) * 4 })
        analyzer = SpeechAnalyzer(
            modules: [module, detector], options: .init(priority: .userInitiated, modelRetention: .whileInUse))
        guard
            let input = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
            let converter = AVAudioConverter(from: input, to: format)
        else { throw CapabilityError.unavailable("Speech analyzer audio format conversion is unavailable") }
        self.converter = converter
    }
    func start(emitter: InferenceEmitter<TranscriptionEvent>) async throws {
        self.emitter = emitter
        let module = module
        reader = Task { [weak self] in
            do {
                for try await result in module.results {
                    try await self?.receive(
                        start: result.range.start.seconds, end: result.range.end.seconds,
                        text: String(result.text.characters))
                }
            } catch { await self?.failed(error) }
        }
        do {
            try await analyzer.prepareToAnalyze(in: format)
            try await analyzer.start(inputSequence: inputs.session.events)
        } catch {
            await stop()
            throw error
        }
    }
    func send(_ frame: AudioFrame) async throws {
        guard !closed, !finishing else { throw CapabilityError.inputFinished }
        guard !busy else { throw CapabilityError.inputBusy }
        busy = true
        defer { busy = false }
        guard frame.format.sampleRate == 16000, frame.format.channels == 1,
            frame.format.encoding == .float32, frame.sampleCount <= 16000,
            samples <= 4_800_000 - frame.sampleCount
        else {
            throw CapabilityError.invalidRequest("Apple recognition input exceeds the duration limit")
        }
        let input = try PCMCodec.decode(frame)
        guard let channel = input.floatChannelData?[0],
            (0..<Int(input.frameLength)).allSatisfy({ channel[$0].isFinite })
        else { throw CapabilityError.invalidRequest("Invalid PCM") }
        let capacity = AVAudioFrameCount(ceil(Double(frame.sampleCount) * format.sampleRate / 16000) + 512)
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw CapabilityError.bufferOverflow
        }
        let box = AnalyzerBuffer(input)
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            if box.used.withLock({ used in
                if used { return true }
                used = true
                return false
            }) {
                state.pointee = .noDataNow
                return nil
            }
            state.pointee = .haveData
            return box.buffer
        }
        if let error { throw error }
        guard status != .error else { throw CapabilityError.invalidRequest("Audio format conversion failed") }
        samples += frame.sampleCount
        if output.frameLength > 0 {
            try await inputs.emitter.yieldSuspending(AnalyzerInput(buffer: output))
        }
    }
    private func receive(start: Double, end: Double, text: String) throws {
        guard !closed, let emitter else { return }
        guard start.isFinite, pieces.count < 2048 || pieces[start] != nil else { throw CapabilityError.bufferOverflow }
        guard end.isFinite, end >= start else { throw CapabilityError.invalidRequest("Invalid transcription range") }
        pieces = pieces.filter { key, piece in key == start || piece.end <= start || key >= end }
        pieces[start] = Piece(end: end, text: text)
        let transcript = transcript()
        guard transcript.utf8.count <= 65536 else { throw CapabilityError.eventTooLarge }
        try emitter.yield(TranscriptionEvent(segmentID: segment, revision: revision, text: transcript, isFinal: false))
        revision += 1
    }
    private func transcript() -> String {
        pieces.keys.sorted().compactMap { pieces[$0]?.text }.reduce("") { accumulated, text in
            guard let last = accumulated.last, let first = text.first,
                last.isASCII && last.isLetter, first.isASCII && first.isLetter
            else { return accumulated + text }
            return accumulated + " " + text
        }
    }
    func finish() async throws {
        guard !closed, !finishing else { throw CapabilityError.inputFinished }
        finishing = true
        inputs.emitter.finish()
        do {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            await reader?.value
            guard !closed, let emitter else { throw CancellationError() }
            let text = transcript()
            try emitter.yield(TranscriptionEvent(segmentID: segment, revision: revision, text: text, isFinal: true))
            emitter.finish()
            await stop()
        } catch {
            await failed(error)
            throw error
        }
    }
    private func failed(_ error: any Error) async {
        emitter?.fail(error)
        await stop()
    }
    func stop() async {
        if let closing {
            await closing.value
            return
        }
        guard !closed else { return }
        closed = true
        inputs.session.cancel()
        inputs.emitter.finish()
        let analyzer = analyzer
        let release = release
        let task = Task {
            await analyzer.cancelAndFinishNow()
            await release()
        }
        closing = task
        await task.value
    }
}
private final class AnalyzerBuffer: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    let used = Mutex(false)
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
}
