import Foundation
import ModelKit

/// Lightweight acoustic activity detector, not a learned speech classifier.
public actor EnergyVoiceActivity: VoiceActivityCapability {
    private let resource: ModelResource<Void>
    public init(context: ModelContext) throws { resource = try context.resource { () } }
    public var availability: CapabilityAvailability { .available }
    public func detectVoiceActivity(format: AudioFormat) async throws -> any VoiceActivitySession {
        guard format.sampleRate == 16000, format.channels == 1, format.encoding == .float32 else {
            throw CapabilityError.invalidRequest("Energy detector requires 16 kHz mono Float32")
        }
        let lease = try await resource.acquire()
        let resource = resource
        let session = EnergySession(format: format, release: { await resource.release(lease.id) })
        await resource.setCancellation(lease.id) { [weak session] in Task { await session?.cancel() } }
        return session
    }
}
private actor EnergySession: VoiceActivitySession {
    private let format: AudioFormat
    private let release: @Sendable () async -> Void
    private var pending: [Float] = []
    private var position: Int64 = 0
    private var noise: Float = 0.002
    private var active = false
    private var closed = false
    init(format: AudioFormat, release: @escaping @Sendable () async -> Void) {
        self.format = format
        self.release = release
    }
    func process(_ frame: AudioFrame) throws -> [VoiceActivityScore] {
        guard !closed else { throw CapabilityError.sessionClosed }
        guard frame.format == format, frame.sampleCount <= 16000 else {
            throw CapabilityError.invalidRequest("Invalid energy input")
        }
        let samples = frame.data.withUnsafeBytes { bytes in
            (0..<frame.sampleCount).map { bytes.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self) }
        }
        guard samples.allSatisfy(\.isFinite) else { throw CapabilityError.invalidRequest("Non-finite PCM") }
        pending.append(contentsOf: samples)
        var scores: [VoiceActivityScore] = []
        while pending.count >= 512 {
            scores.append(try score(Array(pending.prefix(512))))
            pending.removeFirst(512)
        }
        return scores
    }
    private func score(_ samples: [Float]) throws -> VoiceActivityScore {
        let rms = sqrt(samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(samples.count))
        let threshold = max(active ? 0.006 : 0.01, noise * (active ? 2 : 3))
        active = rms >= threshold
        if !active { noise = min(0.02, max(0.0001, noise * 0.95 + rms * 0.05)) }
        let value = try VoiceActivityScore(
            startSample: position, sampleCount: samples.count, probability: active ? 1 : 0)
        guard position <= Int64.max - Int64(samples.count) else { throw CapabilityError.bufferOverflow }
        position += Int64(samples.count)
        return value
    }
    func finish() async throws -> [VoiceActivityScore] {
        guard !closed else { throw CapabilityError.sessionClosed }
        let scores = pending.isEmpty ? [] : [try score(pending)]
        await cancel()
        return scores
    }
    func reset() throws {
        guard !closed else { throw CapabilityError.sessionClosed }
        pending.removeAll()
        position = 0
        noise = 0.002
        active = false
    }
    func cancel() async {
        guard !closed else { return }
        closed = true
        pending.removeAll()
        await release()
    }
}
