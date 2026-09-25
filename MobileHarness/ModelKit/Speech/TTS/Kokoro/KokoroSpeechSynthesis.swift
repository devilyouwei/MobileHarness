import Foundation
import ModelKit

#if canImport(CoreAI)
    @available(iOS 27, macOS 27, *)
    public actor KokoroSpeechSynthesis: SpeechSynthesisCapability {

        private let resource: ModelResource<KokoroModel>
        private let root: URL
        private var worker: (id: UUID, task: Task<Void, Never>)?

        public init(context: ModelContext, artifacts: URL) throws {
            root = artifacts
            resource = try context.resource {
                #if targetEnvironment(simulator) || !arch(arm64)
                    throw CapabilityError.unavailable("Kokoro requires physical Apple Silicon hardware")
                #else
                    let folder = artifacts
                    return try await KokoroModel(
                        predictorAt: folder.appendingPathComponent("kokoro_predictor.aimodel"),
                        prosodyAt: folder.appendingPathComponent("kokoro_prosody.aimodel"),
                        vocoderAt: folder.appendingPathComponent("kokoro_vocoder.aimodel"),
                        glueDir: folder.appendingPathComponent("kokoro_host_glue"))
                #endif
            }
        }

        public var availability: CapabilityAvailability {
            #if targetEnvironment(simulator) || !arch(arm64)
                .unavailable(reason: "Kokoro requires physical Apple Silicon hardware")
            #else
                FileManager.default.fileExists(atPath: root.appendingPathComponent("kokoro_predictor.aimodel").path)
                    ? .available : .unavailable(reason: "Kokoro artifacts not installed")
            #endif
        }

        /// One request, no pending queue. Finished audio is bounded to 60 seconds per request.
        public func synthesize(_ request: SpeechSynthesisRequest) async throws -> InferenceSession<SynthesisEvent> {
            try Task.checkCancellation()
            try KokoroInput.validate(text: request.text, locale: request.locale)
            guard worker == nil else { throw CapabilityError.inputBusy }
            let id = UUID()
            let pair = InferenceSession<SynthesisEvent>.make(
                context: request.context,
                limits: try StreamLimits(capacity: 384, maximumEventBytes: 16_448),
                estimatedBytes: { $0.estimatedBytes },
                onTermination: { [weak self] termination in
                    if case .finished = termination { return }
                    Task { await self?.cancel(id) }
                })
            let resource = resource
            let emitter = pair.emitter
            let task = Task.detached { [weak self] in
                do {
                    let lease = try await resource.acquire()
                    await resource.setCancellation(lease.id) { [weak self] in Task { await self?.cancel(id) } }
                    do {
                        try Task.checkCancellation()
                        let sink = KokoroPCMEmitter(emitter: emitter)
                        try await lease.model.synthesizeChunks(request.text) { try await sink.emit($0) }
                        try Task.checkCancellation()
                        await resource.release(lease.id)
                    } catch {
                        await resource.release(lease.id)
                        throw error
                    }
                    await self?.completed(id)
                    try emitter.yield(.finished)
                    emitter.finish()
                } catch {
                    await self?.completed(id)
                    emitter.fail(error)
                }
            }
            worker = (id, task)
            return pair.session
        }

        private func cancel(_ id: UUID) { if worker?.id == id { worker?.task.cancel() } }
        private func completed(_ id: UUID) { if worker?.id == id { worker = nil } }

    }
#else
    public actor KokoroSpeechSynthesis: SpeechSynthesisCapability {
        public init(context: ModelContext, artifacts: URL) throws {
            let _: ModelResource<Void> = try context.resource {
                throw CapabilityError.unavailable("Kokoro requires CoreAI on OS 27")
            }
        }
        public var availability: CapabilityAvailability { .unavailable(reason: "Kokoro requires CoreAI on OS 27") }
        public func synthesize(_ request: SpeechSynthesisRequest) async throws -> InferenceSession<SynthesisEvent> {
            throw CapabilityError.unavailable("Kokoro requires CoreAI on OS 27")
        }
    }
#endif

private actor KokoroPCMEmitter {
    let emitter: InferenceEmitter<SynthesisEvent>
    var samples = 0
    var sequence: UInt64 = 0
    init(emitter: InferenceEmitter<SynthesisEvent>) { self.emitter = emitter }
    func emit(_ chunk: [Float]) throws {
        guard !chunk.isEmpty, chunk.count <= 24_000 * 60 - samples else { throw CapabilityError.eventTooLarge }
        let format = try AudioFormat(sampleRate: 24_000, channels: 1, encoding: .float32)
        for offset in stride(from: 0, to: chunk.count, by: 4096) {
            try Task.checkCancellation()
            let packet = Array(chunk[offset..<min(offset + 4096, chunk.count)])
            try emitter.yield(
                .audio(
                    AudioFrame(
                        data: packet.withUnsafeBytes { Data($0) }, format: format,
                        sequence: sequence, timestamp: Double(samples) / 24_000)))
            sequence += 1
            samples += packet.count
        }
    }
}
