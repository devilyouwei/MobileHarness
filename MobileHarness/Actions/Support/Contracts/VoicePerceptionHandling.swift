import Foundation

/// Role policy and input lifetime only. This capability cannot operate hardware or render UI.
public protocol VoicePerceptionHandling: Sendable {
    func openCapture(sessionID: String) async throws
    func closeCapture() async
    func startInput(sessionID: String) async throws
    func waitForInput() async throws
    func stopInput() async
    func stopListening(sessionID: String) async throws
    func captureEnded(revision: UInt64, sessionID: String) async throws
    func acquirePlaybackAdmission() async -> Bool
    func resumeListening() async throws
    func isRunning() async -> Bool
    func stop() async
}
