import Foundation

public struct ImageInput: Sendable {
    public let attachment: any Sendable
    public let width: Int
    public let height: Int
    public let sequence: UInt64
    public let timestamp: TimeInterval
    /// Optional native capture callback instant for latency measurement; media timestamp stays unchanged.
    public let capturedAt: ContinuousClock.Instant?
    /// Clockwise quarter turns applied to the camera sensor image to make these pixels upright.
    public let rotation: Int
    public init(
        width: Int, height: Int, attachment: any Sendable,
        sequence: UInt64, timestamp: TimeInterval, rotation: Int, capturedAt: ContinuousClock.Instant? = nil
    ) throws {
        guard (1...4096).contains(width), (1...4096).contains(height), width * height <= 4_194_304,
            timestamp.isFinite, timestamp >= 0, (0...3).contains(rotation)
        else { throw ImageInputError.invalidFrame }
        self.width = width
        self.height = height
        self.attachment = attachment
        self.sequence = sequence
        self.timestamp = timestamp
        self.capturedAt = capturedAt
        self.rotation = rotation
    }

}
public enum ImageInputError: Error, Equatable, Sendable { case invalidFrame }
