import FunctionContracts

extension SpeechActions {
    public static func detectionFunction(using capability: any AudioDetectionCapability) -> ActionFunction {
        ActionFunction(
            path: .init(domain: "Speech", module: "Detection", function: "run"),
            displayName: "Detect audio", kind: .finite, completion: "completed", timeout: .seconds(120),
            handler: { invocation in
                try ActionArguments(invocation.call.parameters).validateAllowedKeys([])
                try await capability.runDetection(invocation: invocation)
            })
    }
}
