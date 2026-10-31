import Foundation

/// Role policy and input lifetime only. This capability cannot operate hardware or render UI.
public protocol VoicePerceptionHandling: Sendable {
    func openCapture(sessionID: String) async throws
    func closeCapture() async
    func startInput(sessionID: String) async throws
    func waitForInput() async throws
    func stopInput() async
    func setListening(enabled: Bool, sessionID: String) async throws -> SpeechActions.ListeningPolicy
    func stopListening(sessionID: String) async throws
    func captureEnded(revision: UInt64, sessionID: String) async throws
    func acquirePlaybackAdmission() async -> Bool
    func resumeListening() async throws
    func isRunning() async -> Bool
    func stop() async
}

extension VoicePerceptionHandling {
    public func setListening(enabled: Bool, sessionID: String) async throws -> SpeechActions.ListeningPolicy {
        throw SpeechActionError.listeningUnavailable
    }
}
