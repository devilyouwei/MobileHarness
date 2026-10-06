import ActionRuntime

/// One presentation domain; registry projections preserve existing protocol semantics.
public struct UIModule: CapabilityModule {
    private let expression: any UIPresentationCapability
    private let pose: any PosePresentationCapability
    private let updates: any UIUpdateCapability
    private let history: any HistoryPresentationCapability
    public init(
        expression: any UIPresentationCapability, pose: any PosePresentationCapability,
        updates: any UIUpdateCapability, history: any HistoryPresentationCapability
    ) {
        self.expression = expression
        self.pose = pose
        self.updates = updates
        self.history = history
    }
    public var definitions: [ActionDefinition] { scheduledDefinitions + directDefinitions }
    private var scheduledDefinitions: [ActionDefinition] {
        [
            UIActions.expressDefinition(handler: { [expression] invocation in
                try await UIActions.express(
                    invocation: invocation,
                    using: {
                        try await expression.presentExpression($0, invocation: $1)
                    },
                    restoring: {
                        try await expression.restoreExpression(invocation: $0)
                    })
            }),
            UIActions.setExpressionDefinition(handler: { [expression] invocation in
                try await UIActions.setExpression(invocation: invocation) {
                    try await expression.setExpression($0, invocation: $1)
                }
            }),
        ]
    }
    private var directDefinitions: [ToolDefinition] {
        [
            UIActions.showHistoryDefinition(completing: { [history] call, context in
                try await UIActions.showHistory(
                    invocation: ToolInvocation(call: call, context: context), using: history)
            }),
            UIActions.finishTranscriptDefinition(
                completing: { [updates] call, context in
                    try await UIActions.finishTranscript(invocation: ToolInvocation(call: call, context: context)) {
                        try await updates.finishTranscript(invocation: $0)
                    }
                }),
            UIActions.setTranscriptDefinition(
                completing: { [updates] call, context in
                    try await UIActions.setTranscript(invocation: ToolInvocation(call: call, context: context)) {
                        try await updates.presentTranscript($0, invocation: $1)
                    }
                }),
            UIActions.beginReplyTurnDefinition(
                completing: { [updates] call, context in
                    try await UIActions.beginReplyTurn(invocation: ToolInvocation(call: call, context: context)) {
                        try await updates.beginReplyTurn(invocation: $0)
                    }
                }),
            UIActions.setVoiceStateDefinition(
                completing: { [updates] call, context in
                    try await UIActions.setVoiceState(invocation: ToolInvocation(call: call, context: context)) {
                        try await updates.presentVoiceState($0, invocation: $1)
                    }
                }),
            UIActions.printDefinition(
                completing: { [updates] call, context in
                    try await UIActions.print(invocation: ToolInvocation(call: call, context: context)) {
                        try await updates.present($0, invocation: $1)
                    }
                }),
            UIActions.moveEyesDefinition(
                completing: { [updates] call, context in
                    try await UIActions.moveEyes(invocation: ToolInvocation(call: call, context: context)) {
                        try await updates.present($0, invocation: $1)
                    }
                }),
            UIActions.showPoseDefinition(
                completing: { [pose] call, context in
                    try await UIActions.showPose(call: call, context: context) {
                        try await pose.present($0, sessionID: $1.sessionID)
                    }
                }),
        ]
    }
}
