import Foundation

/// VisionPerception output wire contract for the showPose Tool. Integer coordinates use 1/10000 image units.
struct PoseOverlayPayload: Encodable, Sendable {
    let sequence: UInt64
    let timestamp: TimeInterval
    let rotation: Int
    /// At most six people in confidence order, each with all 17 COCO joints.
    let people: [[Joint]]
    let statistics: Statistics?
    init(
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
    struct Statistics: Encodable, Sendable {
        let queueMilliseconds: Double?
        let inferenceMilliseconds: Double
        let totalMilliseconds: Double?
        let framesPerSecond: Double?
        let replacements: Int
        let detectionIntervalMilliseconds: Double?
        let imageMotion: Double?
        init(
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
    }

    struct Joint: Encodable, Sendable {
        let x: Int
        let y: Int
        let confidence: Int
        func encode(to encoder: any Encoder) throws {
            var values = encoder.unkeyedContainer()
            try values.encode(x)
            try values.encode(y)
            try values.encode(confidence)
        }
    }
}
