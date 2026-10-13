import Foundation
import FunctionContracts

/// UI.Expression function ownership; current invocation paths remain compatible.
extension UIActions {
    @Action(
        domain: "UI", module: "Expression", title: "表情演出",
        doc:
            "Perform one eye expression, awaiting its transition and return to the current base expression. Each call is a fresh performance. Does not change captions or speech.",
        parameters: [
            .init(
                "emotion", type: .string, required: true,
                description:
                    "The emotion expressed by the two animated blue eyes; closed smoothly closes both eyelids. No emoji or text glyphs.",
                constraints:
                    "Exactly one of: closed, smile, happy, laugh, thinking, surprised, sad, love, angry, scared, playful. clear is invalid; use setExpression for persistent state or clearing."
            )
        ], kind: .finite,
        completion: "One expression transition and restoration finish; cancellation joins override cleanup.",
        timeout: .seconds(5))
    public static func express(
        invocation: any FunctionInput,
        using present: @escaping @Sendable (Emotion, any FunctionInput) async throws -> Void,
        restoring restore: @escaping @Sendable (any FunctionInput) async throws -> Void
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
        domain: "UI", module: "Expression", title: "设置持续表情",
        doc:
            "Set the persistent base eye expression until replaced, cleared or reset on new user speech. Completes on state acceptance, not animation completion. Repeating the same emotion is idempotent.",
        parameters: [
            .init(
                "emotion", type: .string, required: true,
                description:
                    "The emotion expressed by the two animated blue eyes; closed smoothly closes both eyelids. No emoji or text glyphs.",
                constraints:
                    "Exactly one of: clear, closed, smile, happy, laugh, thinking, surprised, sad, love, angry, scared, playful. clear resets the base to neutral."
            )
        ], kind: .state,
        completion: "Base expression target is committed; visual interpolation is not joined.", timeout: .seconds(5))
    public static func setExpression(
        invocation: any FunctionInput,
        using apply: @escaping @Sendable (Emotion, any FunctionInput) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        let emotion = try decode(invocation)
        try await apply(emotion, invocation)
        try Task.checkCancellation()
    }

    private static func decode(_ invocation: any FunctionInput) throws -> Emotion {
        do {
            let arguments = ActionArguments(invocation.call.parameters)
            try arguments.validateAllowedKeys(["emotion"])
            return try arguments.requiredEnum("emotion", as: Emotion.self)
        } catch { throw ExpressionError.invalidEmotion }
    }
}
