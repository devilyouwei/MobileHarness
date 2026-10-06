import ActionRuntime
import Foundation

/// UI.Expression function ownership; current invocation paths remain compatible.
extension UIActions {
    @Action(
        domain: "UI", module: "Expression", title: "表情演出", kind: .finite,
        completion: "One expression transition and restoration finish; cancellation joins override cleanup.",
        serializationKey: "UI",
        timeout: { _ in try ActionExecutionBudget(expected: .seconds(2), timeout: .seconds(5)) })
    public static func express(
        invocation: ActionInvocation,
        using present: @escaping @Sendable (Emotion, ActionInvocation) async throws -> Void,
        restoring restore: @escaping @Sendable (ActionInvocation) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        let emotion = try decode(invocation)
        guard emotion != .clear else { throw ExpressionError.invalidEmotion }
        do {
            try await present(emotion, invocation)
            try Task.checkCancellation()
        } catch {
            // Restoration must release only this invocation's override, even after cancellation.
            let primary = error
            do { try await restore(invocation) } catch {
                throw ExpressionCleanupFailure(primary: primary, cleanup: error)
            }
            throw primary
        }
        try await restore(invocation)
        try Task.checkCancellation()
    }

    @Action(
        domain: "UI", module: "Expression", title: "设置持续表情", kind: .state,
        completion: "Base expression target is committed; visual interpolation is not joined.", serializationKey: "UI")
    public static func setExpression(
        invocation: ActionInvocation,
        using apply: @escaping @Sendable (Emotion, ActionInvocation) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        let emotion = try decode(invocation)
        try await apply(emotion, invocation)
        try Task.checkCancellation()
    }

    private static func decode(_ invocation: ActionInvocation) throws -> Emotion {
        do {
            let arguments = ActionArguments(invocation.call.parameters)
            try arguments.validateAllowedKeys(["emotion"])
            return try arguments.requiredEnum("emotion", as: Emotion.self)
        } catch { throw ExpressionError.invalidEmotion }
    }
}
