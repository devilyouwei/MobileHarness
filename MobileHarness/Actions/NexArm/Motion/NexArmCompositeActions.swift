import Foundation
import FunctionContracts
import PlatformKit

/// Presets own gesture geometry; callers select bounded repetition and native motion options.
public enum NexArmGesture: Sendable, CaseIterable {
    /// Ordinary arm reset home for passive links; device IK resolves Cartesian geometry on other paths.
    /// The sixth reference is not sent by whole-arm reset or presets. This is not measured feedback.
    public static let referenceHomeJoints = [2048, 2087, 1198, 1238, 2048, 2048]
    case baseSway, nod, shakeHead, wave, tiltLeft, tiltRight, lookAround, celebrate, dance

    public var displayName: String {
        switch self {
        case .baseSway: "底座晃动"
        case .nod: "点头"
        case .shakeHead: "摇头"
        case .wave: "挥手"
        case .tiltLeft, .tiltRight: "歪头"
        case .lookAround: "左右张望"
        case .celebrate: "庆祝"
        case .dance: "小舞蹈"
        }
    }
    /// Finite gesture intent. CMD8 geometry MUST be compiled by NexArmArmPlan before sending.
    public struct TestFrame: Sendable {
        public let packet: NexArmPacket
        public let milliseconds: Int
        public init(packet: NexArmPacket, milliseconds: Int) {
            self.packet = packet
            self.milliseconds = milliseconds
        }
    }
    public func settingsTestFrames() throws -> [TestFrame] {
        if motorID != nil {
            return try NexArmSimpleActions.frames(self, home: NexArmGesture.referenceHomeJoints, repetitions: 1)
        }
        return try cartesianPlaybackFrames(repetitions: 1)
    }
    /// Shared geometry and nominal choreography beats; callers select submission or feedback completion.
    func cartesianPlaybackFrames(repetitions: Int) throws -> [TestFrame] {
        guard motorID == nil, (1...3).contains(repetitions),
            (self != .tiltLeft && self != .tiltRight) || repetitions == 1
        else { throw NexArmExecutionError.invalidArguments }
        let poses = [Self.home] + (0..<repetitions).flatMap { _ in frames } + [Self.home]
        guard poses.count <= 20, poses.allSatisfy(Self.validPose) else { throw NexArmExecutionError.invalidArguments }
        return try poses.enumerated().map { index, pose in
            let duration = index == 0 ? 400 : (index == poses.count - 1 ? 600 : 800)
            let values = [pose[3], pose[0], pose[1], pose[2], pose[4], pose[5], duration]
            let packet = try NexArmPacket(
                command: 8,
                payload: values.flatMap { value -> [UInt8] in
                    let bits = UInt16(bitPattern: Int16(value))
                    return [UInt8(bits & 255), UInt8(bits >> 8)]
                })
            return TestFrame(packet: packet, milliseconds: duration)
        }
    }
    public var motorID: Int? {
        switch self {
        case .nod: 4
        case .shakeHead: 5
        default: nil
        }
    }
    public func headFrames(center: [Int]) throws -> [TestFrame] {
        try NexArmSimpleActions.sweeps(self, home: center)
    }
    public var lockedMotors: Set<Int> { motorID.map { [$0] } ?? Set(1...5) }

    static func homeFrame(milliseconds: Int) throws -> TestFrame {
        return try poseFrame(home, milliseconds: milliseconds)
    }
    static func poseFrame(_ pose: [Int], milliseconds: Int) throws -> TestFrame {
        let values = [pose[3], pose[0], pose[1], pose[2], pose[4], pose[5], milliseconds]
        return TestFrame(
            packet: try NexArmPacket(
                command: 8,
                payload: values.flatMap { value -> [UInt8] in
                    let bits = UInt16(bitPattern: Int16(value))
                    return [UInt8(bits & 255), UInt8(bits >> 8)]
                }), milliseconds: milliseconds)
    }
    static func validPose(_ pose: [Int]) -> Bool {
        pose.count == 6 && hypot(Double(pose[0]), Double(pose[1])) <= 450
            && (50...600).contains(pose[2]) && abs(pose[3]) <= 1800
            && abs(pose[4]) <= 180 && abs(pose[5]) <= 180
    }
    static let home = [200, 0, 200, 0, 0, 0]

    /// Absolute XYZ(mm), pitch(tenths of degree), roll/claw(degrees).
    var frames: [[Int]] {
        func pose(_ yaw: Int, _ roll: Int, height: Int = 240) -> [Int] {
            let angle = Double(yaw) * .pi / 180
            return [Int((200 * cos(angle)).rounded()), Int((200 * sin(angle)).rounded()), height, 0, roll, 0]
        }
        switch self {
        case .nod, .shakeHead: return []  // These use calibrated single-motor frames, never Cartesian body frames.
        case .baseSway: return [pose(-30, 0), pose(30, 0), pose(0, 0)]
        case .wave: return [pose(-12, -40), pose(12, 40), pose(-12, -40), pose(12, 40)]
        // Left/right are the arm’s own directions, as viewed from behind facing forward.
        case .tiltLeft: return [pose(12, 40)]
        case .tiltRight: return [pose(-12, -40)]
        case .lookAround: return [pose(-35, -15), pose(35, 15), pose(0, 0)]
        case .celebrate:
            return [
                pose(-20, -45, height: 270), pose(20, 45, height: 270),
                pose(-20, -35, height: 220), pose(20, 35, height: 270),
            ]
        case .dance:
            return [
                pose(-30, -40, height: 260), pose(30, 40, height: 220),
                pose(-30, 40, height: 260), pose(30, -40, height: 220), pose(-15, -30), pose(15, 30),
            ]
        }
    }

}

/// Connection-local device IK, compiled into five addressed servo writes. No gripper target is emitted.
public struct NexArmArmPlan: Sendable {
    private var targets: [[UInt8]: [Int]] = [:]
    public init() {}
    private func key(_ frame: NexArmGesture.TestFrame) -> [UInt8] { Array(frame.packet.payload.prefix(10)) }
    public func contains(_ frame: NexArmGesture.TestFrame) -> Bool { targets[key(frame)] != nil }

    public mutating func insert(_ frame: NexArmGesture.TestFrame, reply: NexArmPacket) throws {
        guard frame.packet.command == 8, frame.packet.payload.count == 14,
            reply.id == 255, reply.command == 7, reply.payload.count == 24
        else { throw NexArmError.invalidPacket }
        let requested = Self.words(frame.packet.payload)
        let values = Self.words(reply.payload)
        guard Array(values.prefix(5)) == [requested[1], requested[2], requested[3], requested[0], requested[4]]
        else { throw NexArmExecutionError.invalidArguments }
        let joints = Array(values[6..<11])
        guard zip(joints, NexArmJogPlanner.limits).allSatisfy({ $1.contains($0) }) else {
            throw NexArmExecutionError.invalidArguments
        }
        guard targets[key(frame)] != nil || targets.count < 64 else { throw NexArmError.overflow }
        targets[key(frame)] = joints
    }

    public var homeJoints: [Int] {
        get throws {
            let frame = try NexArmGesture.homeFrame(milliseconds: 1000)
            guard let arm = targets[key(frame)] else { throw NexArmExecutionError.invalidArguments }
            return arm + [0]  // Claw is neither commanded nor used by an arm plan.
        }
    }

    public func motion(_ gesture: NexArmGesture, repetitions: Int, from joints: [Int]) throws -> NexArmMotionPlan {
        let frames: [NexArmGesture.TestFrame]
        if gesture.motorID != nil {
            frames = try NexArmSimpleActions.frames(gesture, home: homeJoints, repetitions: repetitions)
        } else {
            frames = try compile(gesture.cartesianPlaybackFrames(repetitions: repetitions), from: joints)
        }
        return try NexArmMotionPlan(lockedMotors: gesture.lockedMotors, frames: frames)
    }

    public func home(from joints: [Int]) throws -> NexArmGesture.TestFrame {
        try compile([NexArmGesture.homeFrame(milliseconds: 2000)], from: joints)[0]
    }

    public func compile(_ frames: [NexArmGesture.TestFrame], from joints: [Int]) throws -> [NexArmGesture.TestFrame] {
        guard joints.count == 6, joints.allSatisfy({ NexArmDeviceLimits.encoderCounts.contains($0) }),
            frames.count <= 20
        else {
            throw NexArmExecutionError.invalidArguments
        }
        return try frames.map { frame in
            if frame.packet.command == 3, let index = Int(exactly: frame.packet.id), (4...5).contains(index),
                frame.packet.isObservedControl
            {
                return frame
            }
            guard let target = targets[key(frame)], frame.packet.command == 8, frame.packet.payload.count == 14,
                (400...2000).contains(frame.milliseconds)
            else { throw NexArmExecutionError.invalidArguments }
            let atoms = try (0..<5).map { index in
                try NexArmMotorCommands.move(motor: index + 1, target: target[index], options: NexArmMotorOptions())
            }
            return NexArmGesture.TestFrame(
                packet: try NexArmMotorCommands.simultaneous(atoms), milliseconds: frame.milliseconds)
        }
    }

    /// Command estimate for manual takeover, never reported as measured feedback; preserves motor6.
    public static func applying(_ packet: NexArmPacket, to previous: [Int]) throws -> [Int] {
        guard previous.count == 6 else { throw NexArmExecutionError.invalidArguments }
        var result = previous
        guard let targets = packet.motorTargets else { throw NexArmExecutionError.invalidArguments }
        for (motor, target) in targets { result[motor - 1] = target }
        return result
    }

    private static func words(_ bytes: [UInt8]) -> [Int] {
        stride(from: 0, to: bytes.count, by: 2).map {
            Int(Int16(bitPattern: UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8))
        }
    }
}
