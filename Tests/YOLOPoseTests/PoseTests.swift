import CoreML
import CoreVideo
import Foundation
import ModelKit
import ModelKitCoreML
@_spi(ModelAssembly) import ModelKitRuntime
import Testing

@testable import ModelKitYOLOPose

@Test func imageBoundsAndLetterbox() throws {
    #expect(throws: CapabilityError.self) { try ImageFrame(width: Int.max, height: 1, rgb: Data()) }
    #expect(throws: CapabilityError.self) { try ImageFrame(width: 1, height: 1, rgb: Data()) }
    let image = try ImageFrame(width: 2, height: 1, rgb: Data([255, 0, 0, 255, 0, 0]))
    let box = try YOLOImageLayout(width: image.width, height: image.height)
    #expect(box.top == 160 && box.left == 0)
    let preparation = YOLOImagePreparation()
    let pixels = try preparation.prepare(rgb: image.rgb!, layout: box)
    #expect(pixel(pixels, x: 0, y: 0) == [114, 114, 114, 255])
    #expect(pixel(pixels, x: 0, y: 160) == [0, 0, 255, 255])
}

@Test func poseEndToEndCoordinatesAndNoDuplicateSuppression() throws {
    let layout = try YOLOImageLayout(width: 1280, height: 640)
    var values = [Float](repeating: 0, count: 300 * 57)
    for row in 0..<3 {
        let i = row * 57
        values[i] = row == 2 ? 480 : 80
        values[i + 1] = 200
        values[i + 2] = values[i] + 40
        values[i + 3] = 280
        values[i + 4] = row == 0 ? 0.9 : 0.8
        for joint in 0..<17 {
            values[i + 6 + joint * 3] = 100
            values[i + 7 + joint * 3] = 200
            values[i + 8 + joint * 3] = 0.7
        }
    }
    let result = try PoseDecoder.decode(CoreMLTensor(shape: [1, 300, 57], values: values), letterbox: layout)
    // Identical boxes are retained: the end-to-end head must not receive a second NMS pass.
    #expect(result.count == 3)
    #expect(result[0].box.x == 160 && result[0].box.y == 80)
    #expect(result[0].box.width == 80 && result[0].box.height == 160)
    #expect(result[0].keypoints[0].x == 200 && result[0].keypoints[0].y == 80)
    #expect(result[0].keypoints.count == 17)
    values[5] = 1
    #expect(throws: CapabilityError.self) {
        try PoseDecoder.decode(CoreMLTensor(shape: [1, 300, 57], values: values), letterbox: layout)
    }
    values[5] = 0
    values[8] = 1.1
    #expect(throws: CapabilityError.self) {
        try PoseDecoder.decode(CoreMLTensor(shape: [1, 300, 57], values: values), letterbox: layout)
    }
    values[8] = 0.7
    values[0] = .nan
    #expect(throws: CapabilityError.self) {
        try PoseDecoder.decode(CoreMLTensor(shape: [1, 300, 57], values: values), letterbox: layout)
    }
    #expect(throws: CapabilityError.self) {
        try PoseDecoder.decode(CoreMLTensor(shape: [1, 56, 8400], values: []), letterbox: layout)
    }
}

@Test func missingPoseArtifactsFailAndBindingIsTyped() async throws {
    let manager = try ModelManager()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try await manager.register(
        ModelRegistration(id: ModelID("pose-test"), capabilities: [.pose]) { context in
            ProvidedCapabilities(pose: try YOLOPose(context: context, artifacts: root))
        }, defaults: [.pose])
    let pose = try await manager.get(.pose, load: false)
    #expect(await pose.availability == .unavailable(reason: "YOLO26n Pose artifacts are not installed"))
    await #expect(throws: (any Error).self) { try await manager.load(.pose) }
    await manager.shutdown()
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["YOLO_POSE_MODEL_ROOT"] != nil))
func realPoseModel() async throws {
    let path = try #require(ProcessInfo.processInfo.environment["YOLO_POSE_MODEL_ROOT"])
    let manager = try ModelManager()
    try await manager.register(
        ModelRegistration(id: ModelID("real-pose"), capabilities: [.pose]) { context in
            ProvidedCapabilities(pose: try YOLOPose(context: context, artifacts: URL(fileURLWithPath: path)))
        }, defaults: [.pose])
    let pose = try await manager.get(.pose)
    let image = try ImageFrame(width: 640, height: 320, rgb: Data(repeating: 114, count: 640 * 320 * 3))
    let request = PoseRequest(image: image)
    let result = try await pose.estimatePose(request)
    #expect(result.context == request.context)
    #expect(result.people.isEmpty)
    try await manager.unload(.pose)
    #expect(try await manager.status(.pose) == .unloaded)
    _ = try await pose.estimatePose(request)
    await manager.shutdown()
    await #expect(throws: CapabilityError.sessionClosed) { _ = try await pose.estimatePose(request) }
}

private func pixel(_ buffer: CVPixelBuffer, x: Int, y: Int) -> [UInt8] {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
    let offset = y * CVPixelBufferGetBytesPerRow(buffer) + x * 4
    return Array(UnsafeBufferPointer(start: base + offset, count: 4))
}

@Test func imagePreparationReusesBufferAndClearsOldPadding() throws {
    let preparation = YOLOImagePreparation()
    let landscape = try YOLOImageLayout(width: 640, height: 320)
    let first = try preparation.prepare(rgb: Data(repeating: 80, count: 640 * 320 * 3), layout: landscape)
    #expect(pixel(first, x: 0, y: 160) == [80, 80, 80, 255])
    let portrait = try YOLOImageLayout(width: 320, height: 640)
    let second = try preparation.prepare(rgb: Data(repeating: 30, count: 320 * 640 * 3), layout: portrait)
    #expect(first === second)
    #expect(pixel(second, x: 0, y: 160) == [114, 114, 114, 255])
    #expect(pixel(second, x: 160, y: 0) == [30, 30, 30, 255])
    #expect(throws: CoreMLGraphError.self) { try preparation.prepare(rgb: Data(), layout: portrait) }
    #expect(throws: CoreMLGraphError.self) { try YOLOImageLayout(width: 0, height: 640) }
    #expect(throws: CoreMLGraphError.self) { try YOLOImageLayout(width: Int.max, height: 640) }
}

@Test func poseTensorBulkReadSupportsTypesAndStrides() throws {
    for type in [MLMultiArrayDataType.float16, .float32, .double] {
        for strides in [[17100, 57, 1], [34200, 114, 2], [17100, 1, 300]] {
            let size = type == .float16 ? 2 : (type == .float32 ? 4 : 8)
            let storage = try #require(calloc(strides[0], size))
            let array = try MLMultiArray(
                dataPointer: storage, shape: [1, 300, 57], dataType: type,
                strides: strides.map { NSNumber(value: $0) }, deallocator: { free($0) })
            array[[0, 0, 0]] = 1.25
            array[[0, 17, 13]] = -2.5
            array[[0, 299, 56]] = 3.75
            let result = try PoseTensorReader.read(array)
            #expect(result.values.count == 17100)
            #expect(result.values[0] == 1.25)
            #expect(result.values[17 * 57 + 13] == -2.5)
            #expect(result.values[299 * 57 + 56] == 3.75)
            #expect(result.values[58] == 0)
        }
    }
    let invalid = try MLMultiArray(shape: [1, 300, 57], dataType: .int32)
    #expect(throws: CoreMLGraphError.self) { try PoseTensorReader.read(invalid) }
}

private func nativePixels(width: Int, height: Int) throws -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
    #expect(status == kCVReturnSuccess)
    let pixels = try #require(buffer)
    CVPixelBufferLockBaseAddress(pixels, [])
    defer { CVPixelBufferUnlockBaseAddress(pixels, []) }
    let base = try #require(CVPixelBufferGetBaseAddress(pixels)).assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRow(pixels)
    for y in 0..<height {
        for x in 0..<width {
            let i = y * stride + x * 4
            base[i] = 114
            base[i + 1] = 114
            base[i + 2] = 114
            base[i + 3] = 255
        }
    }
    return pixels
}

@Test func nativeImageOrientationAndVisionCoordinates() throws {
    let pixels = try nativePixels(width: 1280, height: 720)
    for rotation in 0...3 {
        let image = try ImageFrame(pixelBuffer: pixels, rotation: rotation)
        #expect(image.rgb == nil)
        #expect(image.width == (rotation % 2 == 0 ? 1280 : 720))
        #expect(image.height == (rotation % 2 == 0 ? 720 : 1280))
        let layout = try YOLOImageLayout(width: image.width, height: image.height, visionScaleFit: true)
        #expect(layout.scaleX == 0.5 && layout.scaleY == 0.5)
        #expect(layout.offsetX == (rotation % 2 == 0 ? 0 : 140))
        #expect(layout.offsetY == (rotation % 2 == 0 ? 140 : 0))
    }
    #expect(throws: CapabilityError.self) { try ImageFrame(pixelBuffer: pixels, rotation: 4) }
    let odd = try YOLOImageLayout(width: 641, height: 360, visionScaleFit: true)
    #expect(abs((odd.offsetY + Float(360) * odd.scaleY / 2) - 320) < 0.001)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["YOLO_POSE_MODEL_ROOT"] != nil))
func realVisionNativePoseModel() async throws {
    let root = try #require(ProcessInfo.processInfo.environment["YOLO_POSE_MODEL_ROOT"])
    let manager = try ModelManager()
    try await manager.register(
        ModelRegistration(id: ModelID("vision-pose"), capabilities: [.pose]) { context in
            ProvidedCapabilities(pose: try YOLOPose(context: context, artifacts: URL(fileURLWithPath: root)))
        }, defaults: [.pose])
    let pose = try await manager.get(.pose)
    for rotation in 0...3 {
        let image = try ImageFrame(pixelBuffer: nativePixels(width: 640, height: 360), rotation: rotation)
        let request = PoseRequest(image: image)
        let result = try await pose.estimatePose(request)
        #expect(result.context == request.context)
        #expect(result.people.isEmpty)
    }
    await manager.shutdown()
}
