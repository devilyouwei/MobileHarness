import Foundation

/// Typed presentation operations; completion means the endpoint accepted the update.
public protocol UIUpdateCapability: Sendable {
    func present(_ text: String, invocation: ToolInvocation) async throws
    func presentTranscript(_ text: String, invocation: ToolInvocation) async throws
    func finishTranscript(invocation: ToolInvocation) async throws
    func beginReplyTurn(invocation: ToolInvocation) async throws
    func presentVoiceState(_ state: UITools.VoiceState, invocation: ToolInvocation) async throws
    func present(_ target: UITools.Gaze, invocation: ToolInvocation) async throws
}

public protocol PosePresentationCapability: Sendable {
    func present(_ overlay: ToolPoseOverlay, sessionID: UUID) async throws
}

public struct UIToolModule: ToolModule {
    private let updates: any UIUpdateCapability
    private let presentation: any PosePresentationCapability
    public init(presentation: any PosePresentationCapability, updates: any UIUpdateCapability) {
        self.presentation = presentation
        self.updates = updates
    }
    public var definitions: [ToolDefinition] {
        [
            UITools.finishTranscriptDefinition(
                completing: { [updates] call, context in
                    try await UITools.finishTranscript(invocation: ToolInvocation(call: call, context: context)) {
                        try await updates.finishTranscript(invocation: $0)
                    }
                }),
            UITools.setTranscriptDefinition(
                completing: { [updates] call, context in
                    try await UITools.setTranscript(invocation: ToolInvocation(call: call, context: context)) {
                        try await updates.presentTranscript($0, invocation: $1)
                    }
                }),
            UITools.beginReplyTurnDefinition(
                completing: { [updates] call, context in
                    try await UITools.beginReplyTurn(invocation: ToolInvocation(call: call, context: context)) {
                        try await updates.beginReplyTurn(invocation: $0)
                    }
                }),
            UITools.setVoiceStateDefinition(
                completing: { [updates] call, context in
                    try await UITools.setVoiceState(invocation: ToolInvocation(call: call, context: context)) {
                        try await updates.presentVoiceState($0, invocation: $1)
                    }
                }),
            UITools.printDefinition(
                completing: { [updates] call, context in
                    try await UITools.print(invocation: ToolInvocation(call: call, context: context)) {
                        try await updates.present($0, invocation: $1)
                    }
                }),
            UITools.moveEyesDefinition(
                completing: { [updates] call, context in
                    try await UITools.moveEyes(invocation: ToolInvocation(call: call, context: context)) {
                        try await updates.present($0, invocation: $1)
                    }
                }),
            UITools.showPoseDefinition(
                completing: { [presentation] call, context in
                    try await UITools.showPose(call: call, context: context) {
                        try await presentation.present($0, sessionID: $1.sessionID)
                    }
                }),
        ]
    }
}
