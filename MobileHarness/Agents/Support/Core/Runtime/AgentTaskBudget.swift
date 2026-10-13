import Foundation

/// Optional caller policy and cumulative usage; default lifetime is completion/cancellation-owned.
public struct AgentTaskBudget: Codable, Sendable {
    public let maximumRequests: Int?
    public let maximumNativeCalls: Int?
    public private(set) var requests = 0
    public private(set) var nativeCalls = 0
    public init(maximumRequests: Int? = nil, maximumNativeCalls: Int? = nil) throws {
        guard maximumRequests.map({ $0 > 0 }) ?? true, maximumNativeCalls.map({ $0 > 0 }) ?? true
        else { throw CommunicationError.invalidPayload }
        self.maximumRequests = maximumRequests
        self.maximumNativeCalls = maximumNativeCalls
    }
    public func validate() throws {
        guard requests >= 0, nativeCalls >= 0,
            maximumRequests.map({ $0 > 0 && requests <= $0 }) ?? true,
            maximumNativeCalls.map({ $0 > 0 && nativeCalls <= $0 }) ?? true
        else { throw CommunicationError.invalidPayload }
    }
    public mutating func reserveRequest() throws {
        try validate()
        if let maximumRequests, requests >= maximumRequests { throw CommunicationError.capacityExceeded }
        if requests < Int.max { requests += 1 }
    }
    public mutating func reserveNativeCall() throws {
        try validate()
        if let maximumNativeCalls, nativeCalls >= maximumNativeCalls { throw CommunicationError.capacityExceeded }
        if nativeCalls < Int.max { nativeCalls += 1 }
    }
}
