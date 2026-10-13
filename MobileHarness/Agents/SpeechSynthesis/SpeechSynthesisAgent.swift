import AgentCore
import Foundation
import ModelKit
import StorageAudio

/// Shared directed synthesis service. One FIFO worker, independent of playback Channels.
public actor SpeechSynthesisAgent: Agent {

    // MARK: - Interface

    public nonisolated let descriptor: AgentDescriptor
    public nonisolated let outputs: AsyncStream<OutputEnvelope>

    // MARK: - State and dependencies

    private let contextRepository: AgentContextRepository<SpeechSynthesisContextState>
    private let preprocessor = SpeechSynthesisSignalPreprocessor()
    private let contextBuilder = SpeechSynthesisContextBuilder()

    private let continuation: AsyncStream<OutputEnvelope>.Continuation
    private let synthesis: any SpeechSynthesisCapability
    private let store: SpeechAudioStore
    private var lifecycle: AgentLifecycle = .registered
    private var queue: [(SpeechSynthesisInput, AgentInput)] = []
    private var admitting = 0
    private var worker: Task<Void, Never>?
    private var active: UUID?
    private var processed = 0

    // MARK: - Registration

    public init(
        synthesis: any SpeechSynthesisCapability, store: SpeechAudioStore,
        configuration: AgentConfiguration? = nil,
        context: AgentContextRepository<SpeechSynthesisContextState>? = nil
    ) throws {
        self.contextRepository =
            context
            ?? AgentContextRepository(
                agent: AgentID(rawValue: "speechSynthesis"), scope: UUID(), state: SpeechSynthesisContextState())
        guard contextRepository.agentID.rawValue == "speechSynthesis" else {
            throw AgentConfigurationError.identityMismatch
        }
        let config = try configuration ?? AgentConfigurations.load(named: "SpeechSynthesis")
        guard config.agentID.rawValue == "speechSynthesis" else { throw AgentConfigurationError.identityMismatch }
        descriptor = AgentDescriptor(
            id: config.agentID, name: "Speech Synthesis",
            inputs: Set(config.communication.inputs.map(\.kind)), outputs: [], capabilities: config.capabilities)
        self.synthesis = synthesis
        self.store = store
        let stream = AsyncStream<OutputEnvelope>.makeStream(
            bufferingPolicy: .bufferingOldest(SpeechSynthesisSignalPreprocessor.outputCapacity))
        outputs = stream.stream
        continuation = stream.continuation
    }

    // MARK: - Lifecycle

    public func start() async throws {
        guard lifecycle == .registered else { throw HarnessError.invalidTransition }
        _ = try await contextRepository.snapshot()
        lifecycle = .running
    }
    public func pause() throws {
        guard lifecycle == .running else { throw HarnessError.invalidTransition }
        lifecycle = .paused
    }
    public func resume() throws {
        guard lifecycle == .paused else { throw HarnessError.invalidTransition }
        lifecycle = .running
        drain()
    }
    public func stop() async {
        lifecycle = .stopped
        let ids = queue.map { $0.0.audioID } + (active.map { [$0] } ?? [])
        queue.removeAll()
        let pending = worker
        pending?.cancel()
        for id in ids { await store.fail(id, error: CancellationError()) }
        await pending?.value
        continuation.finish()
    }

    // MARK: - Input processing

    public func receive(_ input: AgentInput) async throws {
        guard lifecycle == .running || lifecycle == .paused else { throw HarnessError.notRunning }
        guard !input.metadata.expired else { throw CommunicationError.expired }
        let owner = SpeechAudioStore.Owner(
            source: input.metadata.source,
            session: input.sessionID, input: input.metadata.parentID ?? input.id)
        if case .cancelSpeech(let id)? = input.payload.perception {
            try await store.validate(id, owner: owner)
            try await prepareSignal(input)
            try await store.cancel(id, owner: owner)
            return
        }
        guard case .speechSynthesis(let request)? = input.payload.perception else {
            throw HarnessError.unsupportedInput
        }
        do { try request.validate() } catch { throw CommunicationError.invalidPayload }
        guard queue.count + admitting < SpeechSynthesisSignalPreprocessor.inputCapacity else {
            throw HarnessError.queueFull
        }
        admitting += 1
        defer { admitting -= 1 }
        try await prepareSignal(input)
        do {
            try await store.register(request.audioID, owner: owner) { [weak self] in
                await self?.cancelJob(request.audioID)
            }
            guard !Task.isCancelled, lifecycle == .running || lifecycle == .paused else { throw CancellationError() }
            queue.append((request, input))
            drain()
        } catch {
            await store.fail(request.audioID, error: error)
            let failure = Data(String(describing: error).prefix(512).utf8)
            try await contextRepository.update {
                $0.state.pendingAudioIDs.removeAll { $0 == request.audioID }
                try $0.append(
                    .init(
                        taskID: input.taskScope?.id ?? input.id,
                        kind: "speech.synthesis.rejected", data: failure),
                    retainingLast: SpeechSynthesisSignalPreprocessor.evidenceCapacity)
            }
            throw error
        }
    }

    // MARK: - Decision workers

    private func cancelJob(_ id: UUID) async {
        queue.removeAll { $0.0.audioID == id }
        if active == id {
            let pending = worker
            pending?.cancel()
            if SpeechSynthesisFailureContext.audioID != id { await pending?.value }
        }
    }
    private func drain() {
        guard lifecycle == .running, worker == nil, !queue.isEmpty else { return }
        let (request, input) = queue.removeFirst()
        active = request.audioID
        worker = Task { await produce(request, input: input) }
    }
    private func produce(_ request: SpeechSynthesisInput, input: AgentInput) async {
        defer {
            worker = nil
            active = nil
            processed += 1
            drain()
        }
        do {
            let audio = try await store.begin(request.audioID)
            try Task.checkCancellation()
            let selection = AgentDecisionContext(snapshot: try await contextRepository.snapshot(), input: input)
            let decision = try contextBuilder.build(state: selection, batch: selection.batch())
            let inference = try decision.inferenceRequest()
            let context = inference.context
            try await contextRepository.update {
                $0.state.activeAudioID = request.audioID
                $0.state.pendingAudioIDs.removeAll { $0 == request.audioID }
            }
            let session = try await synthesis.synthesize(inference)
            defer { session.cancel() }
            guard session.context == context else { throw SpeechSynthesisError.invalidOutput }
            var finished = false
            var bytes = 0
            var format: AudioFormat?
            var sequence: UInt64?
            try await withTaskCancellationHandler {
                for try await event in session.events {
                    try Task.checkCancellation()
                    guard !finished else { throw SpeechSynthesisError.invalidOutput }
                    switch event {
                    case .audio(let frame):
                        guard frame.format.channels == 1, frame.format.encoding == .float32,
                            format == nil || format == frame.format,
                            sequence.map({ frame.sequence > $0 }) ?? true,
                            frame.data.count <= 8_388_608 - bytes
                        else { throw SpeechSynthesisError.invalidOutput }
                        format = frame.format
                        sequence = frame.sequence
                        bytes += frame.data.count
                        let storedFormat = try SpeechPCMFormat(
                            sampleRate: frame.format.sampleRate, channels: frame.format.channels,
                            encoding: frame.format.encoding == .float32 ? .float32 : .signedInt16)
                        try await audio.append(
                            SpeechPCMFrame(
                                data: frame.data, format: storedFormat, sequence: frame.sequence,
                                timestamp: frame.timestamp))
                    case .finished: finished = true
                    }
                }
            } onCancel: {
                session.cancel()
            }
            guard finished, bytes > 0 else { throw SpeechSynthesisError.invalidOutput }
            try await contextRepository.update {
                $0.state.activeAudioID = nil
                try $0.append(
                    .init(taskID: input.taskScope?.id ?? input.id, kind: "speech.synthesis.completed"),
                    retainingLast: SpeechSynthesisSignalPreprocessor.evidenceCapacity)
            }
            await store.complete(request.audioID)
        } catch {
            await SpeechSynthesisFailureContext.$audioID.withValue(request.audioID) {
                await store.fail(request.audioID, error: error)
            }
            do {
                try await contextRepository.update {
                    $0.state.activeAudioID = nil
                    $0.state.pendingAudioIDs.removeAll { $0 == request.audioID }
                    try $0.append(
                        .init(
                            taskID: input.taskScope?.id ?? input.id, kind: "speech.synthesis.failed",
                            data: Data(String(describing: error).prefix(512).utf8)),
                        retainingLast: SpeechSynthesisSignalPreprocessor.evidenceCapacity)
                }
            } catch {
                lifecycle = .failed
                continuation.finish()
            }
        }
    }

    // MARK: - Context

    private func prepareSignal(_ input: AgentInput) async throws {
        let snapshot = try await contextRepository.snapshot()
        let disposition = try preprocessor.classify(input, state: snapshot.state)
        if input.payload.kind == .audio || input.payload.kind == .image { return }
        if case .replaceLatest = disposition { return }
        try await contextRepository.recordSignal(
            input, disposition: disposition, admissionSequence: snapshot.revision + 1,
            consumed: disposition != .feedback, retainingLast: SpeechSynthesisSignalPreprocessor.evidenceCapacity
        ) { context in
            if case .speechSynthesis(let job)? = input.payload.perception {
                guard context.state.pendingAudioIDs.count < SpeechSynthesisSignalPreprocessor.inputCapacity else {
                    throw CommunicationError.capacityExceeded
                }
                context.state.pendingAudioIDs.append(job.audioID)
            } else if case .cancelSpeech(let id)? = input.payload.perception {
                context.state.pendingAudioIDs.removeAll { $0 == id }
            }
        }
    }

    // MARK: - Observability

    public func status() -> AgentStatus {
        AgentStatus(lifecycle: lifecycle, queuedInputs: queue.count, processedInputs: processed)
    }

    public func contextSnapshot() async throws -> AgentContext<SpeechSynthesisContextState> {
        try await contextRepository.snapshot()
    }
}

// MARK: - Producer failures

/// Producer failures, independent of storage format and lease errors.
public enum SpeechSynthesisError: Error, Equatable, Sendable {
    case invalidOutput
}

// A producer must not join itself when its failure closes the registered audio handle.
enum SpeechSynthesisFailureContext { @TaskLocal static var audioID: UUID? }
