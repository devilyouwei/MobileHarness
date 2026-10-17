import Foundation

/// Agent input image transport, independent of Agents, ModelKit and camera frameworks.
/// Upright, unmirrored RGB8 with monotonic sequence/time within one capture session.
public protocol ImageAttachment: Sendable {}

/// Opaque retained native value. No platform or image-analysis dependency enters this target.
public struct ImageValueAttachment<Value: Sendable>: ImageAttachment {
    public let value: Value
    public init(_ value: Value) { self.value = value }
}

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
public enum ImageInputError: Error, Equatable, Sendable { case invalidFrame }
