import Foundation
import ModelKit

/// Pure revision/order policy for one ASR segment; no runtime or presentation effects.
struct TranscriptAccumulator {
    let prefix: String
    private var segments: [UUID: TranscriptionEvent] = [:]
    private var order: [UUID] = []

    init(prefix: String = "") { self.prefix = prefix }

    mutating func accept(_ event: TranscriptionEvent) throws -> String? {
        guard event.text.utf8.count <= 16384 else { throw CapabilityError.eventTooLarge }
        if let old = segments[event.segmentID], old.isFinal || old.revision >= event.revision { return nil }
        var candidateOrder = order
        if segments[event.segmentID] == nil {
            guard order.count < 64 else { throw CapabilityError.eventTooLarge }
            candidateOrder.append(event.segmentID)
        }
        var candidate = segments
        candidate[event.segmentID] = event
        let current = candidateOrder.compactMap { candidate[$0]?.text }.joined(separator: " ")
        let visible = prefix.isEmpty ? current : current.isEmpty ? prefix : prefix + " " + current
        guard visible.utf8.count <= 65536 else { throw CapabilityError.eventTooLarge }
        order = candidateOrder
        segments = candidate
        return visible
    }

    var finalText: String {
        order.compactMap { segments[$0].flatMap { $0.isFinal ? $0.text : nil } }.joined(separator: " ")
    }
}
