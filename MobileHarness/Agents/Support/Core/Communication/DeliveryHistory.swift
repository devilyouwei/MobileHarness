import Foundation

/// Bounded diagnostics owned by one messaging port; contains no transport queue or retry.
public actor DeliveryHistory {
    public struct Entry: Sendable {
        public let inputID: UUID
        public let contract: String
        public let report: DeliveryReport
    }
    private var entries: [Entry] = []
    public private(set) var evictedCount = 0
    public func record(inputID: UUID, contract: String, report: DeliveryReport) {
        if entries.count == 128 {
            entries.removeFirst()
            evictedCount += 1
        }
        entries.append(Entry(inputID: inputID, contract: contract, report: report))
    }
    public func snapshot() -> [Entry] { entries }
}
