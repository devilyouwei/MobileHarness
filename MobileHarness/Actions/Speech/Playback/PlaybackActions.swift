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
            "Set the target volume of the caller’s current speech playback. The playback position and state are preserved.",
        parameters: [
            .init("volume", type: .number, description: "Normalized playback volume from 0 to 1."),
            .init(
                "executionID", required: false,
                description: "Target speak execution. Defaults to the current owned playback."),
        ], kind: .finite, completion: "The playback owner accepted the target volume.", timeout: .seconds(3))
    public static func setVolume(
        invocation: any FunctionInput,
        using apply: @escaping @Sendable (Double, UUID?, any FunctionInput) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        let arguments = ActionArguments(invocation.call.parameters)
        try arguments.validateAllowedKeys(["volume", "executionID"])
        let volume = try arguments.requiredFiniteDouble("volume", range: 0...1)
        let executionID: UUID?
        if invocation.call.parameters["executionID"] == nil {
            executionID = nil
        } else {
            let value = try arguments.requiredString("executionID", maximumUTF8Bytes: 36)
            guard let parsed = UUID(uuidString: value) else {
                throw ActionArguments.ValidationError.invalidValue("executionID")
            }
            executionID = parsed
        }
        try await apply(volume, executionID, invocation)
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

    func setVolume(_ value: Double) throws {
        guard value.isFinite, (0...1).contains(value) else {
            throw ActionHostError.invalidPayload
        }
        gain = Float(value)
        if !paused { audioControl.set(.playing(volume: gain)) }
    }
}
