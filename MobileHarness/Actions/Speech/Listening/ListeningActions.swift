import Foundation
import FunctionContracts

extension SpeechActions {
    /// SpeechPerception uses this fixed registered function; it is absent from model catalogs.
    @Action(
        domain: "Speech", module: "Listening", title: "Listening status",
        doc:
            "Apply trusted listening consent/pause revision and join admitted startup children. Feedback plays only on a new wake, never automatic pause/resume. Internal SpeechPerception only.",
        parameters: [
            .init("enabled", type: .boolean, description: "Explicit listening consent."),
            .init("paused", type: .boolean, description: "Reply policy pause."),
            .init(
                "revision", type: .integer, description: "Monotonic trusted policy revision.",
                constraints: "Positive integer."),
            .init(
                "cue", required: false, description: "Wake cue; default wake.",
                values: ["wake", "confirm", "cancel", "error", "soft", "save"]),
            .init(
                "volume", type: .number, required: false, description: "Cue gain; default 0.85.",
                constraints: "Finite 0…1."),
            .init(
                "hapticStyle", required: false, description: "Wake impact style; default heavy.",
                values: ["light", "medium", "heavy", "rigid", "soft"]),
            .init(
                "hapticIntensity", type: .number, required: false, description: "Wake intensity; default 1.",
                constraints: "Finite 0…1."),
        ], kind: .finite,
        completion:
            "Listening policy and admitted activation children join; physical capture follows consent and playback barriers.",
        timeout: .seconds(90))
    public static func update(
        invocation: any FunctionInput,
        using apply: @escaping @Sendable (Bool, Bool, UInt64, ListeningFeedback) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        let arguments = ActionArguments(invocation.call.parameters)
        try arguments.validateAllowedKeys([
            "enabled", "paused", "revision", "cue", "volume", "hapticStyle", "hapticIntensity",
        ])
        let enabled = try arguments.requiredString("enabled", maximumUTF8Bytes: 5)
        let paused = try arguments.requiredString("paused", maximumUTF8Bytes: 5)
        let rawRevision = try arguments.requiredString("revision", maximumUTF8Bytes: 20)
        guard ["true", "false"].contains(enabled), ["true", "false"].contains(paused),
            let revision = UInt64(rawRevision), revision > 0
        else { throw ActionArguments.ValidationError.invalidValue("listening") }
        let cue: UIActions.Cue =
            invocation.call.parameters["cue"] == nil ? .wake : try arguments.requiredEnum("cue", as: UIActions.Cue.self)
        let volume =
            invocation.call.parameters["volume"] == nil
            ? 0.85 : try arguments.requiredFiniteDouble("volume", range: 0...1)
        let style: UIActions.HapticStyle =
            invocation.call.parameters["hapticStyle"] == nil
            ? .heavy : try arguments.requiredEnum("hapticStyle", as: UIActions.HapticStyle.self)
        let intensity =
            invocation.call.parameters["hapticIntensity"] == nil
            ? 1 : try arguments.requiredFiniteDouble("hapticIntensity", range: 0...1)
        let feedback = try ListeningFeedback(
            cue: UIActions.CueRequest(cue: cue, volume: volume),
            haptic: UIActions.HapticRequest(style: style, intensity: intensity))
        try await apply(enabled == "true", paused == "true", revision, feedback)
    }
}

extension SpeechActions {
    public static func prepareListeningFunction(using capability: any SpeechListeningGestureCapability)
        -> ActionFunction
    {
        ActionFunction(
            path: .init(domain: "Speech", module: "Listening", function: "prepare"),
            displayName: "Prepare listening feedback", kind: .state, completion: "completed", timeout: .seconds(5),
            handler: { invocation in
                let arguments = ActionArguments(invocation.call.parameters)
                try arguments.validateAllowedKeys(["pressed"])
                let raw = try arguments.requiredString("pressed", maximumUTF8Bytes: 5)
                guard ["true", "false"].contains(raw) else {
                    throw ActionArguments.ValidationError.invalidValue("pressed")
                }
                let pressed = raw == "true"
                try await capability.prepareListening(pressed: pressed, invocation: invocation)
            })
    }
}

// Public intent Actions never accept the internal policy revision or reply pause.
extension SpeechActions {
    @Action(
        domain: "Speech", module: "Listening", title: "Start listening",
        doc:
            "Enable listening.",
        kind: .finite, completion: "Activated.",
        timeout: .seconds(90))
    public static func startListening(
        invocation: any FunctionInput, using listening: any SpeechListeningCapability
    ) async throws {
        let arguments = ActionArguments(invocation.call.parameters)
        try arguments.validateAllowedKeys([])
        try Task.checkCancellation()
        try await listening.setListening(enabled: true, invocation: invocation)
        try Task.checkCancellation()
    }

    @Action(
        domain: "Speech", module: "Listening", title: "Stop listening",
        doc:
            "End conversation/listening.",
        kind: .finite, completion: "Capture stopped.",
        timeout: .seconds(90))
    public static func stopListening(
        invocation: any FunctionInput, using listening: any SpeechListeningCapability
    ) async throws {
        let arguments = ActionArguments(invocation.call.parameters)
        try arguments.validateAllowedKeys([])
        try Task.checkCancellation()
        try await listening.setListening(enabled: false, invocation: invocation)
        try Task.checkCancellation()
    }
}
