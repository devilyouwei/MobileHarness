import AgentCore
import Foundation

public protocol PosePresentationCapability: Sendable {
    func present(_ overlay: PoseOverlay, sessionID: UUID) async throws
}
