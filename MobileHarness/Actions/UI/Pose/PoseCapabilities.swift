import Foundation
import FunctionContracts

public protocol PosePresentationCapability: Sendable {
    func present(_ overlay: PoseOverlay, sessionID: String) async throws
    func present(_ overlay: PoseOverlay, invocation: any FunctionInput) async throws
}
extension PosePresentationCapability {
    public func present(_ overlay: PoseOverlay, invocation: any FunctionInput) async throws {
        try await present(overlay, sessionID: invocation.context.sessionID)
    }
}
