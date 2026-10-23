import FunctionContracts

/// One presentation domain of protocol-neutral callable functions.
@ActionCatalog
public struct UIModule: CapabilityModule {
    private let expression: any UIPresentationCapability
    private let pose: any PosePresentationCapability
    private let updates: any UIUpdateCapability
    private let history: any HistoryPresentationCapability
    private let effects: (any UIEffectCapability)?
    private let loading: (any LoadingExpressionPresentationCapability)?
    private let runtimeFailures: (any RuntimeFailurePresentationCapability)?
    private let bluetoothStatus: (any BluetoothStatusPresentationCapability)?
    private let feedback: (any UIFeedbackCapability)?
    public init(
        expression: any UIPresentationCapability, pose: any PosePresentationCapability,
        updates: any UIUpdateCapability, history: any HistoryPresentationCapability,
        feedback: (any UIFeedbackCapability)? = nil, effects: (any UIEffectCapability)? = nil,
        loading: (any LoadingExpressionPresentationCapability)? = nil,
        runtimeFailures: (any RuntimeFailurePresentationCapability)? = nil,
        bluetoothStatus: (any BluetoothStatusPresentationCapability)? = nil
    ) {
        self.loading = loading
        self.runtimeFailures = runtimeFailures
        self.bluetoothStatus = bluetoothStatus
        self.expression = expression
        self.pose = pose
        self.updates = updates
        self.history = history
        self.feedback = feedback
        self.effects = effects
    }
    public var definitions: [ActionFunction] {
        expressionFunctions + presentationFunctions + feedbackFunctions + effectFunctions + [
            UIActions.recordFailureDefinition(completing: { [runtimeFailures] invocation in
                guard let presentation = runtimeFailures else {
                    throw UIActions.PresentationError.invalidCall
                }
                return .value(try await UIActions.recordFailure(invocation: invocation, using: presentation))
            }),
            UIActions.showBluetoothHomeDefinition(completing: { [bluetoothStatus] invocation in
                guard let presentation = bluetoothStatus else {
                    throw UIActions.PresentationError.invalidCall
                }
                return .value(try await UIActions.showBluetoothHome(invocation: invocation, using: presentation))
            }),
            UIActions.showBluetoothSettingsDefinition(completing: { [bluetoothStatus] invocation in
                guard let presentation = bluetoothStatus else {
                    throw UIActions.PresentationError.invalidCall
                }
                return .value(try await UIActions.showBluetoothSettings(invocation: invocation, using: presentation))
            }),
        ]
    }
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
            UIActions.setReplyWaitingDefinition(handler: { [updates] invocation in
                try await UIActions.setReplyWaiting(invocation: invocation) {
                    try await updates.setReplyWaiting($0, requestID: $1, invocation: $2)
                }
            }),
            UIActions.setLoadingDefinition(handler: { [loading] invocation in
                guard let presentation = loading else {
                    throw UIActions.PresentationError.invalidCall
                }
                try await UIActions.setLoading(invocation: invocation, using: presentation)
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
                    try await UIActions.showPose(invocation: invocation) { overlay, _ in
                        try await pose.present(overlay, invocation: invocation)
                    }
                }),
        ]
    }
    private var feedbackFunctions: [ActionFunction] { Self.feedbackDefinitions(feedback: feedback) }
    public static func feedbackDefinitions(feedback: (any UIFeedbackCapability)?) -> [ActionFunction] {
        [
            UIActions.playCueDefinition(handler: { [feedback] invocation in
                guard let feedback else { throw UIActions.FeedbackError.unavailable }
                try await UIActions.playCue(
                    invocation: invocation, using: { try await feedback.playCue($0, invocation: $1) })
            }),
            UIActions.vibrateDefinition(handler: { [feedback] invocation in
                guard let feedback else { throw UIActions.FeedbackError.unavailable }
                try await UIActions.vibrate(
                    invocation: invocation, using: { try await feedback.vibrate($0, invocation: $1) })
            }),
        ]
    }
    private var effectFunctions: [ActionFunction] { Self.effectDefinitions(effects: effects) }
    public static func effectDefinitions(effects: (any UIEffectCapability)?) -> [ActionFunction] {
        [
            UIActions.showNoticeDefinition(handler: { [effects] invocation in
                guard let effects else { throw UIActions.EffectError.unavailable }
                try await UIActions.showNotice(
                    invocation: invocation, using: { try await effects.showNotice($0, invocation: $1) })
            }),
            UIActions.dismissNoticeDefinition(handler: { [effects] invocation in
                guard let effects else { throw UIActions.EffectError.unavailable }
                try await UIActions.dismissNotice(
                    invocation: invocation, using: { try await effects.dismissNotice(invocation: $0) })
            }),
            UIActions.updateLightDefinition(handler: { [effects] invocation in
                guard let effects else { throw UIActions.EffectError.unavailable }
                try await UIActions.updateLight(
                    invocation: invocation, using: { try await effects.updateLight($0, invocation: $1) })
            }),
        ]
    }
}
