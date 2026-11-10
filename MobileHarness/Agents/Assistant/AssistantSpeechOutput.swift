import AgentCore
import Foundation
import ModelKit
import StorageCache
import UI

/// Assistant-owned FIFO producer; playback and other Actions run independently.
actor AssistantSpeechOutput: AgentSpeechOutput {
    struct Snapshot: Sendable {
        let installed: Bool
        let queued: Int
        let processed: Int
        let presentationFailure: String?
    }
    private struct Binding: Sendable {
        let id = UUID()
        let synthesis: any SpeechSynthesisCapability
        let store: AudioCache
    }
    private struct Job: Sendable {
        let id: String
        let text: String
        let input: AgentInput
        let binding: Binding
    }
    private struct InputScope: Hashable {
        let session: String
        let input: String
        init(_ value: AgentInput) {
            session = value.sessionID
            input = value.id
        }
    }
    private var binding: Binding?
    private var closed = false
    private var ending: Task<Void, Never>?
    private var admissions: [String: (scope: InputScope, task: Task<String, Error>)] = [:]
    private var cancellingInputs: [InputScope: Int] = [:]
    private var handles: [String: Job] = [:]
    private var queue: [Job] = []
    private var worker: Task<Void, Never>?
    private var active: String?
    private var activeScope: InputScope?
    private var processed = 0
    private var playing: String?
    private let island = AgentIslandPublication()

    func configure(synthesis: any SpeechSynthesisCapability, store: AudioCache) throws {
        guard !closed else { throw HarnessError.notRunning }
        guard binding == nil, ending == nil else { throw HarnessError.invalidTransition }
        binding = Binding(synthesis: synthesis, store: store)
    }
    func bindPresentation(_ consumer: GatewayOutputConsumer) async {
        await island.bind(consumer: consumer, source: .assistant)
        await island.start()
    }
    func snapshot() async -> Snapshot {
        var pending = Set(queue.map(\.id)).union(admissions.keys)
        if let active { pending.remove(active) }
        return Snapshot(
            installed: binding != nil, queued: pending.count,
            processed: processed, presentationFailure: await island.lastFailure)
    }
    func playbackChanged(audioID: String, active: Bool) async {
        guard !closed, binding != nil else { return }
        if active { playing = audioID } else if playing == audioID { playing = nil }
        await refreshIsland()
    }
    private func refreshIsland() async {
        let content: IslandContent?
        if closed || binding == nil {
            content = nil
        } else if playing != nil {
            content = .init(
                title: "正在说话", primary: .symbol(name: "speaker.wave.2.fill"),
                tone: .blue, priority: .high, secondary: .spectrum)
        } else if active != nil {
            content = .init(title: "正在合成语音", primary: .symbol(name: "waveform"), priority: .low, secondary: .loading)
        } else {
            content = nil
        }
        await island.submit(content)
    }
    func prepare(text: String, input: AgentInput) async throws -> String {
        try Task.checkCancellation()
        try Self.validate(text: text)
        guard !closed, let binding else { throw HarnessError.notRunning }
        guard cancellingInputs[InputScope(input)] == nil else { throw CancellationError() }
        guard handles.count + admissions.keys.filter({ handles[$0] == nil }).count < 32 else {
            throw HarnessError.queueFull
        }
        let job = Job(id: UUID().uuidString, text: text, input: input, binding: binding)
        let task = Task { try await admit(job) }
        admissions[job.id] = (InputScope(input), task)
        defer { admissions[job.id] = nil }
        return try await withTaskCancellationHandler {
            let id = try await task.value
            do { try Task.checkCancellation() } catch {
                await job.binding.store.fail(id, error: error)
                throw error
            }
            return id
        } onCancel: {
            task.cancel()
        }
    }
    static func validate(text: String) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 2000 else {
            throw SpeechValidationError.invalidRequest
        }
    }
    private func owner(_ input: AgentInput) -> AudioCache.Owner {
        .init(source: "assistant", session: input.sessionID, input: input.id)
    }
    private func admit(_ job: Job) async throws -> String {
        try Task.checkCancellation()
        try await job.binding.store.register(job.id, owner: owner(job.input)) { [weak self] in
            await self?.cancelJob(job.id)
        }
        handles[job.id] = job
        do {
            try await job.binding.store.validate(job.id, owner: owner(job.input))
            try Task.checkCancellation()
            guard binding?.id == job.binding.id, !closed, cancellingInputs[InputScope(job.input)] == nil else {
                throw CancellationError()
            }
            queue.append(job)
            drain()
            return job.id
        } catch {
            handles[job.id] = nil
            await job.binding.store.fail(job.id, error: error)
            throw error
        }
    }
    func cancel(audioID: String, input: AgentInput) async throws {
        guard let binding else { throw HarnessError.notRunning }
        try await binding.store.cancel(audioID, owner: owner(input))
    }
    func cancel(input: AgentInput) async {
        let scope = InputScope(input)
        let pending = admissions.values.filter { $0.scope == scope }.map(\.task)
        guard
            !pending.isEmpty || activeScope == scope
                || handles.values.contains(where: { InputScope($0.input) == scope })
        else {
            return
        }
        cancellingInputs[scope, default: 0] += 1
        let producer = activeScope == scope ? worker : nil
        producer?.cancel()
        for task in pending { task.cancel() }
        for task in pending { _ = await task.result }
        let owned = handles.values.filter { InputScope($0.input) == scope }
        for job in owned { await job.binding.store.fail(job.id, error: CancellationError()) }
        await producer?.value
        if let count = cancellingInputs[scope], count > 1 {
            cancellingInputs[scope] = count - 1
        } else {
            cancellingInputs[scope] = nil
        }
        drain()
    }
    private func cancelJob(_ id: String) async {
        handles[id] = nil
        queue.removeAll { $0.id == id }
        if active == id {
            let pending = worker
            pending?.cancel()
            if AssistantSpeechFailureContext.audioID != id { await pending?.value }
        }
    }
    private func drain() {
        guard !closed, binding != nil, worker == nil, !queue.isEmpty else { return }
        guard cancellingInputs[InputScope(queue[0].input)] == nil else { return }
        let job = queue.removeFirst()
        active = job.id
        activeScope = InputScope(job.input)
        worker = Task { await produce(job) }
    }
    private func produce(_ job: Job) async {
        await refreshIsland()
        do {
            try Task.checkCancellation()
            let audio = try await job.binding.store.begin(job.id)
            let request = try SpeechSynthesisRequest(
                text: job.text, locale: "auto", context: .init(requestID: job.id, scopeID: job.input.sessionID))
            let session = try await job.binding.synthesis.synthesize(request)
            try await session.withCleanup {
                guard session.context == request.context else { throw SpeechSynthesisError.invalidOutput }
                var finished = false
                var bytes = 0
                var format: ModelKit.AudioFormat?
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
                            try await audio.append(
                                StorageCache.AudioFrame(
                                    data: frame.data,
                                    format: .init(sampleRate: frame.format.sampleRate, channels: 1, encoding: .float32),
                                    sequence: frame.sequence, timestamp: frame.timestamp))
                        case .finished: finished = true
                        }
                    }
                } onCancel: {
                    session.cancel()
                }
                try Task.checkCancellation()
                guard finished, bytes > 0 else { throw SpeechSynthesisError.invalidOutput }
            }
            try Task.checkCancellation()
            await job.binding.store.complete(job.id)
        } catch {
            await AssistantSpeechFailureContext.$audioID.withValue(job.id) {
                await job.binding.store.fail(job.id, error: error)
            }
        }
        active = nil
        activeScope = nil
        await refreshIsland()
        worker = nil
        processed += 1
        drain()
    }
    func endSession() async {
        if let ending { return await ending.value }
        let previous = binding
        binding = nil
        let pending = admissions.values.map(\.task)
        for task in pending { task.cancel() }
        queue.removeAll()
        let producer = worker
        producer?.cancel()
        let task = Task {
            for task in pending { _ = await task.result }
            admissions.removeAll()
            await previous?.store.shutdown()
            await producer?.value
            handles.removeAll()
            playing = nil
            await refreshIsland()
        }
        ending = task
        await task.value
        ending = nil
    }
    func stop() async {
        closed = true
        await endSession()
        await island.stop()
    }
}

public enum SpeechValidationError: Error, Equatable, Sendable { case invalidRequest }
public enum SpeechSynthesisError: Error, Equatable, Sendable { case invalidOutput }
private enum AssistantSpeechFailureContext { @TaskLocal static var audioID: String? }
