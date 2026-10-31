import Foundation
import FunctionContracts
import StorageCore

/// Session-owned playback of an already decoded handle, including checkout, drain and cleanup.
public protocol SpeechPlaybackCapability: Sendable {
    func play(audioID: String, invocation: any FunctionInput) async throws
}

public protocol SpeechListeningCapability: Sendable {
    func setListening(enabled: Bool, invocation: any FunctionInput) async throws
    func updateListening(
        enabled: Bool, paused: Bool, revision: UInt64, feedback: SpeechActions.ListeningFeedback,
        invocation: any FunctionInput) async throws
}

public protocol SpeechListeningGestureCapability: Sendable {
    func prepareListening(pressed: Bool, invocation: any FunctionInput) async throws
}

extension SpeechListeningCapability {
    public func setListening(enabled: Bool, invocation: any FunctionInput) async throws {
        throw SpeechActionError.listeningUnavailable
    }
}
