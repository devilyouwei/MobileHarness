import AgentCore
import Agents
import Foundation
import Testing

@testable import PlatformKit

@Test(.actionCatalog) func cameraGraySamplePreservesStrideAndOrientation() throws {
    let source: [UInt8] = [
        10, 10, 10, 255, 20, 20, 20, 255, 99, 99, 99, 99,
        30, 30, 30, 255, 40, 40, 40, 255, 99, 99, 99, 99,
    ]
    let corners: [[UInt8]] = [[10, 20, 30, 40], [30, 10, 40, 20], [40, 30, 20, 10], [20, 40, 10, 30]]
    for rotation in 0...3 {
        let sample = try source.withUnsafeBytes {
            try CameraGraySampler.sample(
                base: UnsafeMutableRawPointer(mutating: $0.baseAddress!), sourceWidth: 2, sourceHeight: 2, stride: 12,
                rotation: rotation)
        }
        #expect(sample.count == 4096)
        #expect([sample[0], sample[63], sample[4032], sample[4095]] == corners[rotation])
    }
}

private struct SampleAttachment: ImageAttachment {}
@Test(.actionCatalog) func sampledNativeInputPreservesTransportAndValidatesSampleSize() throws {
    let sample = Data(repeating: 7, count: 4096)
    let input = try ImageInput(
        width: 720, height: 1280, gray64: sample, attachment: SampleAttachment(),
        sequence: 1, timestamp: 0, rotation: 1)
    guard case .attachment(let value) = input.content, let sampleAttachment = value as? SampledImageAttachment else {
        Issue.record("Missing native attachment transport")
        return
    }
    #expect(sampleAttachment.gray64 == sample)
    #expect(throws: ImageInputError.self) {
        try ImageInput(
            width: 720, height: 1280, gray64: Data(), attachment: SampleAttachment(), sequence: 1, timestamp: 0,
            rotation: 1)
    }
}
