import Foundation
import ToolRuntime

public enum UITools {
    @Tool(path: "UI.showHistory", title: "showHistory")
    public static func showHistory(invocation: ToolInvocation, using history: any HistoryPresentationCapability)
        async throws
    {
        try Task.checkCancellation()
        try ToolArguments(invocation.call.arguments).validateAllowedKeys([])
        try await history.showHistory(invocation: invocation)
        try Task.checkCancellation()
    }

    @Tool(path: "UI.beginReplyTurn", title: "beginReplyTurn")
    public static func beginReplyTurn(
        invocation: ToolInvocation,
        using present: @escaping @Sendable (ToolInvocation) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        do { try ToolArguments(invocation.call.arguments).validateAllowedKeys([]) } catch {
            throw PresentationError.invalidCall
        }
        try await present(invocation)
        try Task.checkCancellation()
    }

    /// Replace the recognition caption; unlike UI.print, empty text is an explicit clear.
    @Tool(path: "UI.setTranscript", title: "setTranscript")
    public static func setTranscript(
        invocation: ToolInvocation,
        using present: @escaping @Sendable (String, ToolInvocation) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        let text: String
        do {
            let arguments = ToolArguments(invocation.call.arguments)
            try arguments.validateAllowedKeys(["text"])
            text = try arguments.requiredString("text", maximumUTF8Bytes: 4096, allowBlank: true)
        } catch { throw PresentationError.invalidText }
        try await present(text, invocation)
        try Task.checkCancellation()
    }

    @Tool(path: "UI.finishTranscript", title: "finishTranscript")
    public static func finishTranscript(
        invocation: ToolInvocation,
        using present: @escaping @Sendable (ToolInvocation) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        do { try ToolArguments(invocation.call.arguments).validateAllowedKeys([]) } catch {
            throw PresentationError.invalidCall
        }
        try await present(invocation)
        try Task.checkCancellation()
    }

    @Tool(path: "UI.setVoiceState", title: "setVoiceState")
    public static func setVoiceState(
        invocation: ToolInvocation,
        using present: @escaping @Sendable (VoiceState, ToolInvocation) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        let state: VoiceState
        do {
            let arguments = ToolArguments(invocation.call.arguments)
            try arguments.validateAllowedKeys(["state"])
            state = try arguments.requiredEnum("state", as: VoiceState.self)
        } catch { throw PresentationError.invalidCall }
        try await present(state, invocation)
        try Task.checkCancellation()
    }

    @Tool(path: "UI.print", title: "print")
    public static func print(
        invocation: ToolInvocation,
        using present: @escaping @Sendable (String, ToolInvocation) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        let text: String
        do {
            let arguments = ToolArguments(invocation.call.arguments)
            try arguments.validateAllowedKeys(["text"])
            text = try arguments.requiredString("text", maximumUTF8Bytes: 2000, allowBlank: false)
        } catch { throw PresentationError.invalidText }
        try await present(text, invocation)
        try Task.checkCancellation()
    }

    @Tool(path: "UI.moveEyes", title: "moveEyes")
    public static func moveEyes(
        invocation: ToolInvocation,
        using present: @escaping @Sendable (Gaze, ToolInvocation) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        let target: Gaze
        do {
            let arguments = ToolArguments(invocation.call.arguments)
            try arguments.validateAllowedKeys(["x", "y"])
            target = try Gaze(
                x: arguments.requiredFiniteDouble("x", range: -1...1),
                y: arguments.requiredFiniteDouble("y", range: -1...1))
        } catch { throw GazeError.invalidTarget }
        try await present(target, invocation)
        try Task.checkCancellation()
    }

    /// Atomically replaces all displayed skeletons; an empty people list clears them.
    @Tool(path: "UI.showPose", title: "showPose")
    public static func showPose(
        call: ToolRequest, context: ToolExecutionContext,
        present: @escaping @Sendable (ToolPoseOverlay, ToolExecutionContext) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        guard let payload = call.arguments["payload"], payload.utf8.count <= 3000,
            let overlay = try? JSONDecoder().decode(ToolPoseOverlay.self, from: Data(payload.utf8)),
            overlay.timestamp.isFinite, overlay.timestamp >= 0, (0...3).contains(overlay.rotation),
            overlay.people.count <= 6, overlay.statistics?.isValid ?? true,
            overlay.people.allSatisfy({ person in
                person.count == 17
                    && person.allSatisfy {
                        (-10000...20000).contains($0.x) && (-10000...20000).contains($0.y)
                            && (0...1000).contains($0.confidence)
                    }
            })
        else { throw PoseError.invalidPayload }
        try await present(overlay, context)
        try Task.checkCancellation()
    }
}
