public struct UIToolModule: ToolModule {
    private let updates: any UIUpdateCapability
    private let presentation: any PosePresentationCapability
    public init(presentation: any PosePresentationCapability, updates: any UIUpdateCapability) {
        self.presentation = presentation
        self.updates = updates
    }
    public var definitions: [ToolDefinition] {
        [
            ToolDefinition(
                path: "UI.finishTranscript",
                completing: { [updates] call, envelope in
                    try await UITools.finishTranscript(invocation: ToolInvocation(call: call, envelope: envelope)) {
                        try await updates.finishTranscript(invocation: $0)
                    }
                }),
            ToolDefinition(
                path: "UI.setTranscript",
                completing: { [updates] call, envelope in
                    try await UITools.setTranscript(invocation: ToolInvocation(call: call, envelope: envelope)) {
                        try await updates.presentTranscript($0, invocation: $1)
                    }
                }),
            ToolDefinition(
                path: "UI.beginReplyTurn",
                completing: { [updates] call, envelope in
                    try await UITools.beginReplyTurn(invocation: ToolInvocation(call: call, envelope: envelope)) {
                        try await updates.beginReplyTurn(invocation: $0)
                    }
                }),
            ToolDefinition(
                path: "UI.setVoiceState",
                completing: { [updates] call, envelope in
                    try await UITools.setVoiceState(invocation: ToolInvocation(call: call, envelope: envelope)) {
                        try await updates.presentVoiceState($0, invocation: $1)
                    }
                }),
            ToolDefinition(
                path: "UI.print",
                completing: { [updates] call, envelope in
                    try await UITools.print(invocation: ToolInvocation(call: call, envelope: envelope)) {
                        try await updates.present($0, invocation: $1)
                    }
                }),
            ToolDefinition(
                path: "UI.moveEyes",
                completing: { [updates] call, envelope in
                    try await UITools.moveEyes(invocation: ToolInvocation(call: call, envelope: envelope)) {
                        try await updates.present($0, invocation: $1)
                    }
                }),
            ToolDefinition(
                path: "UI.showPose",
                completing: { [presentation] call, envelope in
                    try await UITools.showPose(call: call, envelope: envelope) {
                        try await presentation.present($0, sessionID: $1.sessionID)
                    }
                }),
        ]
    }
}
