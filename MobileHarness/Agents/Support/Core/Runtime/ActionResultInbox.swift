import Foundation

/// Agent-owned receipt history, not a work queue. Duplicate admission is acknowledged without reprocessing.
public struct ActionResultInbox: Sendable {
    private var values: [ActionResult] = []
    private let capacity: Int
    public private(set) var evictedCount: UInt64 = 0

    public init(capacity: Int = 128) {
        precondition((1...512).contains(capacity))
        self.capacity = capacity
    }

    @discardableResult
    public mutating func accept(_ result: ActionResult) -> Bool {
        guard !values.contains(where: { $0.executionID == result.executionID }) else { return false }
        if values.count == capacity {
            values.removeFirst()
            evictedCount &+= 1
        }
        values.append(result)
        return true
    }

    public var results: [ActionResult] { values }
}
