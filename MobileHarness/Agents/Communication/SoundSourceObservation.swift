import Foundation

/// One dominant direction in the captured ACN/SN3D sound field, never a device command.
public struct SoundSourceObservation: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable { case active, inactive, uncertain, unavailable }
    public enum CoordinateFrame: String, Codable, Sendable { case ambisonicXFrontYLeftZUp }
    public struct Direction: Codable, Sendable, Equatable {
        public let x: Double
        public let y: Double
        public let z: Double
        public let azimuth: Double
        public let elevation: Double
        /// Angles are radians, azimuth positive toward Y (left).
        public init(x: Double, y: Double, z: Double) {
            self.x = x
            self.y = y
            self.z = z
            azimuth = atan2(y, x)
            elevation = atan2(z, hypot(x, y))
        }
    }
    public let state: State
    public let direction: Direction?
    /// Correlation quality, not a calibrated probability.
    public let quality: Double
    public let rms: Double
    public let timestamp: TimeInterval
    public let duration: TimeInterval
    public let coordinateFrame: CoordinateFrame
    public init(
        state: State, direction: Direction? = nil, quality: Double = 0, rms: Double = 0,
        timestamp: TimeInterval, duration: TimeInterval
    ) {
        self.state = state
        self.direction = direction
        self.quality = quality
        self.rms = rms
        self.timestamp = timestamp
        self.duration = duration
        coordinateFrame = .ambisonicXFrontYLeftZUp
    }
    public func validate() throws {
        guard quality.isFinite, (0...1).contains(quality), rms.isFinite, rms >= 0,
            timestamp.isFinite, timestamp >= 0, duration.isFinite, (0...0.101).contains(duration),
            (state == .active) == (direction != nil)
        else { throw SoundSourceValidationError.invalidObservation }
        if let direction {
            let length = direction.x * direction.x + direction.y * direction.y + direction.z * direction.z
            guard length.isFinite, abs(length - 1) < 0.000001,
                direction.azimuth.isFinite, direction.elevation.isFinite,
                abs(direction.azimuth - atan2(direction.y, direction.x)) < 0.000001,
                abs(direction.elevation - atan2(direction.z, hypot(direction.x, direction.y))) < 0.000001
            else { throw SoundSourceValidationError.invalidObservation }
        }
    }
}
public enum SoundSourceValidationError: Error, Sendable { case invalidObservation }
