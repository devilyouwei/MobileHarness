import Foundation
import FunctionContracts

extension UIActions {
    @Action(
        domain: "UI", module: "Feedback", title: "播放提示音",
        doc:
            "Play one bounded application cue and await actual native drain. Host controls audio admission; never replaces ongoing speech or recording.",
        parameters: [
            .init(
                "cue", type: .string, required: false, description: "Cue profile; default wake.",
                values: ["wake", "confirm", "cancel", "error", "soft", "save", "discard"]),
            .init(
                "volume", type: .number, required: false, description: "Relative PCM gain; default 0.85.",
                constraints: "Finite 0 through 1; system volume remains user-owned."),
        ], kind: .finite, completion: "Native cue playback drains and cleanup joins.", timeout: .seconds(5))
    public static func playCue(
        invocation: any FunctionInput,
        using play: @escaping @Sendable (CueRequest, any FunctionInput) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        let args = ActionArguments(invocation.call.parameters)
        try args.validateAllowedKeys(["cue", "volume"])
        let cue: Cue = invocation.call.parameters["cue"] == nil ? .wake : try args.requiredEnum("cue", as: Cue.self)
        let volume =
            invocation.call.parameters["volume"] == nil ? 0.85 : try args.requiredFiniteDouble("volume", range: 0...1)
        try await play(CueRequest(cue: cue, volume: volume), invocation)
        try Task.checkCancellation()
    }

    @Action(
        domain: "UI", module: "Feedback", title: "触觉反馈",
        doc:
            "Issue a short bounded native haptic pattern. Completes after the requested pulses are issued; does not prove perceived strength. Unsupported hardware and overlap fail explicitly.",
        parameters: [
            .init(
                "style", type: .string, required: false, description: "Impact style; default heavy.",
                values: ["light", "medium", "heavy", "rigid", "soft"]),
            .init(
                "intensity", type: .number, required: false, description: "Relative intensity; default 1.",
                constraints: "Finite 0 through 1."),
            .init(
                "count", type: .integer, required: false, description: "Number of pulses; default 1.",
                constraints: "Integer 1 through 3."),
            .init(
                "intervalMS", type: .integer, required: false, description: "Pulse spacing; default 80 milliseconds.",
                constraints: "Integer 40 through 250."),
        ], kind: .finite, completion: "All bounded impact requests are issued or cancellation joins.",
        timeout: .seconds(5))
    public static func vibrate(
        invocation: any FunctionInput,
        using impact: @escaping @Sendable (HapticRequest, any FunctionInput) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        let args = ActionArguments(invocation.call.parameters)
        try args.validateAllowedKeys(["style", "intensity", "count", "intervalMS"])
        let style: HapticStyle =
            invocation.call.parameters["style"] == nil ? .heavy : try args.requiredEnum("style", as: HapticStyle.self)
        let intensity =
            invocation.call.parameters["intensity"] == nil
            ? 1 : try args.requiredFiniteDouble("intensity", range: 0...1)
        let count = invocation.call.parameters["count"] == nil ? 1 : try args.requiredInt("count", range: 1...3)
        let interval =
            invocation.call.parameters["intervalMS"] == nil ? 80 : try args.requiredInt("intervalMS", range: 40...250)
        try await impact(
            HapticRequest(style: style, intensity: intensity, count: count, intervalMS: interval), invocation)
        try Task.checkCancellation()
    }
}
