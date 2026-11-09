import Foundation
import FunctionContracts

/// Six finite original PCM profiles; no system/private sound ID or user recording is packaged.
public enum FeedbackTone {
    public static let sampleRate = 48000
    private struct Voice {
        let frequency: Double
        let onset: Double
        let gain: Double
        let decay: Double
    }
    private static let bank: [UIActions.Cue: [Float]] = Dictionary(
        uniqueKeysWithValues: UIActions.Cue.allCases.map { ($0, render($0)) })
    public static func samples(for request: UIActions.CueRequest) throws -> [Float] {
        guard let values = bank[request.cue] else { throw UIActions.FeedbackError.unavailable }
        return values.map { $0 * Float(request.volume) }
    }
    private static func render(_ cue: UIActions.Cue) -> [Float] {
        let duration: Double
        let voices: [Voice]
        switch cue {
        case .wake:
            // Reference partials: F3/C4/F4/A4/C5, bright attack and warm sustained body.
            duration = 0.94
            voices = [
                Voice(frequency: 523.25, onset: 0, gain: 0.38, decay: 5.4),
                Voice(frequency: 1046.5, onset: 0, gain: 0.08, decay: 10),
                Voice(frequency: 174.61, onset: 0.025, gain: 0.14, decay: 4.5),
                Voice(frequency: 261.63, onset: 0.03, gain: 0.13, decay: 4.5),
                Voice(frequency: 349.23, onset: 0.065, gain: 0.17, decay: 3.5),
                Voice(frequency: 440, onset: 0.055, gain: 0.10, decay: 3.8),
            ]
        case .confirm:
            duration = 0.38
            voices = [
                Voice(frequency: 659.25, onset: 0, gain: 0.5, decay: 9),
                Voice(frequency: 1046.5, onset: 0.08, gain: 0.4, decay: 8),
            ]
        case .cancel:
            duration = 0.4
            voices = [
                Voice(frequency: 523.25, onset: 0, gain: 0.48, decay: 9),
                Voice(frequency: 349.23, onset: 0.09, gain: 0.42, decay: 8),
            ]
        case .error:
            duration = 0.46
            voices = [
                Voice(frequency: 293.66, onset: 0, gain: 0.45, decay: 14),
                Voice(frequency: 311.13, onset: 0, gain: 0.12, decay: 14),
                Voice(frequency: 293.66, onset: 0.16, gain: 0.45, decay: 12),
            ]
        case .soft:
            duration = 0.52
            voices = [
                Voice(frequency: 440, onset: 0, gain: 0.5, decay: 6),
                Voice(frequency: 660, onset: 0.035, gain: 0.24, decay: 8),
            ]
        case .save:
            duration = 0.62
            voices = [
                Voice(frequency: 659.25, onset: 0, gain: 0.44, decay: 7),
                Voice(frequency: 880, onset: 0.075, gain: 0.32, decay: 6),
                Voice(frequency: 1318.5, onset: 0.14, gain: 0.16, decay: 8),
            ]
        }
        return (0..<Int((duration * Double(sampleRate)).rounded())).map { i in
            let t = Double(i) / Double(sampleRate)
            let end = min(1, max(0, (duration - t) / 0.16))
            let tail = end * end * (3 - 2 * end)
            let value = voices.reduce(0.0) { result, voice in
                let age = t - voice.onset
                guard age > 0 else { return result }
                let attack = min(1, age / 0.012)
                let envelope = attack * attack * (3 - 2 * attack) * exp(-voice.decay * age)
                let vibrato = 0.002 * sin(2 * Double.pi * 5 * age)
                let phase = 2 * Double.pi * voice.frequency * age + vibrato
                return result + voice.gain * envelope * (sin(phase) + 0.035 * sin(2 * phase))
            }
            return Float(value * tail * 0.42)
        }
    }
}
