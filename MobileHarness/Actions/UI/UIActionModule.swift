import AgentCore

public struct UIActionModule: ActionModule {
    private let presentation: any UIPresentationCapability
    public init(presentation: any UIPresentationCapability) { self.presentation = presentation }
    public var definitions: [ActionDefinition] {
        [
            ActionDefinition(
                path: ActionPath(module: "UI", function: "finishTranscript"), kind: .state,
                completion: "Presentation policy accepted transcript closure or rejected a stale update.",
                handler: { [presentation] invocation in
                    try await UIActions.finishTranscript(invocation: invocation) {
                        try await presentation.finishTranscript(invocation: $0)
                    }
                }),
            ActionDefinition(
                path: ActionPath(module: "UI", function: "setTranscript"), kind: .state,
                completion: "Presentation policy accepted transcript state or rejected a stale update.",
                handler: { [presentation] invocation in
                    try await UIActions.setTranscript(invocation: invocation) {
                        try await presentation.presentTranscript($0, invocation: $1)
                    }
                }),
            ActionDefinition(
                path: ActionPath(module: "UI", function: "beginReplyTurn"), kind: .state,
                completion: "Presentation policy accepted turn initialization or rejected a duplicate/stale update.",
                handler: { [presentation] invocation in
                    try await UIActions.beginReplyTurn(invocation: invocation) {
                        try await presentation.beginReplyTurn(invocation: $0)
                    }
                }),
            ActionDefinition(
                path: ActionPath(module: "UI", function: "setVoiceState"), kind: .state,
                completion: "Presentation policy accepted voice phase or rejected a stale update.",
                handler: { [presentation] invocation in
                    try await UIActions.setVoiceState(invocation: invocation) {
                        try await presentation.presentVoiceState($0, invocation: $1)
                    }
                }),
            ActionDefinition(
                path: ActionPath(module: "UI", function: "print"), kind: .finite,
                completion:
                    "Presentation policy accepted caption append or rejected a stale update; animation is not joined.",
                handler: { [presentation] invocation in
                    try await UIActions.print(invocation: invocation) {
                        try await presentation.present($0, invocation: $1)
                    }
                }),
            ActionDefinition(
                path: ActionPath(module: "UI", function: "moveEyes"), kind: .state,
                completion:
                    "Presentation owner accepted a gaze target or rejected a stale update; animation is not joined.",
                handler: { [presentation] invocation in
                    try await UIActions.moveEyes(invocation: invocation) {
                        try await presentation.present($0, invocation: $1)
                    }
                }),
            ActionDefinition(
                path: ActionPath(module: "UI", function: "express"), kind: .state,
                completion:
                    "Presentation policy accepted expression target or rejected a stale update; animation is not joined.",
                handler: { [presentation] invocation in
                    try await UIActions.express(invocation: invocation) {
                        try await presentation.presentExpression($0, invocation: $1)
                    }
                }),
        ]
    }
}
