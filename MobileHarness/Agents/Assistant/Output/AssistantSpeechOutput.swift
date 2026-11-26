import AgentCore
import Foundation
import ModelKit
import StorageCache
import Synchronization
import UI

/// One decoded speak Action. Only its last PCM packet per unit can confirm that unit.
public final class AssistantSpeechProgress: Sendable {
    let units: [String]
    private let completions: Mutex<[ContinuousClock.Instant?]>

    init(_ text: String) throws {
        units = try TextSegmentationPolicy.sentences.segments(in: text)
        completions = Mutex(Array(repeating: nil, count: units.count))
    }

    func played(_ unit: Int, at instant: ContinuousClock.Instant) {
        completions.withLock { if $0[unit] == nil { $0[unit] = instant } }
    }

    func completedUnits(at cutoff: ContinuousClock.Instant) -> Int {
        completions.withLock { $0.prefix { $0.map { $0 <= cutoff } ?? false }.count }
    }
}

/// Assistant-owned FIFO producer; playback and other Actions run independently.
actor AssistantSpeechOutput: AssistantSpeechProducing {
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
        let progress: AssistantSpeechProgress?
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
    private var nativePlayback: [String: InputScope] = [:]
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
    func preparePlayback(audioID: String) throws {
        guard let job = handles[audioID], !closed, binding?.id == job.binding.id else {
            throw CancellationError()
        }
        let scope = InputScope(job.input)
        guard cancellingInputs[scope] == nil, nativePlayback[audioID] == nil else { throw CancellationError() }
        guard nativePlayback.count < 32 else { throw HarnessError.queueFull }
        nativePlayback[audioID] = scope
    }
    func playbackChanged(audioID: String, active: Bool) async {
        guard !closed, binding != nil, nativePlayback[audioID] != nil else { return }
        if active {
            playing = audioID
        } else {
            if playing == audioID { playing = nil }
            nativePlayback[audioID] = nil
        }
        await refreshIsland()
    }
    func isPlaying(sessionID: String) async -> Bool? {
        guard !closed, binding != nil else { return nil }
        guard let playing else { return false }
        return nativePlayback[playing]?.session == sessionID
    }
    private func refreshIsland() async {
        let content: IslandContent?
        if closed || binding == nil {
            content = nil
        } else if playing != nil {
            content = .init(
                title: "Speaking", primary: .symbol(name: "speaker.wave.2.fill"),
                tone: .blue, priority: .high, secondary: .spectrum, localizedLabels: true)
        } else if active != nil {
            content = .init(
                title: "Synthesizing speech", primary: .symbol(name: "waveform"), priority: .low,
                secondary: .loading, localizedLabels: true)
        } else {
            content = nil
        }
        await island.submit(content)
    }
    func prepare(text: String, input: AgentInput) async throws -> String {
        try await prepare(text: text, input: input, tracking: nil)
    }
    func prepare(text: String, input: AgentInput, tracking: AssistantSpeechProgress?) async throws -> String {
        try Task.checkCancellation()
        try Self.validate(text: text)
        guard !closed, let binding else { throw HarnessError.notRunning }
        guard cancellingInputs[InputScope(input)] == nil else { throw CancellationError() }
        guard handles.count + admissions.keys.filter({ handles[$0] == nil }).count < 32 else {
            throw HarnessError.queueFull
        }
        let job = Job(id: UUID().uuidString, text: text, input: input, binding: binding, progress: tracking)
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
            try await synthesize(job, into: audio)
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

    private struct PCMProgress: Sendable {
        var bytes = 0
        var format: StorageCache.AudioFormat?
        var sequence: UInt64 = 0
    }

    private func synthesize(_ job: Job, into audio: AudioStream) async throws {
        var streamProgress = PCMProgress()
        let units = job.progress?.units ?? [job.text]
        let joinedStream = units.count > 1
        for (index, unit) in units.enumerated() {
            try Task.checkCancellation()
            let request = try SpeechSynthesisRequest(
                text: unit, locale: "auto",
                context: .init(requestID: index == 0 ? job.id : "\(job.id).\(index)", scopeID: job.input.sessionID))
            let session = try await job.binding.synthesis.synthesize(request)
            let initial = streamProgress
            streamProgress = try await session.withCleanup {
                guard session.context == request.context else { throw SpeechSynthesisError.invalidOutput }
                var stream = initial
                var finished = false
                var received: UInt64?
                var tail: StorageCache.AudioFrame?
                try await withTaskCancellationHandler {
                    for try await event in session.events {
                        try Task.checkCancellation()
                        guard !finished else { throw SpeechSynthesisError.invalidOutput }
                        switch event {
                        case .audio(let frame):
                            guard frame.format.channels == 1, frame.format.encoding == .float32,
                                received.map({ frame.sequence > $0 }) ?? true,
                                frame.data.count <= 8_388_608 - stream.bytes
                            else { throw SpeechSynthesisError.invalidOutput }
                            let pcmFormat = try StorageCache.AudioFormat(
                                sampleRate: frame.format.sampleRate, channels: 1, encoding: .float32)
                            guard stream.format == nil || stream.format == pcmFormat else {
                                throw SpeechSynthesisError.invalidOutput
                            }
                            if let tail { try await audio.append(tail) }
                            let pcm = try StorageCache.AudioFrame(
                                data: frame.data, format: pcmFormat,
                                sequence: joinedStream ? stream.sequence : frame.sequence,
                                timestamp: joinedStream
                                    ? Double(stream.bytes / 4) / Double(pcmFormat.sampleRate) : frame.timestamp)
                            if job.progress == nil {
                                try await audio.append(pcm)
                            } else {
                                tail = pcm
                            }
                            stream.format = pcmFormat
                            received = frame.sequence
                            stream.sequence += 1
                            stream.bytes += frame.data.count
                        case .finished: finished = true
                        }
                    }
                    try Task.checkCancellation()
                    guard finished, received != nil else { throw SpeechSynthesisError.invalidOutput }
                    if let tail, let progress = job.progress {
                        try await audio.append(tail) { progress.played(index, at: $0) }
                    }
                } onCancel: {
                    session.cancel()
                }
                return stream
            }
        }
    }
    func endSession() async {
        if let ending { return await ending.value }
        let previous = binding
        binding = nil
        nativePlayback.removeAll()
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

/// A role-owned text-to-audio boundary. Admission reserves a handle, not audible completion.
public protocol AssistantSpeechProducing: Sendable {
    func isPlaying(sessionID: String) async -> Bool?
    func prepare(text: String, input: AgentInput) async throws -> String
    func prepare(text: String, input: AgentInput, tracking: AssistantSpeechProgress?) async throws -> String
    func cancel(audioID: String, input: AgentInput) async throws
    func cancel(input: AgentInput) async
    func stop() async
}

extension AssistantSpeechProducing {
    public func isPlaying(sessionID: String) async -> Bool? { nil }
    public func prepare(text: String, input: AgentInput, tracking: AssistantSpeechProgress?) async throws -> String {
        try await prepare(text: text, input: input)
    }
}
