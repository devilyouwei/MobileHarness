import AudioToolbox
import CoreMedia
import Testing

@testable import PlatformKit

private enum NativeAudioReaderFixtureError: Error { case readFailed }

/// Native CoreMedia buffers, not mocked buffer-list sizes or captured user audio.
private func makeNativeAudioSample(channels: Int = 4, planar: Bool) throws -> CMSampleBuffer {
    let frames = 8
    let bytesPerFrame = UInt32(MemoryLayout<Float>.size * (planar ? 1 : channels))
    var asbd = AudioStreamBasicDescription(
        mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
            | (planar ? kAudioFormatFlagIsNonInterleaved : 0),
        mBytesPerPacket: bytesPerFrame, mFramesPerPacket: 1, mBytesPerFrame: bytesPerFrame,
        mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
    var description: CMAudioFormatDescription?
    try #require(
        CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description) == noErr)
    let samples = (0..<frames * channels).map { Float($0) / 64 }
    let byteCount = samples.count * MemoryLayout<Float>.size
    var block: CMBlockBuffer?
    try #require(
        CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: byteCount, flags: 0, blockBufferOut: &block) == noErr)
    let data = try #require(block)
    try samples.withUnsafeBytes { bytes in
        try #require(
            CMBlockBufferReplaceDataBytes(
                with: try #require(bytes.baseAddress), blockBuffer: data, offsetIntoDestination: 0,
                dataLength: byteCount) == noErr)
    }
    var timing = CMSampleTimingInfo(
        duration: CMTime(value: 1, timescale: 48_000), presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
    var sampleSize = Int(bytesPerFrame)
    var sample: CMSampleBuffer?
    try #require(
        CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: data, formatDescription: description,
            sampleCount: frames, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &sample) == noErr)
    return try #require(sample)
}

@Test func nativeAudioReaderAcceptsFourInterleavedChannelsInOneBuffer() throws {
    let sample = try makeNativeAudioSample(planar: false)
    let values = try AudioSampleBufferReader.withAudioBuffers(from: sample) { buffers in
        #expect(buffers.count == 1)
        #expect(buffers[0].mNumberChannels == 4)
        #expect(buffers[0].mDataByteSize == 32 * MemoryLayout<Float>.size)
        let pointer = try #require(buffers[0].mData)
        return (0..<32).map { pointer.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self) }
    }
    #expect(values == (0..<32).map { Float($0) / 64 })
}

@Test func nativeAudioReaderPreservesFourPlanarBuffersAndTheirSamples() throws {
    let sample = try makeNativeAudioSample(planar: true)
    let values = try AudioSampleBufferReader.withAudioBuffers(from: sample) { buffers in
        #expect(buffers.count == 4)
        return try buffers.flatMap { buffer in
            #expect(buffer.mNumberChannels == 1)
            #expect(buffer.mDataByteSize == 8 * MemoryLayout<Float>.size)
            let pointer = try #require(buffer.mData)
            return (0..<8).map { pointer.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self) }
        }
    }
    #expect(values == (0..<32).map { Float($0) / 64 })
}

@Test func nativeAudioReaderRejectsMoreThanFourBuffersBeforeCallingReader() throws {
    let sample = try makeNativeAudioSample(channels: 5, planar: true)
    #expect(throws: AudioSampleBufferReader.BufferListError.invalidSize(AudioBufferList.sizeInBytes(maximumBuffers: 5)))
    {
        try AudioSampleBufferReader.withAudioBuffers(from: sample) { _ in
            Issue.record("Oversized native buffer list was admitted")
        }
    }
}

@Test func nativeAudioReaderPreservesReadFailureAndCanReadAgain() throws {
    let sample = try makeNativeAudioSample(planar: false)
    #expect(throws: NativeAudioReaderFixtureError.self) {
        try AudioSampleBufferReader.withAudioBuffers(from: sample) { _ in
            throw NativeAudioReaderFixtureError.readFailed
        }
    }
    let count = try AudioSampleBufferReader.withAudioBuffers(from: sample) { $0.count }
    #expect(count == 1)
}
