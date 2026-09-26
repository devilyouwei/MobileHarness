import Foundation

public protocol PoseCapability: Capability {
    func estimatePose(_ request: PoseRequest) async throws -> PoseResult
}
public struct PoseRequest: Sendable {
    public let image: ImageFrame
    public let context: InferenceContext
    public init(image: ImageFrame, context: InferenceContext = InferenceContext()) {
        self.image = image
        self.context = context
    }
}
/// COCO ordering, including left/right from the subject's perspective.
public enum BodyJoint: Int, CaseIterable, Sendable {
    case nose, leftEye, rightEye, leftEar, rightEar, leftShoulder, rightShoulder
    case leftElbow, rightElbow, leftWrist, rightWrist, leftHip, rightHip
    case leftKnee, rightKnee, leftAnkle, rightAnkle
}
/// Original-image pixel coordinates, top-left origin. Points outside the image are retained.
public struct PoseKeypoint: Sendable {
    public let joint: BodyJoint
    public let x: Float
    public let y: Float
    public let confidence: Float
    public init(joint: BodyJoint, x: Float, y: Float, confidence: Float) {
        self.joint = joint
        self.x = x
        self.y = y
        self.confidence = confidence
    }
}
public struct PoseBox: Sendable {
    public let x: Float
    public let y: Float
    public let width: Float
    public let height: Float
    public init(x: Float, y: Float, width: Float, height: Float) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}
public struct PersonPose: Sendable {
    public let box: PoseBox
    public let confidence: Float
    public let keypoints: [PoseKeypoint]
    public init(box: PoseBox, confidence: Float, keypoints: [PoseKeypoint]) {
        self.box = box
        self.confidence = confidence
        self.keypoints = keypoints
    }
}
public struct PoseResult: Sendable {
    public let context: InferenceContext
    public let people: [PersonPose]
    public init(context: InferenceContext, people: [PersonPose]) {
        self.context = context
        self.people = people
    }
}
