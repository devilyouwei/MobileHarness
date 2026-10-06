import FunctionContracts

/// One presentation domain of protocol-neutral callable functions.
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
    public var definitions: [ActionFunction] { expressionFunctions + presentationFunctions }
    private var expressionFunctions: [ActionFunction] {
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
    private var presentationFunctions: [ActionFunction] {
        [
            UIActions.showHistoryDefinition(handler: { [history] invocation in
                try await UIActions.showHistory(
                    invocation: invocation, using: history)
            }),
            UIActions.finishTranscriptDefinition(
                handler: { [updates] invocation in
                    try await UIActions.finishTranscript(invocation: invocation) {
                        try await updates.finishTranscript(invocation: $0)
                    }
                }),
            UIActions.setTranscriptDefinition(
                handler: { [updates] invocation in
                    try await UIActions.setTranscript(invocation: invocation) {
                        try await updates.presentTranscript($0, invocation: $1)
                    }
                }),
            UIActions.beginReplyTurnDefinition(
                handler: { [updates] invocation in
                    try await UIActions.beginReplyTurn(invocation: invocation) {
                        try await updates.beginReplyTurn(invocation: $0)
                    }
                }),
            UIActions.setVoiceStateDefinition(
                handler: { [updates] invocation in
                    try await UIActions.setVoiceState(invocation: invocation) {
                        try await updates.presentVoiceState($0, invocation: $1)
                    }
                }),
            UIActions.printDefinition(
                handler: { [updates] invocation in
                    try await UIActions.print(invocation: invocation) {
                        try await updates.present($0, invocation: $1)
                    }
                }),
            UIActions.moveEyesDefinition(
                handler: { [updates] invocation in
                    try await UIActions.moveEyes(invocation: invocation) {
                        try await updates.present($0, invocation: $1)
                    }
                }),
            UIActions.showPoseDefinition(
                handler: { [pose] invocation in
                    try await UIActions.showPose(invocation: invocation) {
                        try await pose.present($0, sessionID: $1.sessionID)
                    }
                }),
        ]
    }
}
