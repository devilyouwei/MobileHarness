import Foundation

/// Bounded overlap/context adapter for stateless enhancement. Not recurrent streaming.
/// 320 ms hop/history + 40 ms crossfade + 40 ms lookahead; first output after 400 ms.
public actor WindowedSpeechEnhancement {
    private static let hop = 15360
    private static let overlap = 1920
    private static let lookahead = 1920
    private let capability: any SpeechEnhancementCapability
    private var pending: [Float] = []
    private var history: [Float] = []
    private var tail: [Float] = []
    private var origin: TimeInterval?
    private var received = 0
    private var emitted = 0
    private var sequence: UInt64 = 0
    private var lastSequence: UInt64?
    private var busy = false
    private var closed = false
    private var generation: UInt64 = 0
    public init(capability: any SpeechEnhancementCapability) { self.capability = capability }
    public func reset() {
        generation &+= 1
        pending.removeAll()
        history.removeAll()
        tail.removeAll()
        origin = nil
        received = 0
        emitted = 0
        sequence = 0
        lastSequence = nil
        closed = false
    }
    public func process(_ frame: AudioFrame) async throws -> [AudioFrame] {
        guard !closed else { throw CapabilityError.sessionClosed }
        guard !busy else { throw CapabilityError.inputBusy }
        guard frame.format.sampleRate == 48000, frame.format.channels == 1, frame.format.encoding == .float32,
            frame.sampleCount <= 8192, lastSequence.map({ frame.sequence > $0 }) ?? true,
            origin.map({ abs(frame.timestamp - ($0 + Double(received) / 48000)) <= 1.0 / 48000 }) ?? true
        else {
            throw CapabilityError.invalidRequest("Enhancement stream requires contiguous 48 kHz mono Float32")
        }
        let samples = frame.data.withUnsafeBytes { bytes in
            (0..<frame.sampleCount).map { bytes.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self) }
        }
        guard samples.allSatisfy(\.isFinite) else { throw CapabilityError.invalidRequest("Nonfinite PCM") }
        guard pending.count + samples.count <= 27392 else { throw CapabilityError.bufferOverflow }
        busy = true
        defer { busy = false }
        let epoch = generation
        if origin == nil { origin = frame.timestamp }
        received += samples.count
        lastSequence = frame.sequence
        pending += samples
        do {
            var result: [AudioFrame] = []
            while pending.count >= Self.hop + Self.overlap + Self.lookahead {
                result.append(try await render(count: Self.hop, finishing: false, epoch: epoch))
            }
            return result
        } catch {
            if epoch == generation {
                reset()
                closed = true
            }
            throw error
        }
    }
    public func finish() async throws -> [AudioFrame] {
        guard !closed else { throw CapabilityError.sessionClosed }
        guard !busy else { throw CapabilityError.inputBusy }
        busy = true
        defer { busy = false }
        let epoch = generation
        do {
            let result = pending.isEmpty ? [] : [try await render(count: pending.count, finishing: true, epoch: epoch)]
            guard epoch == generation else { throw CancellationError() }
            closed = true
            history.removeAll()
            tail.removeAll()
            return result
        } catch {
            if epoch == generation {
                reset()
                closed = true
            }
            throw error
        }
    }
    private func render(count: Int, finishing: Bool, epoch: UInt64) async throws -> AudioFrame {
        try Task.checkCancellation()
        let future = finishing ? 0 : Self.overlap + Self.lookahead
        let raw = Array(pending.prefix(count + future))
        let input = history + raw
        let format = try AudioFormat(sampleRate: 48000, channels: 1, encoding: .float32)
        let enhanced = try await capability.enhance(
            AudioFrame(
                data: input.withUnsafeBytes { Data($0) }, format: format, sequence: sequence,
                timestamp: (origin ?? 0) + Double(emitted - history.count) / 48000))
        try Task.checkCancellation()
        guard epoch == generation else { throw CancellationError() }
        guard enhanced.format == format, enhanced.sampleCount == input.count else {
            throw CapabilityError.invalidRequest("Enhancement changed PCM format or length")
        }
        let values = enhanced.data.withUnsafeBytes { bytes in
            (0..<enhanced.sampleCount).map { bytes.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self) }
        }
        guard values.allSatisfy(\.isFinite) else { throw CapabilityError.invalidRequest("Nonfinite enhanced PCM") }
        var output = Array(values[history.count..<history.count + count])
        for i in 0..<min(tail.count, output.count) {
            let weight = Float(i + 1) / Float(Self.overlap + 1)
            output[i] = tail[i] * (1 - weight) + output[i] * weight
        }
        tail = finishing ? [] : Array(values[history.count + count..<history.count + count + Self.overlap])
        let result = try AudioFrame(
            data: output.withUnsafeBytes { Data($0) }, format: format,
            sequence: sequence, timestamp: (origin ?? 0) + Double(emitted) / 48000)
        history = Array((history + pending.prefix(count)).suffix(Self.hop))
        pending.removeFirst(count)
        emitted += count
        sequence += 1
        return result
    }
}
