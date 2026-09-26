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
    let box = PoseLetterbox(image: image)
    #expect(box.top == 160 && box.left == 0)
    let pixels = try box.render(image)
    #expect(Array(pixels.prefix(3)) == [114, 114, 114])
    #expect(Array(pixels[(160 * 640 * 3)..<(160 * 640 * 3 + 3)]) == [255, 0, 0])
}

@Test func poseNMSAndCoordinates() throws {
    let image = try ImageFrame(width: 1280, height: 640, rgb: Data(repeating: 0, count: 1280 * 640 * 3))
    var values = [Float](repeating: 0, count: 56 * 8400)
    for i in 0..<3 {
        values[i] = i == 2 ? 500 : 100
        values[8400 + i] = 240
        values[2 * 8400 + i] = 40
        values[3 * 8400 + i] = 80
        values[4 * 8400 + i] = i == 0 ? 0.9 : 0.8
        for joint in 0..<17 {
            values[(5 + joint * 3) * 8400 + i] = 100
            values[(6 + joint * 3) * 8400 + i] = 200
            values[(7 + joint * 3) * 8400 + i] = 0.7
        }
    }
    let result = try PoseDecoder.decode(
        CoreMLTensor(shape: [1, 56, 8400], values: values), letterbox: PoseLetterbox(image: image))
    #expect(result.count == 2)
    #expect(result[0].box.x == 160 && result[0].box.y == 80)
    #expect(result[0].keypoints.count == 17)
    #expect(result[0].keypoints[0].x == 200 && result[0].keypoints[0].y == 80)
    values[0] = .nan
    #expect(throws: CapabilityError.self) {
        try PoseDecoder.decode(
            CoreMLTensor(shape: [1, 56, 8400], values: values), letterbox: PoseLetterbox(image: image))
    }
}

@Test func missingPoseArtifactsFailAndBindingIsTyped() async throws {
    let manager = ModelManager()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try await manager.register(
        ModelRegistration(id: ModelID("pose-test"), capabilities: [.pose]) { context in
            ProvidedCapabilities(pose: try YOLOPose(context: context, artifacts: root))
        }, defaults: [.pose])
    let pose = try await manager.get(.pose, load: false)
    #expect(await pose.availability == .unavailable(reason: "YOLOv8n Pose artifacts are not installed"))
    await #expect(throws: (any Error).self) { try await manager.load(.pose) }
    await manager.shutdown()
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["YOLO_POSE_MODEL_ROOT"] != nil))
func realPoseModel() async throws {
    let path = try #require(ProcessInfo.processInfo.environment["YOLO_POSE_MODEL_ROOT"])
    let manager = ModelManager()
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
