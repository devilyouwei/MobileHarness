import ActionRuntime
import Foundation

/// Bounded UI action data, not a model/backend type. Integer coordinates use 1/10000 image units.
public struct ToolPoseOverlay: Codable, Sendable, Equatable {
    public let sequence: UInt64
    public let timestamp: TimeInterval
    public let rotation: Int
    /// At most six people in confidence order, each with all 17 COCO joints.
    public let people: [[Joint]]
    public let statistics: Statistics?
    public init(
        sequence: UInt64, timestamp: TimeInterval, rotation: Int, people: [[Joint]],
        statistics: Statistics? = nil
    ) {
        self.sequence = sequence
        self.timestamp = timestamp
        self.rotation = rotation
        self.people = people
        self.statistics = statistics
    }
    /// Measurements end when the pose result returns, before UI rendering.
    public struct Statistics: Codable, Sendable, Equatable {
        public let queueMilliseconds: Double?
        public let inferenceMilliseconds: Double
        public let totalMilliseconds: Double?
        public let framesPerSecond: Double?
        public let replacements: Int
        public let detectionIntervalMilliseconds: Double?
        public let imageMotion: Double?
        public init(
            queueMilliseconds: Double?, inferenceMilliseconds: Double, totalMilliseconds: Double?,
            framesPerSecond: Double?, replacements: Int, detectionIntervalMilliseconds: Double? = nil,
            imageMotion: Double? = nil
        ) {
            self.queueMilliseconds = queueMilliseconds
            self.inferenceMilliseconds = inferenceMilliseconds
            self.totalMilliseconds = totalMilliseconds
            self.framesPerSecond = framesPerSecond
            self.replacements = replacements
            self.detectionIntervalMilliseconds = detectionIntervalMilliseconds
            self.imageMotion = imageMotion
        }
        public var isValid: Bool {
            let values = [
                queueMilliseconds, inferenceMilliseconds, totalMilliseconds, framesPerSecond,
                detectionIntervalMilliseconds, imageMotion,
            ]
            guard values.allSatisfy({ $0.map { $0.isFinite && $0 >= 0 } ?? true }), replacements >= 0 else {
                return false
            }
            if let detectionIntervalMilliseconds, detectionIntervalMilliseconds > 1000 { return false }
            if let imageMotion, imageMotion > 1 { return false }
            guard let queueMilliseconds, let totalMilliseconds else {
                return queueMilliseconds == nil && totalMilliseconds == nil
            }
            return totalMilliseconds >= queueMilliseconds + inferenceMilliseconds - 0.001
        }
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
