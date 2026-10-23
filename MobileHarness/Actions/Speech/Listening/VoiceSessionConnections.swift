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

#if os(iOS)

    /// Execution dependencies. Actual role registration remains in Agents.
    @MainActor public struct VoiceSessionConnections {
        public let endpoints: ActionEndpoints
        public let interactionSessionID: String
        public let cancelReply: @MainActor () async throws -> Void
        public let adaptFailure: @Sendable (any Error) -> any Error
        public init(
            endpoints: ActionEndpoints, interactionSessionID: String,
            cancelReply: @escaping @MainActor () async throws -> Void,
            adaptFailure: @escaping @Sendable (any Error) -> any Error
        ) {
            self.endpoints = endpoints
            self.interactionSessionID = interactionSessionID
            self.cancelReply = cancelReply
            self.adaptFailure = adaptFailure
        }
    }
#endif
