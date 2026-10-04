import AVFAudio
import Foundation

/// One converter per capture stream: its filter history survives hardware tap boundaries.
public actor StreamingMonoPCMResampler {
    public enum ConversionError: Error { case invalidInput, conversionFailed }
    private var converter: AVAudioConverter?
    private var sourceRate: Int?
    private var sequence: UInt64 = 0
    private let outputSampleRate: Int
    public init(outputSampleRate: Int) throws {
        guard (8000...192000).contains(outputSampleRate) else { throw ConversionError.invalidInput }
        self.outputSampleRate = outputSampleRate
    }
    public func reset() {
        converter?.reset()
        sequence = 0
        converter = nil
        sourceRate = nil
    }
    public func process(_ frame: MicrophoneFrame) throws -> [MicrophoneFrame] {
        try Task.checkCancellation()
        guard frame.layout == .mono, (8000...192000).contains(frame.sampleRate), !frame.samples.isEmpty,
            frame.samples.count <= 8192, frame.samples.allSatisfy(\.isFinite),
            sourceRate == nil || sourceRate == frame.sampleRate
        else { throw ConversionError.invalidInput }
        sourceRate = frame.sampleRate
        var samples: [Float]
        if frame.sampleRate == outputSampleRate {
            samples = frame.samples
        } else {
            guard
                let source = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32, sampleRate: Double(frame.sampleRate), channels: 1,
                    interleaved: false),
                let target = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32, sampleRate: Double(outputSampleRate), channels: 1,
                    interleaved: false),
                let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(frame.samples.count)),
                let data = input.floatChannelData?[0]
            else { throw ConversionError.conversionFailed }
            if converter == nil { converter = AVAudioConverter(from: source, to: target) }
            guard let converter else { throw ConversionError.conversionFailed }
            input.frameLength = AVAudioFrameCount(frame.samples.count)
            frame.samples.withUnsafeBufferPointer { data.update(from: $0.baseAddress!, count: frame.samples.count) }
            let capacity =
                Int(ceil(Double(frame.samples.count) * Double(outputSampleRate) / Double(frame.sampleRate))) + 4096
            guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(capacity)) else {
                throw ConversionError.conversionFailed
            }
            var supplied = false
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, status in
                guard !supplied else {
                    status.pointee = .noDataNow
                    return nil
                }
                supplied = true
                status.pointee = .haveData
                return input
            }
            guard error == nil, status == .inputRanDry, let values = output.floatChannelData?[0] else {
                throw ConversionError.conversionFailed
            }
            samples = Array(UnsafeBufferPointer(start: values, count: Int(output.frameLength)))
        }
        try Task.checkCancellation()
        return stride(from: 0, to: samples.count, by: 4000).map { offset in
            defer { sequence += 1 }
            return MicrophoneFrame(
                samples: Array(samples[offset..<min(offset + 4000, samples.count)]), sampleRate: outputSampleRate,
                sequence: sequence)
        }
    }
}
