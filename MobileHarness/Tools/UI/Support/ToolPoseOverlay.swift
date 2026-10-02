import Foundation
import ToolRuntime

/// Bounded UI action data, not a model/backend type. Integer coordinates use 1/10000 image units.
public struct ToolPoseOverlay: Codable, Sendable, Equatable {
    public let sequence: UInt64
    public let timestamp: TimeInterval
    public let rotation: Int
    /// At most six people in confidence order, each with all 17 COCO joints.
    public let people: [[Joint]]
    public init(sequence: UInt64, timestamp: TimeInterval, rotation: Int, people: [[Joint]]) {
        self.sequence = sequence
        self.timestamp = timestamp
        self.rotation = rotation
        self.people = people
    }
    public struct Joint: Codable, Sendable, Equatable {
        public let x: Int
        public let y: Int
        public let confidence: Int
        public init(x: Int, y: Int, confidence: Int) {
            self.x = x
            self.y = y
            self.confidence = confidence
        }
        public init(from decoder: any Decoder) throws {
            var values = try decoder.unkeyedContainer()
            x = try values.decode(Int.self)
            y = try values.decode(Int.self)
            confidence = try values.decode(Int.self)
            guard values.isAtEnd else {
                throw DecodingError.dataCorruptedError(
                    in: values, debugDescription: "Expected exactly three joint values")
            }
        }
        public func encode(to encoder: any Encoder) throws {
            var values = encoder.unkeyedContainer()
            try values.encode(x)
            try values.encode(y)
            try values.encode(confidence)
        }
    }
}
