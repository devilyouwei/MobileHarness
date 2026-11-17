import Foundation
@_spi(ModelManagement) import ModelKit
import Testing

@testable import ModelKitDeepFilterNet3

@Test func deepFilterSTFTRoundtrip() throws {
    let window: [Float] = (0..<960).map { i in
        let v = sin(Float.pi * (Float(i) + 0.5) / 960)
        return sin(Float.pi / 2 * v * v)
    }
    let stft = try STFTProcessor(fftSize: 960, hopSize: 480, window: window)
    for count in [1, 479, 480, 481, 4961] {
        let samples = (0..<count).map { sin(Float($0) * 0.13) * 0.25 }
        var analysis = [Float](repeating: 0, count: 480)
        var synthesis = analysis
        let spectrum = stft.forward(audio: samples + [Float](repeating: 0, count: 960), analysisMem: &analysis)
        let pcm = stft.inverse(real: spectrum.real, imag: spectrum.imag, synthesisMem: &synthesis)
        #expect(zip(samples, pcm.dropFirst(480)).allSatisfy { abs($0 - $1) < 0.00001 })
    }
}

@Test func deepFilterRejectsCorruptAuxiliary() {
    for data in [Data(), Data([80, 75, 3, 4]), Data(repeating: 0, count: 262145)] {
        #expect(throws: (any Error).self) { try DeepFilterAuxiliary(data: data) }
    }
}

@Test func deepFilterRejectsInvalidPCMBeforeLoading() async throws {
    let context = try ModelContext(loadGate: ModelLoadGate(maximumConcurrentLoads: 1), maximumLoadWaiters: 2)
    let model = try DeepFilterNet3(context: context, artifacts: URL(fileURLWithPath: "/missing-deepfilter"))
    let wrong = try AudioFrame(
        data: Data(repeating: 0, count: 4),
        format: AudioFormat(sampleRate: 16000, channels: 1, encoding: .float32), sequence: 0, timestamp: 0)
    await #expect(throws: CapabilityError.self) { try await model.enhance(wrong) }
    let samples: [Float] = [.nan]
    let nan = try AudioFrame(
        data: samples.withUnsafeBytes { Data($0) },
        format: AudioFormat(sampleRate: 48000, channels: 1, encoding: .float32), sequence: 0, timestamp: 0)
    await #expect(throws: CapabilityError.self) { try await model.enhance(nan) }
    await context.shutdown()
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["DEEPFILTER_MODEL_ROOT"] != nil))
func deepFilterRealModelSmoke() async throws {
    guard let path = ProcessInfo.processInfo.environment["DEEPFILTER_MODEL_ROOT"] else { return }
    let root = URL(fileURLWithPath: path)
    let auxiliary = try DeepFilterAuxiliary(url: root.appendingPathComponent("auxiliary.npz"))
    let forward = auxiliary.arrays["erb_fb"]!
    let inverse = auxiliary.arrays["erb_inv_fb"]!
    for f in 0..<481 {
        #expect((0..<32).reduce(Float(0)) { $0 + inverse[$1 * 481 + f] } == 1)
        #expect((0..<32).contains { forward[f * 32 + $0] > 0 && inverse[$0 * 481 + f] == 1 })
    }
    let context = try ModelContext(loadGate: ModelLoadGate(maximumConcurrentLoads: 1), maximumLoadWaiters: 2)
    let model = try DeepFilterNet3(context: context, artifacts: root)
    for count in [1, 4801, 240000] {
        let samples = [Float](repeating: 0, count: count)
        let input = try AudioFrame(
            data: samples.withUnsafeBytes { Data($0) },
            format: AudioFormat(sampleRate: 48000, channels: 1, encoding: .float32), sequence: 7, timestamp: 1.25)
        let output = try await model.enhance(input)
        #expect(output.sampleCount == count)
        #expect(output.sequence == 7 && output.timestamp == 1.25)
        #expect(
            output.data.withUnsafeBytes { bytes in
                (0..<count).allSatisfy { abs(bytes.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self)) < 0.00001 }
            })
    }
    let noise = (0..<4800).map { i in Float((i * 7919) % 65536) / 65536 * 0.1 - 0.05 }
    let input = try AudioFrame(
        data: noise.withUnsafeBytes { Data($0) },
        format: AudioFormat(sampleRate: 48000, channels: 1, encoding: .float32), sequence: 8, timestamp: 2)
    let output = try await model.enhance(input)
    #expect(output.sampleCount == noise.count)
    #expect(output.data != input.data)
    let repeated = try await model.enhance(input)
    #expect(repeated == output)
    await context.shutdown()
}

@Test func deepFilterAuxiliaryLayoutAndTruncation() throws {
    var archive = Data()
    for name in DeepFilterAuxiliary.shapes.keys.sorted() {
        let shape = DeepFilterAuxiliary.shapes[name]!
        let isFortran = name == "erb_inv_fb"
        let header =
            "{'descr': '<f4', 'fortran_order': \(isFortran ? "True" : "False"), 'shape': (\(shape.map(String.init).joined(separator: ", ")),), }\n"
        var npy = Data([147, 78, 85, 77, 80, 89, 1, 0])
        npy.append(UInt8(header.utf8.count & 255))
        npy.append(UInt8(header.utf8.count >> 8))
        npy.append(Data(header.utf8))
        for i in 0..<shape.reduce(1, *) {
            var value = Float(i + 1).bitPattern.littleEndian
            withUnsafeBytes(of: &value) { npy.append(contentsOf: $0) }
        }
        let filename = Data((name + ".npy").utf8)
        var local = Data(repeating: 0, count: 30)
        local.replaceSubrange(0..<4, with: [80, 75, 3, 4])
        for offset in [18, 22] { for i in 0..<4 { local[offset + i] = UInt8((npy.count >> (8 * i)) & 255) } }
        local[26] = UInt8(filename.count)
        archive.append(local)
        archive.append(filename)
        archive.append(npy)
    }
    let decoded = try DeepFilterAuxiliary(data: archive)
    let inverse = decoded.arrays["erb_inv_fb"]!
    #expect(inverse[1] == 33)
    #expect(inverse[481] == 2)
    #expect(throws: (any Error).self) { try DeepFilterAuxiliary(data: archive.dropLast()) }
    var compressed = archive
    compressed[8] = 8
    #expect(throws: (any Error).self) { try DeepFilterAuxiliary(data: compressed) }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["DEEPFILTER_MODEL_ROOT"] != nil))
func windowedEnhancementRealModelProcessing() async throws {
    let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["DEEPFILTER_MODEL_ROOT"]))
    let context = try ModelContext(loadGate: ModelLoadGate(maximumConcurrentLoads: 1), maximumLoadWaiters: 2)
    let model = try DeepFilterNet3(context: context, artifacts: root)
    let stream = WindowedSpeechEnhancement(capability: model)
    let loading = ContinuousClock.now
    try await context.load()
    print("DeepFilterNet3 startup preload: \(loading.duration(to: .now))")
    var result: [AudioFrame] = []
    let start = ContinuousClock.now
    for offset in stride(from: 0, to: 96000, by: 4000) {
        let samples = (offset..<offset + 4000).map { Float(($0 * 7919) % 65536) / 65536 * 0.1 - 0.05 }
        result += try await stream.process(
            AudioFrame(
                data: samples.withUnsafeBytes { Data($0) },
                format: AudioFormat(sampleRate: 48000, channels: 1, encoding: .float32), sequence: UInt64(offset),
                timestamp: Double(offset) / 48000))
    }
    result += try await stream.finish()
    print(
        "DeepFilterNet3 windowed 2 s audio processing: \(start.duration(to: .now)) (Mac CPU, model preloaded as at App startup)"
    )
    #expect(result.reduce(0) { $0 + $1.sampleCount } == 96000)
    #expect(result.allSatisfy { $0.format.sampleRate == 48000 })
    await context.shutdown()
}
