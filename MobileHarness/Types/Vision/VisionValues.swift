import Foundation

public enum VisionValidationError: Error, Equatable, Sendable { case invalidObservation }

/// Upright, unmirrored pixel coordinates; display quantization is a consumer policy.
public struct PoseObservation: Codable, Equatable, Sendable {
    public struct Joint: Codable, Equatable, Sendable {
        public let x: Float
        public let y: Float
        public let confidence: Float
        public init(x: Float, y: Float, confidence: Float) {
            self.x = x
            self.y = y
            self.confidence = confidence
        }
    }
    public let width: Int
    public let height: Int
    public let sequence: UInt64
    public let timestamp: TimeInterval
    public let rotation: Int
    public let people: [[Joint]]
    public init(width: Int, height: Int, sequence: UInt64, timestamp: TimeInterval, rotation: Int, people: [[Joint]])
        throws
    {
        self.width = width
        self.height = height
        self.sequence = sequence
        self.timestamp = timestamp
        self.rotation = rotation
        self.people = people
        try validate()
    }
    public func validate() throws {
        guard (1...4096).contains(width), (1...4096).contains(height), (0...3).contains(rotation),
            timestamp.isFinite, timestamp >= 0, people.count <= 300,
            people.allSatisfy({
                $0.count == 17
                    && $0.allSatisfy {
                        $0.x.isFinite && $0.y.isFinite && $0.confidence.isFinite && (0...1).contains($0.confidence)
                    }
            })
        else { throw VisionValidationError.invalidObservation }
    }
}

/// Shared skeleton presentation values, independent of Agent and Tool execution. Integer coordinates use 1/10000 image units.
public struct PoseOverlay: Codable, Sendable, Equatable {
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

/// Shared image transport, independent of Agents, ModelKit and camera frameworks.
/// Upright, unmirrored RGB8 with monotonic sequence/time within one capture session.
public protocol ImageAttachment: Sendable {}

public struct ImageInput: Sendable {
    public enum Content: Sendable {
        case rgb(Data)
        case attachment(any ImageAttachment)
    }
    public let content: Content
    public let width: Int
    public let height: Int
    public let sequence: UInt64
    public let timestamp: TimeInterval
    /// Optional native capture callback instant for latency measurement; media timestamp stays unchanged.
    public let capturedAt: ContinuousClock.Instant?
    /// Clockwise quarter turns applied to the camera sensor image to make these pixels upright.
    public let rotation: Int
    public init(
        width: Int, height: Int, rgb: Data, sequence: UInt64, timestamp: TimeInterval, rotation: Int,
        capturedAt: ContinuousClock.Instant? = nil
    ) throws {
        guard (1...640).contains(width), (1...640).contains(height), rgb.count == width * height * 3,
            timestamp.isFinite, timestamp >= 0, (0...3).contains(rotation)
        else { throw ImageInputError.invalidFrame }
        self.width = width
        self.height = height
        self.content = .rgb(rgb)
        self.sequence = sequence
        self.timestamp = timestamp
        self.capturedAt = capturedAt
        self.rotation = rotation
    }
    public init(
        width: Int, height: Int, attachment: any ImageAttachment,
        sequence: UInt64, timestamp: TimeInterval, rotation: Int, capturedAt: ContinuousClock.Instant? = nil
    ) throws {
        guard (1...4096).contains(width), (1...4096).contains(height), width * height <= 4_194_304,
            timestamp.isFinite, timestamp >= 0, (0...3).contains(rotation)
        else { throw ImageInputError.invalidFrame }
        self.width = width
        self.height = height
        content = .attachment(attachment)
        self.sequence = sequence
        self.timestamp = timestamp
        self.capturedAt = capturedAt
        self.rotation = rotation
    }

}
public enum ImageInputError: Error, Equatable, Sendable { case invalidFrame, outOfOrder, wrongSession }
