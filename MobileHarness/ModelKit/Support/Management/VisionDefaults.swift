import Foundation
import ModelKit
@_spi(ModelAssembly) import ModelKitRuntime
import ModelKitYOLOPose

extension DefaultModelAssembly {
    static func registerVision(manager: ModelManager, resources: URL) async throws {
        try await manager.register(
            ModelRegistration(
                id: ModelID("yolo26n-pose"), capabilities: [.pose], memoryPolicy: .releaseWhenIdle,
                artifactID: "yolo26n-pose"
            ) {
                context in
                ProvidedCapabilities(
                    pose: try YOLOPose(context: context, artifacts: resources.appendingPathComponent("YOLOPose")))
            }, defaults: [.pose])
    }
}
