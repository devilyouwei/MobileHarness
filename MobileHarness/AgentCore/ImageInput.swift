import Foundation

/// Agent-owned transport, independent of ModelKit and camera frameworks.
/// Upright, unmirrored RGB8 with monotonic sequence/time within one capture session.
public struct ImageInput: Sendable {
    public let width: Int
    public let height: Int
    public let rgb: Data
    public let sequence: UInt64
    public let timestamp: TimeInterval
    /// Clockwise quarter turns applied to the camera sensor image to make these pixels upright.
    public let rotation: Int
    public init(width: Int, height: Int, rgb: Data, sequence: UInt64, timestamp: TimeInterval, rotation: Int) throws {
        guard (1...640).contains(width), (1...640).contains(height), rgb.count == width * height * 3,
            timestamp.isFinite, timestamp >= 0, (0...3).contains(rotation)
        else { throw ImageInputError.invalidFrame }
        self.width = width
        self.height = height
        self.rgb = rgb
        self.sequence = sequence
        self.timestamp = timestamp
        self.rotation = rotation
    }
}
public enum ImageInputError: Error, Equatable, Sendable { case invalidFrame, outOfOrder, wrongSession }
