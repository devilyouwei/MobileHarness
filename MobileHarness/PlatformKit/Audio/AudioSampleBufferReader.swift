import AudioToolbox
import CoreMedia

/// Synchronous access to native PCM storage. The retained block lives through the reader closure.
enum AudioSampleBufferReader {
    enum BufferListError: Error, Equatable {
        case queryFailed(OSStatus)
        case invalidSize(Int)
        case extractionFailed(OSStatus)
        case invalidBufferCount(Int)
    }

    /// Capture supports at most four native buffers; reported sizes never drive an unbounded allocation.
    static func withAudioBuffers<Result>(
        from sampleBuffer: CMSampleBuffer,
        _ read: (UnsafeMutableAudioBufferListPointer) throws -> Result
    ) throws -> Result {
        let flags = kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment
        var requiredSize = 0
        let queryStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: &requiredSize, bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: flags, blockBufferOut: nil)
        guard queryStatus == noErr else { throw BufferListError.queryFailed(queryStatus) }
        let maximumBuffers = 4
        guard requiredSize >= AudioBufferList.sizeInBytes(maximumBuffers: 1),
            requiredSize <= AudioBufferList.sizeInBytes(maximumBuffers: maximumBuffers)
        else { throw BufferListError.invalidSize(requiredSize) }

        let buffers = AudioBufferList.allocate(maximumBuffers: maximumBuffers)
        defer { buffers.unsafeMutablePointer.deallocate() }
        var retainedBlock: CMBlockBuffer?
        // CoreMedia requires its reported list size, not storage sized from the channel count.
        // Four interleaved channels use one AudioBuffer; four planar channels use four.
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: buffers.unsafeMutablePointer,
            bufferListSize: requiredSize, blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault, flags: flags, blockBufferOut: &retainedBlock)
        guard status == noErr else { throw BufferListError.extractionFailed(status) }
        guard (1...maximumBuffers).contains(buffers.count) else {
            throw BufferListError.invalidBufferCount(buffers.count)
        }
        return try withExtendedLifetime(retainedBlock) { try read(buffers) }
    }
}
