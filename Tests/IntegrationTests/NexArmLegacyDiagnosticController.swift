import ActionRuntime
import Actions
import Foundation
import PlatformKit

/// Historical USB diagnostics only. Never bind this polling controller into the application.
/// Kept for explicit opt-in reproduction of the retired settlement algorithm.
actor NexArmLegacyDiagnosticController {
    private let link: any NexArmLink
    private let verifier: NexArmActionController
    private var busy = false
    private var faulted = false
    private var used = false
    private(set) var lastFailure: String?
    private(set) var attemptedTarget: Int?
    private(set) var lastObserved: Int?
    private(set) var lastMotion: Motion?
    struct Motion: Equatable, Sendable {
        let start: Int
        let target: Int
        let observed: Int
    }
    init(link: any NexArmLink) {
        self.link = link
        verifier = NexArmActionController(link: link)
    }
    private func requireCompatibility() async throws -> NexArmCompatibility {
        try await verifier.verifyCompatibility()
    }
    func nudgeWrist(delta: Int) async throws {
        try Task.checkCancellation()
        guard !busy else { throw NexArmError.busy }
        guard !faulted else { throw NexArmActionError.uncertainMotion }
        guard !used else { throw NexArmActionError.alreadyUsed }
        guard (-2...2).contains(delta), delta != 0 else { throw NexArmError.invalidMotion }
        busy = true
        defer { busy = false }
        _ = try await requireCompatibility()
        let first = try await position()
        try await Task.sleep(for: .milliseconds(150))
        let second = try await position()
        guard zip(first.joints.prefix(5), second.joints.prefix(5)).allSatisfy({ abs($0 - $1) <= 2 }) else {
            throw NexArmActionError.moving
        }
        let target = second.position + Int((Double(delta) * 4096 / 360).rounded())
        let expectedRoll = second.roll + delta
        guard (1536...2560).contains(second.position), (1536...2560).contains(target) else {
            throw NexArmError.invalidMotion
        }
        try Task.checkCancellation()
        used = true
        attemptedTarget = target
        lastObserved = second.position
        // Once committed, join bounded physical settlement even when the caller is cancelled.
        // Cancellation never sends a rollback or torque-off command (which could drop a load).
        guard let writer = link as? any NexArmWritableLink else { throw NexArmError.invalidMotion }
        let movement = Task {
            try await writer.write(
                NexArmMotorCommands.move(motor: 5, target: target, options: NexArmMotorOptions(speed: 100)))
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            var stable = 0
            while ContinuousClock.now < deadline {
                let state = try await position()
                lastObserved = state.position
                guard
                    zip(state.joints.prefix(5).enumerated(), second.joints).allSatisfy({ item, baseline in
                        item.offset == 4 || abs(item.element - baseline) <= 8
                    })
                else { throw NexArmActionError.moving }
                stable = abs(state.position - target) <= 6 && abs(state.roll - expectedRoll) <= 1 ? stable + 1 : 0
                if stable == 3 { return state.position }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw NexArmError.timeout
        }
        do {
            let actual = try await movement.value
            lastMotion = Motion(start: second.position, target: target, observed: actual)
        } catch {
            faulted = true
            lastFailure = String(describing: error)
            throw NexArmActionError.uncertainMotion
        }
        try Task.checkCancellation()
    }

    struct BaseSweep: Equatable, Sendable {
        let cycles: Int
        let start: Int
        let observed: [Int]
    }
    private(set) var lastBaseSweep: BaseSweep?
    /// Bounded diagnostics: one baseline, one target and the latest pose/joint sample.
    private(set) var baseBaseline: [Int] = []
    private(set) var baseTarget: [Int] = []
    private(set) var baseObserved: [Int] = []
    private(set) var completedBaseLegs = 0

    /// One cycle is origin → +2° XY yaw → -2° XY yaw → origin.
    /// Native motor1 movement preserves the other four arm joints and never addresses the gripper.
    func shakeBase(cycles: Int) async throws {
        try Task.checkCancellation()
        guard (1...3).contains(cycles) else { throw NexArmError.invalidMotion }
        guard !busy else { throw NexArmError.busy }
        guard !faulted else { throw NexArmActionError.uncertainMotion }
        busy = true
        defer { busy = false }
        lastBaseSweep = nil
        baseBaseline = []
        baseTarget = []
        baseObserved = []
        completedBaseLegs = 0
        _ = try await requireCompatibility()
        let first = try await position()
        try await Task.sleep(for: .milliseconds(150))
        let origin = try await position()
        guard zip(first.joints.prefix(5), origin.joints.prefix(5)).allSatisfy({ abs($0 - $1) <= 2 }) else {
            throw NexArmActionError.moving
        }
        baseBaseline = origin.pose + origin.joints
        let x = Double(origin.pose[0])
        let y = Double(origin.pose[1])
        let radius = hypot(x, y)
        guard (100...350).contains(radius), (1580...2516).contains(origin.joints[0]) else {
            throw NexArmError.invalidMotion
        }
        var current = origin
        var samples: [Int] = []  // At most nine legs; never retained across calls.
        for _ in 0..<cycles {
            for degrees in [2.0, -2.0, 0.0] {
                try Task.checkCancellation()
                let angle = degrees * .pi / 180
                let targetX = Int((x * cos(angle) - y * sin(angle)).rounded())
                let targetY = Int((x * sin(angle) + y * cos(angle)).rounded())
                baseTarget = [targetX, targetY] + Array(origin.pose.dropFirst(2))
                let dx = targetX - current.pose[0]
                let dy = targetY - current.pose[1]
                guard abs(dx) <= 26, abs(dy) <= 26 else { throw NexArmError.invalidMotion }
                // Retain and join each committed finite leg even if its caller cancels.
                let leg = Task {
                    guard let writer = link as? any NexArmWritableLink else { throw NexArmError.invalidMotion }
                    let target = origin.joints[0] - Int((degrees * 4096 / 360).rounded())
                    try await writer.write(
                        NexArmMotorCommands.move(motor: 1, target: target, options: NexArmMotorOptions(speed: 100)))
                    // Do not count a transient passage through a target as completion.
                    try await Task.sleep(for: .milliseconds(1500))
                    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
                    var stable = 0
                    while ContinuousClock.now < deadline {
                        let state = try await position()
                        baseObserved = state.pose + state.joints
                        guard abs(state.joints[0] - origin.joints[0]) <= 40,
                            zip(state.joints[1..<5], origin.joints[1..<5]).allSatisfy({ abs($0 - $1) <= 16 })
                        else { throw NexArmActionError.moving }
                        let baseDelta = abs(state.joints[0] - origin.joints[0])
                        let baseOK = degrees == 0 ? baseDelta <= 6 : (12...34).contains(baseDelta)
                        let poseOK =
                            abs(state.pose[0] - targetX) <= 2 && abs(state.pose[1] - targetY) <= 2
                            && zip(state.pose[2..<5], origin.pose[2..<5]).allSatisfy({ abs($0 - $1) <= 2 })
                        stable = baseOK && poseOK ? stable + 1 : 0
                        if stable == 3 { return state }
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    throw NexArmError.timeout
                }
                do {
                    current = try await leg.value
                    samples.append(current.joints[0])
                    completedBaseLegs += 1
                } catch {
                    faulted = true
                    lastFailure = String(describing: error)
                    throw NexArmActionError.uncertainMotion
                }
                try Task.checkCancellation()
            }
        }
        lastBaseSweep = BaseSweep(cycles: cycles, start: origin.joints[0], observed: samples)
    }

    private func position() async throws -> (position: Int, joints: [Int], roll: Int, pose: [Int]) {
        let response = try await link.exchange(
            NexArmPacket(command: 11), replyID: 255, replyCommand: 11, replyCount: 24)
        return try decodePosition(response)
    }
    private func decodePosition(_ response: NexArmPacket) throws -> (
        position: Int, joints: [Int], roll: Int, pose: [Int]
    ) {
        let p = response.payload
        guard p.count == 24 else { throw NexArmError.invalidPacket }
        let joints = stride(from: 12, to: 24, by: 2).map { Int(p[$0]) | Int(p[$0 + 1]) << 8 }
        guard joints.allSatisfy({ (0...4095).contains($0) }) else { throw NexArmError.invalidPacket }
        let roll = Int(Int16(bitPattern: UInt16(p[8]) | UInt16(p[9]) << 8))
        let pose = stride(from: 0, to: 12, by: 2).map {
            Int(Int16(bitPattern: UInt16(p[$0]) | UInt16(p[$0 + 1]) << 8))
        }
        return (joints[4], joints, roll, pose)
    }
}
