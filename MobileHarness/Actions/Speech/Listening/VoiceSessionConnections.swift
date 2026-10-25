import Foundation
import FunctionContracts

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
