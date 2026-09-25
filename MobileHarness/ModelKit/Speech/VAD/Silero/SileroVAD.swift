// Streaming tensor contract follows hugging-mac models/silero/coreml.py (MIT).
// Reference commit: 60b176843703fd730a04e2b537212fba92b399a3. See docs/licenses/Hugging-Mac-MIT.txt.
import Foundation
import ModelKit
import ModelKitCoreML

public actor SileroVAD: VoiceActivityCapability {

    private let root: URL
    private let resource: ModelResource<CoreMLGraph>
    public init(context: ModelContext, artifacts: URL) throws {
        root = artifacts
        resource = try context.resource {
            return try await CoreMLGraph(contentsOf: artifacts.appendingPathComponent("silero_vad.mlmodelc"))
        }
    }
    public var availability: CapabilityAvailability {
        FileManager.default.fileExists(atPath: root.appendingPathComponent("silero_vad.mlmodelc").path)
            ? .available : .unavailable(reason: "Silero 模型制品未安装")
    }
    public func detectVoiceActivity(format: AudioFormat) async throws -> any VoiceActivitySession {
        guard format.sampleRate == 16000, format.channels == 1, format.encoding == .float32 else {
            throw CapabilityError.invalidRequest("Silero requires 16 kHz mono Float32 PCM")
        }
        let lease = try await resource.acquire()
        let resource = resource
        let id = lease.id
        let session = SileroSession(graph: lease.model, format: format) { await resource.release(id) }
        await resource.setCancellation(id) { [weak session] in Task { await session?.cancel() } }
        return session
    }
}

private actor SileroSession: VoiceActivitySession {
    private var graph: CoreMLGraph?
    private let format: AudioFormat
    private let release: @Sendable () async -> Void
    private var h = [Float](repeating: 0, count: 128)
    private var c = [Float](repeating: 0, count: 128)
    private var context = [Float](repeating: 0, count: 64)
    private var pending: [Float] = []
    private var position: Int64 = 0
    private var lastSequence: UInt64?
    private var lastTimestamp: TimeInterval?
    private var closed = false
    private var busy = false
    private var stopWaiter: CheckedContinuation<Void, Never>?

    init(graph: CoreMLGraph, format: AudioFormat, release: @escaping @Sendable () async -> Void) {
        self.graph = graph
        self.format = format
        self.release = release
    }
    deinit {
        let release = release
        Task { await release() }
    }
    func process(_ frame: AudioFrame) async throws -> [VoiceActivityScore] {
        guard !closed else { throw CapabilityError.sessionClosed }
        guard !busy else { throw CapabilityError.inputBusy }
        guard frame.format == format, frame.sampleCount <= 16000,
            lastSequence.map({ frame.sequence > $0 }) ?? true,
            lastTimestamp.map({ frame.timestamp >= $0 }) ?? true
        else { throw CapabilityError.invalidRequest("VAD format, size or input order mismatch") }
        let samples = frame.data.withUnsafeBytes { data in
            (0..<frame.sampleCount).map { data.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self) }
        }
        guard samples.allSatisfy(\.isFinite) else { throw CapabilityError.invalidRequest("Non-finite PCM") }
        busy = true
        do {
            try Task.checkCancellation()
            pending.append(contentsOf: samples)
            var scores: [VoiceActivityScore] = []
            var consumed = 0
            while pending.count - consumed >= 512 {
                scores.append(try await evaluate(Array(pending[consumed..<consumed + 512]), count: 512))
                consumed += 512
            }
            pending.removeFirst(consumed)
            lastSequence = frame.sequence
            lastTimestamp = frame.timestamp
            completeOperation()
            return scores
        } catch {
            completeOperation()
            await cancel()
            throw error
        }
    }
    private func evaluate(_ samples: [Float], count: Int) async throws -> VoiceActivityScore {
        try Task.checkCancellation()
        guard !closed, let graph else { throw CancellationError() }
        let outputs = try await graph.run([
            "audio": CoreMLTensor(shape: [1, 1, 576], values: context + samples),
            "h": CoreMLTensor(shape: [1, 1, 128], values: h),
            "c": CoreMLTensor(shape: [1, 1, 128], values: c),
        ])
        guard !closed else { throw CancellationError() }
        try Task.checkCancellation()
        guard let probability = outputs["probability"], probability.shape == [1],
            let nextH = outputs["h_out"], nextH.shape == [1, 1, 128],
            let nextC = outputs["c_out"], nextC.shape == [1, 1, 128],
            position <= Int64.max - Int64(count)
        else { throw CapabilityError.invalidRequest("Unexpected Silero output") }
        let score = try VoiceActivityScore(
            startSample: position, sampleCount: count, probability: probability.values[0])
        h = nextH.values
        c = nextC.values
        context = Array(samples.suffix(64))
        position += Int64(count)
        return score
    }
    func finish() async throws -> [VoiceActivityScore] {
        guard !closed else { throw CapabilityError.sessionClosed }
        guard !busy else { throw CapabilityError.inputBusy }
        busy = true
        do {
            var scores: [VoiceActivityScore] = []
            if !pending.isEmpty {
                let count = pending.count
                scores = [try await evaluate(pending + Array(repeating: 0, count: 512 - count), count: count)]
            }
            completeOperation()
            await cancel()
            return scores
        } catch {
            completeOperation()
            await cancel()
            throw error
        }
    }
    func reset() throws {
        guard !closed else { throw CapabilityError.sessionClosed }
        guard !busy else { throw CapabilityError.inputBusy }
        h = Array(repeating: 0, count: 128)
        c = h
        context = Array(repeating: 0, count: 64)
        pending.removeAll(keepingCapacity: true)
        position = 0
        lastSequence = nil
        lastTimestamp = nil
    }
    private func completeOperation() {
        busy = false
        stopWaiter?.resume()
        stopWaiter = nil
    }
    func cancel() async {
        guard !closed else { return }
        closed = true
        if busy { await withCheckedContinuation { stopWaiter = $0 } }
        pending.removeAll()
        graph = nil
        await release()
    }
}
