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
