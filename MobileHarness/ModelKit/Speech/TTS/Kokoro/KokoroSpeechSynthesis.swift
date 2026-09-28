import Foundation
import ModelKit
import ModelKitFluidAudio
import Synchronization

#if canImport(CoreML)
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
                    return try await KokoroModel(artifacts: artifacts)
                #endif
            }
        }

        public var availability: CapabilityAvailability {
            #if targetEnvironment(simulator) || !arch(arm64)
                .unavailable(reason: "Kokoro requires physical Apple Silicon hardware")
            #else
                do {
                    try LocalKokoroEngine.validateResources(at: root)
                    return .available
                } catch { return .unavailable(reason: "Kokoro Core ML resources are missing or incompatible") }
            #endif
        }

        /// One request, no pending queue. Finished audio is bounded to 60 seconds per request.
        public func synthesize(_ request: SpeechSynthesisRequest) async throws -> InferenceSession<SynthesisEvent> {
            try Task.checkCancellation()
            let segments = try KokoroInput.segments(text: request.text, locale: request.locale)
            if let previous = worker, previous.task.isCancelled { await previous.task.value }
            try Task.checkCancellation()
            guard worker == nil else { throw CapabilityError.inputBusy }
            let id = UUID()
            let cancellation = KokoroCancellation()
            let pair = InferenceSession<SynthesisEvent>.make(
                context: request.context,
                limits: try StreamLimits(capacity: 8, maximumEventBytes: 16_448),
                estimatedBytes: { $0.estimatedBytes },
                onTermination: { termination in
                    if case .finished = termination { return }
                    cancellation.cancel()
                })
            let resource = resource
            let emitter = pair.emitter
            let task = Task.detached { [weak self] in
                defer { cancellation.finish() }
                do {
                    let lease = try await resource.acquire()
                    await resource.setCancellation(lease.id) { cancellation.cancel() }
                    do {
                        try Task.checkCancellation()
                        let sink = KokoroPCMEmitter(emitter: emitter)
                        try await lease.model.synthesizeChunks(segments) { try await sink.emit($0) }
                        try Task.checkCancellation()
                        await resource.release(lease.id)
                    } catch {
                        await resource.release(lease.id)
                        throw error
                    }
                    await self?.completed(id)
                    try await emitter.yieldSuspending(.finished)
                    emitter.finish()
                } catch {
                    await self?.completed(id)
                    emitter.fail(error)
                }
            }
            worker = (id, task)
            cancellation.install(task)
            return pair.session
        }

        private func completed(_ id: UUID) { if worker?.id == id { worker = nil } }

    }
#else
    public actor KokoroSpeechSynthesis: SpeechSynthesisCapability {
        public init(context: ModelContext, artifacts: URL) throws {
            let _: ModelResource<Void> = try context.resource {
                throw CapabilityError.unavailable("Kokoro requires Core ML on Apple Silicon")
            }
        }
        public var availability: CapabilityAvailability {
            .unavailable(reason: "Kokoro requires Core ML on Apple Silicon")
        }
        public func synthesize(_ request: SpeechSynthesisRequest) async throws -> InferenceSession<SynthesisEvent> {
            throw CapabilityError.unavailable("Kokoro requires Core ML on Apple Silicon")
        }
    }
#endif

private actor KokoroPCMEmitter {
    let emitter: InferenceEmitter<SynthesisEvent>
    var samples = 0
    var sequence: UInt64 = 0
    init(emitter: InferenceEmitter<SynthesisEvent>) { self.emitter = emitter }
    func emit(_ chunk: [Float]) async throws {
        guard !chunk.isEmpty, chunk.count <= 24_000 * 60 - samples else { throw CapabilityError.eventTooLarge }
        let format = try AudioFormat(sampleRate: 24_000, channels: 1, encoding: .float32)
        for offset in stride(from: 0, to: chunk.count, by: 4096) {
            try Task.checkCancellation()
            let packet = Array(chunk[offset..<min(offset + 4096, chunk.count)])
            try await emitter.yieldSuspending(
                .audio(
                    AudioFrame(
                        data: packet.withUnsafeBytes { Data($0) }, format: format,
                        sequence: sequence, timestamp: Double(samples) / 24_000)))
            sequence += 1
            samples += packet.count
        }
    }
}

/// Cancellation reaches the worker synchronously, including cancellation before task installation.
private final class KokoroCancellation: Sendable {
    private let state = Mutex((task: Optional<Task<Void, Never>>.none, cancelled: false))
    func install(_ task: Task<Void, Never>) {
        let cancelled = state.withLock { value in
            value.task = task
            return value.cancelled
        }
        if cancelled { task.cancel() }
    }
    func finish() { state.withLock { $0.task = nil } }
    func cancel() {
        let task = state.withLock { value in
            value.cancelled = true
            return value.task
        }
        task?.cancel()
    }
}
