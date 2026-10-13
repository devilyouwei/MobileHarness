import Foundation

/// Bounded mono PCM16 WAV encoding for native short-sound playback.
public enum PCMClipEncoding {
    public enum Failure: Error, Sendable { case invalidFormat }
    public static func wav16(samples: [Float], sampleRate: Int) throws -> Data {
        guard (8000...192000).contains(sampleRate), !samples.isEmpty,
            samples.count <= min(192000, sampleRate),
            samples.allSatisfy({ $0.isFinite && abs($0) <= 1 })
        else { throw Failure.invalidFormat }
        let length = samples.count * 2
        var data = Data(capacity: length + 44)
        func append<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: "RIFF".utf8)
        append(UInt32(length + 36))
        data.append(contentsOf: "WAVEfmt ".utf8)
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * 2))
        append(UInt16(2))
        append(UInt16(16))
        data.append(contentsOf: "data".utf8)
        append(UInt32(length))
        for sample in samples { append(Int16((sample * 32767).rounded())) }
        return data
    }
}
