import Foundation
import FunctionContracts

#if os(iOS)

    /// Execution dependencies. Actual role registration remains in Agents.
    @MainActor public struct VoiceSessionConnections {
        public let endpoints: ActionEndpoints
        public let interactionSessionID: String
        public let cancelReply: @MainActor () async throws -> Void
        public let playbackChanged: @Sendable (String, Bool) async -> Void
        public let playbackSpectrum: @MainActor ([Float], Bool) -> Void
        public let adaptFailure: @Sendable (any Error) -> any Error
        public init(
            endpoints: ActionEndpoints, interactionSessionID: String,
            cancelReply: @escaping @MainActor () async throws -> Void,
            adaptFailure: @escaping @Sendable (any Error) -> any Error,
            playbackChanged: @escaping @Sendable (String, Bool) async -> Void = { _, _ in },
            playbackSpectrum: @escaping @MainActor ([Float], Bool) -> Void = { _, _ in }
        ) {
            self.endpoints = endpoints
            self.interactionSessionID = interactionSessionID
            self.cancelReply = cancelReply
            self.adaptFailure = adaptFailure
            self.playbackChanged = playbackChanged
            self.playbackSpectrum = playbackSpectrum
        }
    }
#endif
