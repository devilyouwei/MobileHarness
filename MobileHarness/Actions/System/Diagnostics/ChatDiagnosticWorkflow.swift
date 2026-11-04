import FunctionContracts

#if DEBUG
    import Foundation
    import ModelKit

    /// Explicit synthetic check of ASR readiness and the configured chat capability; no Agent or device effects.
    public enum ChatDiagnosticWorkflow {
        public static func validate(
            chat: any ChatCapability, prepare: @Sendable () async throws -> Void
        ) async throws -> String {
            let started = Date()
            try await prepare()
            try Task.checkCancellation()
            let session = try await chat.chat(
                ChatRequest(
                    messages: [
                        .init(role: .system, content: "你是中文助手，直接简短回答。"),
                        .init(role: .user, content: "我有3个苹果，又买了2个，吃掉1个，还剩几个？只回答数字。"),
                    ], temperature: 0))
            defer { session.cancel() }
            var answer = ""
            for try await event in session.events {
                if case .text(let delta) = event { answer += delta }
            }
            guard !answer.isEmpty else { throw CapabilityError.unavailable("Empty validation reply") }
            return "ASR + chat ready. Reply: \(answer). Total: \(Date().timeIntervalSince(started)) s"
        }
    }
#endif
