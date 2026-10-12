import Foundation
import ModelKit
import ModelKitCoreML
import os

public actor YOLOPose: PoseCapability {
    private let signposter = OSSignposter(subsystem: "dev.mobileharness.models", category: "Pose")
    private let url: URL
    private let resource: ModelResource<YOLOImageGraph>
    public init(context: ModelContext, artifacts: URL) throws {
        let compiled = artifacts.appendingPathComponent("yolo26n-pose.mlmodelc")
        let url =
            FileManager.default.fileExists(atPath: compiled.path)
            ? compiled : artifacts.appendingPathComponent("yolo26n-pose.mlpackage")
        self.url = url
        resource = try context.resource {
            let compiled = artifacts.appendingPathComponent("yolo26n-pose.mlmodelc")
            let current =
                FileManager.default.fileExists(atPath: compiled.path)
                ? compiled : artifacts.appendingPathComponent("yolo26n-pose.mlpackage")
            return try YOLOImageGraph(contentsOf: current)
        }
    }
    public var availability: CapabilityAvailability {
        FileManager.default.fileExists(atPath: url.path)
            ? .available : .unavailable(reason: "YOLO26n Pose artifacts are not installed")
    }
    public func estimatePose(_ request: PoseRequest) async throws -> PoseResult {
        let lease = try await resource.acquire()
        let worker = Task {
            let letterbox = try YOLOImageLayout(
                width: request.image.width, height: request.image.height,
                visionScaleFit: request.image.native != nil)
            let output: CoreMLTensor
            if let native = request.image.native {
                output = try await lease.model.runNative(
                    source: { native.withPixelBuffer { $0 } }, rotation: native.rotation)
            } else if let rgb = request.image.rgb {
                output = try await lease.model.run(rgb: rgb, layout: letterbox)
            } else {
                throw CapabilityError.invalidRequest("Missing image storage")
            }
            let interval = signposter.beginInterval("DecodePose")
            let people: [PersonPose]
            do {
                defer { signposter.endInterval("DecodePose", interval) }
                people = try PoseDecoder.decode(output, letterbox: letterbox)
            }
            try Task.checkCancellation()
            return PoseResult(context: request.context, people: people)
        }
        await resource.setCancellation(lease.id) { worker.cancel() }
        do {
            let result = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
            }
            await resource.release(lease.id)
            try Task.checkCancellation()
            return result
        } catch {
            await resource.release(lease.id)
            throw error
        }
    }
}
