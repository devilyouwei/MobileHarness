import Foundation

@MainActor public struct AudioDetectionPerception {
    public let perception: any VoicePerceptionHandling
    public let stop: @MainActor () async -> Void
    public init(perception: any VoicePerceptionHandling, stop: @escaping @MainActor () async -> Void) {
        self.perception = perception
        self.stop = stop
    }
}

public enum DetectionObservation<Layout: Sendable, Direction: Sendable>: Sendable {
    case microphone(Layout, Int, Float, ContinuousClock.Instant)
    case direction(Direction, Double?, Double?, ContinuousClock.Instant?)
}
@MainActor public struct DetectionConnections<Input: Sendable, Observation: Sendable> {
    public let makePerception:
        @MainActor (
            String, Input, @escaping @MainActor (Observation) -> Void,
            @escaping @MainActor (any Error) async -> Void
        ) async throws -> AudioDetectionPerception
    public init(
        makePerception:
            @escaping @MainActor (
                String, Input, @escaping @MainActor (Observation) -> Void,
                @escaping @MainActor (any Error) async -> Void
            ) async throws -> AudioDetectionPerception
    ) { self.makePerception = makePerception }
}
@MainActor public protocol SpectrumPresenting: Sendable {
    func begin(sessionID: String, captureGeneration: String) throws -> UUID
    @discardableResult func present(_ spectrum: [Float], using handle: UUID) throws -> Bool
    @discardableResult func finish(_ handle: UUID) -> Bool
}
