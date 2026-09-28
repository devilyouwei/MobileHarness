import Foundation
import ModelKit
import ModelKitMossCoreML
import Synchronization

#if canImport(CoreML)
    @available(iOS 27, macOS 27, *)
    public actor MossSpeechSynthesis: SpeechSynthesisCapability {

        private let resource: ModelResource<LocalMossEngine>
        private let root: URL
        private var worker: (id: UUID, task: Task<Void, Never>)?

        public init(context: ModelContext, artifacts: URL) throws {
            root = artifacts
            resource = try context.resource {
                #if targetEnvironment(simulator) || !arch(arm64)
                    throw CapabilityError.unavailable("MOSS-TTS-Nano requires physical Apple Silicon hardware")
                #else
                    return try LocalMossEngine(root: artifacts)
                #endif
            }
        }

        public var availability: CapabilityAvailability {
            #if targetEnvironment(simulator) || !arch(arm64)
                .unavailable(reason: "MOSS-TTS-Nano requires physical Apple Silicon hardware")
            #else
                do {
                    try LocalMossEngine.validateResources(at: root)
                    return .available
                } catch { return .unavailable(reason: "MOSS-TTS-Nano Core ML resources are missing or incompatible") }
            #endif
        }

        /// One request, no pending queue. Finished audio is bounded to 60 seconds per request.
        public func synthesize(_ request: SpeechSynthesisRequest) async throws -> InferenceSession<SynthesisEvent> {
            try Task.checkCancellation()
            let chineseVoice = try MossInput.chineseVoice(text: request.text, locale: request.locale)
            if let previous = worker, previous.task.isCancelled { await previous.task.value }
            try Task.checkCancellation()
            guard worker == nil else { throw CapabilityError.inputBusy }
            let id = UUID()
            let cancellation = MossCancellation()
            let pair = InferenceSession<SynthesisEvent>.make(
                context: request.context,
                limits: try StreamLimits(capacity: 256, maximumEventBytes: 16_448),
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
                        let sink = Mutex(MossPCMEncoder())
                        try await lease.model.synthesize(text: request.text, chineseVoice: chineseVoice) {
                            left, right in
                            try sink.withLock { encoder in
                                for frame in try encoder.encode(left: left, right: right) {
                                    try emitter.yield(.audio(frame))
                                }
                            }
                        }
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
    public actor MossSpeechSynthesis: SpeechSynthesisCapability {
        public init(context: ModelContext, artifacts: URL) throws {
            let _: ModelResource<Void> = try context.resource {
                throw CapabilityError.unavailable("MOSS-TTS-Nano requires Core ML on Apple Silicon")
            }
        }
        public var availability: CapabilityAvailability {
            .unavailable(reason: "MOSS-TTS-Nano requires Core ML on Apple Silicon")
        }
        public func synthesize(_ request: SpeechSynthesisRequest) async throws -> InferenceSession<SynthesisEvent> {
            throw CapabilityError.unavailable("MOSS-TTS-Nano requires Core ML on Apple Silicon")
        }
    }
#endif

/// Cancellation reaches the worker synchronously, including cancellation before task installation.
private final class MossCancellation: Sendable {
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

@available(iOS 27, macOS 27, *)
extension MossSpeechSynthesis {
    /// Exercise lazy Core ML kernels before conversation playback starts its first-audio timer.
    /// The synthetic PCM is consumed in memory and never sent to a speaker or Agent.
    public func warmup() async throws {
        let session = try await synthesize(SpeechSynthesisRequest(text: "你好。", locale: "zh-CN"))
        defer { session.cancel() }
        var hasAudio = false
        var finished = false
        for try await event in session.events {
            switch event {
            case .audio: hasAudio = true
            case .finished: finished = true
            }
        }
        guard hasAudio, finished else { throw CapabilityError.unavailable("MOSS warmup produced no audio") }
    }
}
