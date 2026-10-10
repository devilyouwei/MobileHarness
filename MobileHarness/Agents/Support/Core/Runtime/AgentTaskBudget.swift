import Foundation

/// Cumulative decision budget survives queue waits and round boundaries.
public struct AgentTaskBudget: Codable, Sendable {
    public let maximumRequests: Int
    public let maximumNativeCalls: Int
    public let maximumExecutionSeconds: Double
    public private(set) var requests = 0
    public private(set) var nativeCalls = 0
    public private(set) var executionSeconds: Double = 0
    public var remainingExecution: Duration { .seconds(max(0, maximumExecutionSeconds - executionSeconds)) }
    public init(maximumRequests: Int = 4, maximumNativeCalls: Int = 16, maximumExecutionSeconds: Double = 30) throws {
        guard (1...128).contains(maximumRequests), (1...128).contains(maximumNativeCalls),
            maximumExecutionSeconds.isFinite, maximumExecutionSeconds > 0, maximumExecutionSeconds <= 3600
        else { throw CommunicationError.invalidPayload }
        self.maximumRequests = maximumRequests
        self.maximumNativeCalls = maximumNativeCalls
        self.maximumExecutionSeconds = maximumExecutionSeconds
    }
    public func validate() throws {
        guard (1...128).contains(maximumRequests), (1...128).contains(maximumNativeCalls),
            maximumExecutionSeconds.isFinite, maximumExecutionSeconds > 0, maximumExecutionSeconds <= 3600,
            (0...maximumRequests).contains(requests), (0...maximumNativeCalls).contains(nativeCalls),
            executionSeconds.isFinite, executionSeconds >= 0
        else { throw CommunicationError.invalidPayload }
    }
    public mutating func reserveRequest() throws {
        try validate()
        guard requests < maximumRequests, executionSeconds < maximumExecutionSeconds else {
            throw CommunicationError.capacityExceeded
        }
        requests += 1
    }
    public mutating func reserveNativeCall() throws {
        try validate()
        guard nativeCalls < maximumNativeCalls else { throw CommunicationError.capacityExceeded }
        nativeCalls += 1
    }
    public mutating func charge(_ duration: Duration) throws {
        try validate()
        let parts = duration.components
        let seconds = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
        guard seconds.isFinite, seconds >= 0 else { throw CommunicationError.invalidPayload }
        executionSeconds += seconds
        guard executionSeconds <= maximumExecutionSeconds else { throw CommunicationError.expired }
    }
}
