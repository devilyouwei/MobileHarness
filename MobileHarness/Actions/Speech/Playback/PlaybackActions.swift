import Foundation
import FunctionContracts
import PlatformKit
import StorageCore

/// Speech.Playback function ownership; current invocation paths remain compatible.
extension SpeechActions {
    /// Play an existing single-use audio handle; never synthesize text here.
    @Action(
        domain: "Speech", module: "Playback", title: "Read reply aloud",
        doc: "Play the synthesized reply audio identified by audioID until playback drains.", kind: .finite,
        completion: "Playback drained and audio lease released.", timeout: .seconds(300))
    public static func speak(
        invocation: any FunctionInput,
        using play: @escaping @Sendable (String, any FunctionInput) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        let id: String
        do {
            let arguments = ActionArguments(invocation.call.parameters)
            try arguments.validateAllowedKeys(["audioID"])
            let value = try arguments.requiredString("audioID", maximumUTF8Bytes: 36, allowBlank: false)
            guard let parsed = UUID(uuidString: value) else { throw SpeechActionError.missingAudio }
            id = parsed.uuidString
        } catch { throw SpeechActionError.missingAudio }
        try await play(id, invocation)
        try Task.checkCancellation()
    }

    @Action(
        domain: "Speech", module: "Playback", title: "Set speech playback volume",
        doc:
            "Set the target volume for current and subsequent speech playback, including while idle.",
        parameters: [
            .init("volume", type: .number, description: "Normalized playback volume from 0 to 1.")
        ], kind: .finite, completion: "The target speech volume is set.", timeout: .seconds(3))
    public static func setVolume(
        invocation: any FunctionInput,
        using apply: @escaping @Sendable (Double) async -> Void
    ) async throws {
        try Task.checkCancellation()
        let arguments = ActionArguments(invocation.call.parameters)
        try arguments.validateAllowedKeys(["volume"])
        let volume = try arguments.requiredFiniteDouble("volume", range: 0...1)
        await apply(volume)
    }
}

struct SpeechPlaybackExecution: ActionExecutable {
    let playback: any SpeechPlaybackCapability

    func execute(_ invocation: any FunctionInput) async throws -> ActionCompletion {
        try await SpeechActions.speak(invocation: invocation) {
            try await playback.play(audioID: $0, invocation: $1)
        }
        return .completed
    }
}

/// Keeps gain and transport state for one speak execution.
@MainActor final class SpeechPlaybackControl: ActionPauseControl {
    let audioControl = AudioPlaybackControl()
    private var gain: Float = 1
    private var paused = false

    func pause() async throws {
        paused = true
        audioControl.set(.paused)
        try await audioControl.waitUntilPlaying(false)
    }

    func resume() async throws {
        paused = false
        audioControl.set(.playing(volume: gain))
        try await audioControl.waitUntilPlaying(true)
    }

    func setVolume(_ value: Double) {
        gain = Float(value)
        if !paused { audioControl.set(.playing(volume: gain)) }
    }
}
