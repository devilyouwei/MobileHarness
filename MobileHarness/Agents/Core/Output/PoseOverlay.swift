import Foundation

/// Bounded UI action data, not a model/backend type. Integer coordinates use 1/10000 image units.
public struct PoseOverlay: Codable, Sendable, Equatable {
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
            guard values.isAtEnd else { throw ImageInputError.invalidFrame }
        }
        public func encode(to encoder: any Encoder) throws {
            var values = encoder.unkeyedContainer()
            try values.encode(x)
            try values.encode(y)
            try values.encode(confidence)
        }
        /// Undo upright rotation; native preview conversion subsequently handles crop/mirroring.
        public func sensorPoint(rotation: Int) -> (x: Double, y: Double) {
            let x = Double(x) / 10000
            let y = Double(y) / 10000
            switch rotation {
            case 1: return (y, 1 - x)
            case 2: return (1 - x, 1 - y)
            case 3: return (1 - y, x)
            default: return (x, y)
            }
        }
    }
}
