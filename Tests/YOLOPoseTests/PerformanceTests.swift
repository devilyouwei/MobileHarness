import CoreML
import Foundation
import ModelKit
import ModelKitCoreML
import Testing

@testable import ModelKitYOLOPose

/// Opt-in local microbenchmark. Timings are diagnostic, never flaky pass/fail thresholds.
@Test(.enabled(if: ProcessInfo.processInfo.environment["POSE_PERFORMANCE_CHECK"] == "1"))
func poseProcessingPerformance() throws {
    let image = try ImageFrame(width: 360, height: 640, rgb: Data(repeating: 114, count: 360 * 640 * 3))
    let preparation = YOLOImagePreparation()
    let layout = try YOLOImageLayout(width: image.width, height: image.height)
    let reference = ReferenceLetterbox(image: image)
    let tensor = try MLMultiArray(shape: [1, 300, 57], dataType: .float32)
    tensor.withUnsafeMutableBytes { bytes, _ in bytes.initializeMemory(as: UInt8.self, repeating: 0) }
    func median(_ name: String, _ work: () throws -> Void) rethrows {
        try work()  // warm-up
        var samples: [Double] = []
        for _ in 0..<5 {
            let start = ContinuousClock.now
            try work()
            let duration = start.duration(to: .now).components
            samples.append(Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15)
        }
        print("POSE_BENCH \(name): \(samples.sorted()[2]) ms median / 5, warmed, host only")
    }
    try median("old RGB letterbox only") {
        let result = try reference.render(image)
        #expect(result.count == 640 * 640 * 3)
    }
    try median("new complete RGB-to-model preparation") { _ = try preparation.prepare(rgb: image.rgb!, layout: layout) }
    median("old NSNumber tensor read") {
        let values = (0..<300).flatMap { channel in
            (0..<57).map { index in tensor[[0, NSNumber(value: channel), NSNumber(value: index)]].floatValue }
        }
        #expect(values.count == 17100)
    }
    try median("new bulk tensor read") {
        let result = try PoseTensorReader.read(tensor)
        #expect(result.values.count == 17100)
    }
}

private struct ReferenceLetterbox: Sendable {
    let width: Int
    let height: Int
    let left: Int
    let top: Int
    let scaleX: Float
    let scaleY: Float
    init(image: ImageFrame) {
        let scale = min(640.0 / Double(image.width), 640.0 / Double(image.height))
        width = max(1, Int((Double(image.width) * scale).rounded()))
        height = max(1, Int((Double(image.height) * scale).rounded()))
        left = (640 - width) / 2
        top = (640 - height) / 2
        scaleX = Float(width) / Float(image.width)
        scaleY = Float(height) / Float(image.height)
    }
    func render(_ image: ImageFrame) throws -> Data {
        var output = [UInt8](repeating: 114, count: 640 * 640 * 3)
        let source = [UInt8](image.rgb!)
        for y in 0..<height {
            try Task.checkCancellation()
            let sy = max(0, min(Float(image.height - 1), (Float(y) + 0.5) / scaleY - 0.5))
            let y0 = Int(sy)
            let y1 = min(y0 + 1, image.height - 1)
            let fy = sy - Float(y0)
            for x in 0..<width {
                let sx = max(0, min(Float(image.width - 1), (Float(x) + 0.5) / scaleX - 0.5))
                let x0 = Int(sx)
                let x1 = min(x0 + 1, image.width - 1)
                let fx = sx - Float(x0)
                for c in 0..<3 {
                    let a = Float(source[(y0 * image.width + x0) * 3 + c])
                    let b = Float(source[(y0 * image.width + x1) * 3 + c])
                    let d = Float(source[(y1 * image.width + x0) * 3 + c])
                    let e = Float(source[(y1 * image.width + x1) * 3 + c])
                    output[((y + top) * 640 + x + left) * 3 + c] = UInt8(
                        max(0, min(255, ((a * (1 - fx) + b * fx) * (1 - fy) + (d * (1 - fx) + e * fx) * fy).rounded())))
                }
            }
        }
        return Data(output)
    }
}

@Test(
    .enabled(
        if: ProcessInfo.processInfo.environment["POSE_VISION_BENCH"] == "1"
            && ProcessInfo.processInfo.environment["YOLO_POSE_MODEL_ROOT"] != nil))
func visionVersusVImageModelBaseline() async throws {
    let root = try #require(ProcessInfo.processInfo.environment["YOLO_POSE_MODEL_ROOT"])
    let url = URL(fileURLWithPath: root).appendingPathComponent("yolo26n-pose.mlpackage")
    // Constant fixture is reproducible, but not an accuracy or sustained-camera benchmark.
    let preparation = YOLOImagePreparation()
    let square = try YOLOImageLayout(width: 640, height: 640)
    let pixels = try preparation.prepare(rgb: Data(repeating: 114, count: 640 * 640 * 3), layout: square)
    let native = try NativeImageBuffer(pixelBuffer: pixels, rotation: 0)
    let rgb = Data(repeating: 114, count: 640 * 640 * 3)
    for compute in [YOLOImageGraph.Compute.cpuAndNeuralEngine, .all] {
        let graph = try YOLOImageGraph(contentsOf: url, compute: compute)
        for vision in [true, false] {
            var times: [Double] = []
            for iteration in 0..<8 {
                let start = ContinuousClock.now
                let tensor: CoreMLTensor
                if vision {
                    tensor = try await graph.runNative(source: { native.withPixelBuffer { $0 } }, rotation: 0)
                } else {
                    tensor = try await graph.run(rgb: rgb, layout: square)
                }
                #expect(tensor.values.count == 17100)
                let duration = start.duration(to: .now).components
                if iteration >= 3 {
                    times.append(Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15)
                }
            }
            print(
                "POSE_VISION_BENCH \(compute) \(vision ? "Vision" : "vImage/direct") \(times.sorted()[2]) ms; host, square constant fixture, includes tensor read"
            )
        }
    }
}
