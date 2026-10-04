import Foundation

/// Sample-count DSP, independent of VAD, inference, transport and presentation.
/// Only accumulated scalar statistics are retained; no PCM or unbounded result list.
struct SoundSourceEstimator {
    static let windowDuration = 0.1
    static let activityRMS = pow(10.0, -50.0 / 20.0)
    static let minimumQuality = 0.6
    private var sampleRate = 0
    private var count = 0
    private var start: TimeInterval = 0
    private var wPower = 0.0
    private var vectorPower = 0.0
    private var wx = 0.0
    private var wy = 0.0
    private var wz = 0.0
    private var quietWindows = 0

    mutating func reset() { self = Self() }

    /// Caller feeds individual interleaved W/Y/Z/X frames so each result has its own causal capture time.
    mutating func consume(
        w: Float, y: Float, z: Float, x: Float, sampleRate: Int, timestamp: TimeInterval
    ) throws -> SoundSourceObservation? {
        guard (8_000...192_000).contains(sampleRate), w.isFinite, x.isFinite, y.isFinite, z.isFinite,
            timestamp.isFinite, timestamp >= 0
        else { throw SoundSourceValidationError.invalidObservation }
        if self.sampleRate != sampleRate {
            reset()
            self.sampleRate = sampleRate
        }
        if count == 0 { start = timestamp }
        let w = Double(w)
        let x = Double(x)
        let y = Double(y)
        let z = Double(z)
        wPower += w * w
        vectorPower += x * x + y * y + z * z
        wx += w * x
        wy += w * y
        wz += w * z
        count += 1
        guard count == (sampleRate + 9) / 10 else { return nil }
        let rms = sqrt(wPower / Double(count))
        let magnitude = sqrt(wx * wx + wy * wy + wz * wz)
        let denominator = sqrt(wPower * vectorPower)
        let quality = denominator > 0 ? min(1, magnitude / denominator) : 0
        let state: SoundSourceObservation.State
        var direction: SoundSourceObservation.Direction?
        if rms < Self.activityRMS {
            quietWindows = min(2, quietWindows + 1)
            // Clear immediately to uncertain; confirm inactivity after two quiet windows.
            state = quietWindows >= 2 ? .inactive : .uncertain
        } else {
            quietWindows = 0
            if quality >= Self.minimumQuality, magnitude > 0 {
                state = .active
                direction = .init(x: wx / magnitude, y: wy / magnitude, z: wz / magnitude)
            } else {
                state = .uncertain
            }
        }
        let result = SoundSourceObservation(
            state: state, direction: direction, quality: quality, rms: rms,
            timestamp: start, duration: Double(count) / Double(sampleRate))
        count = 0
        wPower = 0
        vectorPower = 0
        wx = 0
        wy = 0
        wz = 0
        return result
    }
}
