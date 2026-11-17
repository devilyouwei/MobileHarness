import Foundation
import ModelKit
import ModelKitD3
@_spi(ModelAssembly) import ModelKitRuntime
import ModelKitYOLOPose

extension DefaultModelAssembly {
    @available(iOS 27, macOS 27, *)
    static func registerDecision(manager: ModelManager, resources: URL) async throws {
        try await manager.register(
            ModelRegistration(
                id: ModelID("d3-edge"), capabilities: [.decision], memoryPolicy: .retain, artifactID: "d3-edge"
            ) { context in
                ProvidedCapabilities(
                    decision: try D3Decision(context: context, artifacts: resources.appendingPathComponent("D3Edge")))
            }, defaults: [.decision])
        try await manager.register(
            ModelRegistration(
                id: ModelID("d3-lite"), capabilities: [.decision], memoryPolicy: .retain, artifactID: "d3-lite"
            ) { context in
                ProvidedCapabilities(
                    decision: try D3Decision(context: context, artifacts: resources.appendingPathComponent("D3Lite")))
            })
        try await manager.register(
            ModelRegistration(
                id: ModelID("vela3-fast"), capabilities: [.decision], memoryPolicy: .retain,
                artifactID: "vela3-fast"
            ) { context in
                ProvidedCapabilities(
                    decision: try VelaDecision(
                        context: context,
                        artifacts: resources.appendingPathComponent("Vela3Fast")))
            })
    }
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
