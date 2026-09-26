import Foundation
import ModelKit
import ModelKitCoreML

public actor YOLOPose: PoseCapability {
    private let url: URL
    private let resource: ModelResource<CoreMLImageGraph>
    public init(context: ModelContext, artifacts: URL) throws {
        let compiled = artifacts.appendingPathComponent("yolov8n-pose.mlmodelc")
        let url =
            FileManager.default.fileExists(atPath: compiled.path)
            ? compiled : artifacts.appendingPathComponent("yolov8n-pose.mlpackage")
        self.url = url
        resource = try context.resource { try CoreMLImageGraph(contentsOf: url) }
    }
    public var availability: CapabilityAvailability {
        FileManager.default.fileExists(atPath: url.path)
            ? .available : .unavailable(reason: "YOLOv8n Pose artifacts are not installed")
    }
    public func estimatePose(_ request: PoseRequest) async throws -> PoseResult {
        let lease = try await resource.acquire()
        let worker = Task {
            let letterbox = PoseLetterbox(image: request.image)
            let pixels = try letterbox.render(request.image)
            let output = try await lease.model.run(rgb: pixels)
            let people = try PoseDecoder.decode(output, letterbox: letterbox)
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
