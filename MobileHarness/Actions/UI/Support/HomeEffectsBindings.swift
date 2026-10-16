import Foundation
import FunctionContracts
import UI

extension HomeEffectsWorkflow {
    public func showNotice(_ notice: HomeNotice, durationMS: Int = 8000, invocation: any FunctionInput) async throws {
        try await showNotice(
            notice, durationMS: durationMS,
            owner: .init(source: invocation.context.source, session: invocation.context.sessionID))
    }
    public func dismissNotice(invocation: any FunctionInput) async throws {
        try await dismissNotice(owner: .init(source: invocation.context.source, session: invocation.context.sessionID))
    }
    public func updateLight(_ light: DecorativeLight?, durationMS: Int = 3000, invocation: any FunctionInput)
        async throws
    {
        try await updateLight(
            light, durationMS: durationMS,
            owner: .init(source: invocation.context.source, session: invocation.context.sessionID))
    }
}
