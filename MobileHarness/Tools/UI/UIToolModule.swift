public struct UIToolModule: ToolModule {
    private let presentation: any PosePresentationCapability
    public init(presentation: any PosePresentationCapability) { self.presentation = presentation }
    public var definitions: [ToolDefinition] {
        [
            ToolDefinition(
                path: "UI.showPose",
                completing: { [presentation] call, envelope in
                    try await UITools.showPose(call: call, envelope: envelope) {
                        try await presentation.present($0, sessionID: $1.sessionID)
                    }
                })
        ]
    }
}
