import Foundation

/// Session-owned playback of an already decoded handle, including checkout, drain and cleanup.
public protocol SpeechPlaybackCapability: Sendable {
    func play(audioID: UUID, invocation: ActionInvocation) async throws
}
