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
        let duplicate = values.contains { existing in
            if let executionID = result.executionID { return existing.executionID == executionID }
            return existing.executionID == nil && result.callID != nil && existing.callID == result.callID
                && existing.roundID == result.roundID && existing.owner == result.owner
        }
        guard !duplicate else { return false }
        if values.count == capacity {
            values.removeFirst()
            evictedCount &+= 1
        }
        values.append(result)
        return true
    }

    public var results: [ActionResult] { values }
}
