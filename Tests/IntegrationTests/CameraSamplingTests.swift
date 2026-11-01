import AgentCore
import Foundation
import Testing

@testable import Agents
@testable import PlatformKit

@Test(arguments: [CameraOutputDimensions(width: 1920, height: 1440), .init(width: 1206, height: 1608)])
func nativePreviewGeometrySelectsMatchingBoundedPhoto(_ preview: CameraOutputDimensions) throws {
    let photo = try CameraOutputDimensions.photo(
        preview: preview, source: .init(width: 4032, height: 3024),
        supported: [
            .init(width: 8064, height: 6048), .init(width: 4032, height: 3024),
            .init(width: 1920, height: 1080), .init(width: 2016, height: 1512),
        ])
    #expect(photo == .init(width: 2016, height: 1512))
}

@Test(arguments: [
    CameraOutputDimensions(width: 1280, height: 720),
    CameraOutputDimensions(width: 4032, height: 3024),
    CameraOutputDimensions(width: 0, height: 0),
    CameraOutputDimensions(width: -4, height: -3),
    CameraOutputDimensions(width: .max, height: .max),
]) func nativePreviewGeometryRejectsMismatchOrUnboundedBuffers(_ preview: CameraOutputDimensions) {
    #expect(throws: CameraError.configurationFailed) {
        try CameraOutputDimensions.photo(
            preview: preview, source: .init(width: 4032, height: 3024),
            supported: [.init(width: 4032, height: 3024)])
    }
}

@Test(arguments: [
    [CameraOutputDimensions](), [.init(width: 8064, height: 6048)],
    [.init(width: 1920, height: 1080)], [.init(width: 0, height: 0)],
]) func nativePreviewGeometryRequiresSupportedPhoto(_ photos: [CameraOutputDimensions]) {
    #expect(throws: CameraError.configurationFailed) {
        try CameraOutputDimensions.photo(
            preview: .init(width: 1280, height: 960), source: .init(width: 4032, height: 3024), supported: photos)
    }
}

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

@Test(.actionCatalog) func cameraMotionSampleUsesNativeFrameAndRejectsInvalidSize() throws {
    let frame = try syntheticCameraFrame(
        width: 720, height: 1280, value: 7,
        sequence: 1, timestamp: 0, rotation: 1)
    #expect(frame.gray64 == Data(repeating: 7, count: 4096))
    let input = try syntheticCameraImage(
        width: 720, height: 1280, value: 7,
        sequence: 1, timestamp: 0, rotation: 1)
    var cadence = FrameCadence(configuration: try FrameSamplingConfiguration(minimumInterval: 0))
    #expect(try cadence.accepts(input))
    let malformed = try syntheticCameraImage(
        width: 720, height: 1280, gray64: Data(),
        sequence: 2, timestamp: 1, rotation: 1)
    #expect(throws: ImageInputError.self) { try cadence.accepts(malformed) }
}
