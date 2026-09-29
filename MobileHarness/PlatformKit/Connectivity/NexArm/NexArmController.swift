import Foundation

public enum NexArmCompatibilityPolicy: Sendable {
    case strictFirmware
    /// Validated NexArm pose protocol; firmware version is not part of the BLE handshake.
    case nexArmBLEProtocol
}
public enum NexArmCompatibility: Sendable, Equatable {
    case firmware102
    case poseProtocol
}

/// Supervised bounded motion owner. Device feedback does not establish physical clearance.
public actor NexArmController {
    private let link: any NexArmLink
    private var busy = false
    private var used = false
    private var faulted = false
    private let compatibilityPolicy: NexArmCompatibilityPolicy
    private var compatibility: NexArmCompatibility?
    private var connectionIndicationUsed = false
    public private(set) var lastFailure: String?
    public private(set) var attemptedTarget: Int?
    public private(set) var lastObserved: Int?
    public private(set) var lastMotion: Motion?

    public struct Motion: Equatable, Sendable {
        public let start: Int
        public let target: Int
        public let observed: Int
    }
    public init(link: any NexArmLink, compatibilityPolicy: NexArmCompatibilityPolicy = .strictFirmware) {
        self.link = link
        self.compatibilityPolicy = compatibilityPolicy
    }

    /// One controller belongs to one live connection; discard it on disconnect.
    @discardableResult
    public func verifyCompatibility() async throws -> NexArmCompatibility {
        try Task.checkCancellation()
        guard !busy else { throw NexArmError.busy }
        guard !faulted else { throw NexArmError.uncertainMotion }
        busy = true
        defer { busy = false }
        return try await requireCompatibility()
    }

    private func requireCompatibility() async throws -> NexArmCompatibility {
        try Task.checkCancellation()
        if let compatibility { return compatibility }
        if compatibilityPolicy == .nexArmBLEProtocol {
            // This validates the pose protocol, not any firmware version.
            let first = try await position()
            try await Task.sleep(for: .milliseconds(200))
            let second = try await position()
            for sample in [first, second] {
                guard hypot(Double(sample.pose[0]), Double(sample.pose[1])) <= 450,
                    (50...600).contains(sample.pose[2]), abs(sample.pose[3]) <= 1800,
                    abs(sample.pose[4]) <= 180, abs(sample.pose[5]) <= 180
                else { throw NexArmError.invalidMotion }
            }
            guard zip(first.joints, second.joints).allSatisfy({ abs($0 - $1) <= 2 }) else {
                throw NexArmError.moving
            }
            compatibility = .poseProtocol
            return .poseProtocol
        }
        for attempt in 0..<4 {
            let version = try await link.exchange(
                NexArmPacket(command: 1), replyID: 255, replyCommand: 1, replyCount: 6)
            if version.payload == [1, 0, 2, 1, 0, 2] {
                compatibility = .firmware102
                return .firmware102
            }
            // The ESP32 returns zeros when its internal AT32 version read fails.
            // Only this read-only result can be queried again; never retry a motion or failed transport.
            guard version.payload == [1, 0, 2, 0, 0, 0] else { throw NexArmError.unsupportedFirmware }
            if attempt < 3 { try await Task.sleep(for: .milliseconds(200)) }
        }
        throw NexArmError.firmwareUnavailable
    }

    /// Explicit connection feedback: reset to the vendor home, then ID5 ±8° and center, once per connection.
    public func indicateConnection() async throws {
        try Task.checkCancellation()
        guard !busy else { throw NexArmError.busy }
        guard !faulted else { throw NexArmError.uncertainMotion }
        guard !connectionIndicationUsed else { throw NexArmError.alreadyUsed }
        guard let writer = link as? any NexArmWritableLink else { throw NexArmError.invalidMotion }
        busy = true
        defer { busy = false }
        _ = try await requireCompatibility()
        let first = try await position()
        try await Task.sleep(for: .milliseconds(150))
        let second = try await position()
        guard zip(first.joints, second.joints).allSatisfy({ abs($0 - $1) <= 2 }) else { throw NexArmError.moving }
        try Task.checkCancellation()
        connectionIndicationUsed = true
        // Vendor CMD_ARM_RESET moves the whole arm to [200,0,200,0,0,0], not factory reset.
        let reset = Task {
            try await writer.write(NexArmPacket(command: 54, payload: [0xD0, 0x07]))
            try await Task.sleep(for: .seconds(2))
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            var stable = 0
            var previous: [Int]?
            while ContinuousClock.now < deadline {
                let sample = try await position()
                let atHome =
                    zip(sample.pose.prefix(3), [200, 0, 200]).allSatisfy { abs($0 - $1) <= 5 }
                    && abs(sample.pose[3]) <= 20 && abs(sample.pose[4]) <= 2 && abs(sample.pose[5]) <= 2
                let still = previous.map { zip(sample.joints, $0).allSatisfy { abs($0 - $1) <= 2 } } ?? false
                stable = atHome && still ? stable + 1 : 0
                previous = sample.joints
                if stable == 3 { return sample.joints }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw NexArmError.timeout
        }
        let home: [Int]
        do { home = try await reset.value } catch {
            faulted = true
            lastFailure = String(describing: error)
            throw NexArmError.uncertainMotion
        }
        try Task.checkCancellation()
        guard (1627...2469).contains(home[4]) else { throw NexArmError.invalidMotion }
        for offset in [-91, 91, 0] {
            let target = home[4] + offset
            guard (1536...2560).contains(target) else { throw NexArmError.invalidMotion }
            try Task.checkCancellation()
            let leg = Task {
                // CMD_ARM_SERVO_SINGLE takes ID, absolute encoder position and vendor speed parameter.
                try await writer.write(
                    NexArmPacket(command: 51, payload: [5, UInt8(target & 255), UInt8(target >> 8), 200, 0]))
                try await Task.sleep(for: .seconds(1))
                let deadline = ContinuousClock.now.advanced(by: .seconds(3))
                var stable = 0
                while ContinuousClock.now < deadline {
                    let sample = try await position()
                    guard
                        zip(sample.joints.enumerated(), home).allSatisfy({ pair, start in
                            pair.offset == 4 ? abs(pair.element - home[4]) <= 110 : abs(pair.element - start) <= 8
                        })
                    else { throw NexArmError.moving }
                    stable = abs(sample.joints[4] - target) <= 6 ? stable + 1 : 0
                    if stable == 3 { return }
                    try await Task.sleep(for: .milliseconds(100))
                }
                throw NexArmError.timeout
            }
            do { try await leg.value } catch {
                faulted = true
                lastFailure = String(describing: error)
                throw NexArmError.uncertainMotion
            }
            try Task.checkCancellation()
        }
    }

    public func nudgeWrist(delta: Int) async throws {
        try Task.checkCancellation()
        guard !busy else { throw NexArmError.busy }
        guard !faulted else { throw NexArmError.uncertainMotion }
        guard !used else { throw NexArmError.alreadyUsed }
        guard (-2...2).contains(delta), delta != 0 else { throw NexArmError.invalidMotion }
        busy = true
        defer { busy = false }
        _ = try await requireCompatibility()
        let first = try await position()
        try await Task.sleep(for: .milliseconds(150))
        let second = try await position()
        guard zip(first.joints, second.joints).allSatisfy({ abs($0 - $1) <= 2 }) else {
            throw NexArmError.moving
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
        let movement = Task {
            let roll = UInt16(bitPattern: Int16(delta))
            let payload: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0, UInt8(roll & 255), UInt8(roll >> 8), 0, 0, 0xE8, 0x03]
            _ = try await link.exchange(
                NexArmPacket(command: 0x32, payload: payload), replyID: 255, replyCommand: 11, replyCount: 24)
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            var stable = 0
            while ContinuousClock.now < deadline {
                let state = try await position()
                lastObserved = state.position
                guard
                    zip(state.joints.enumerated(), second.joints).allSatisfy({ item, baseline in
                        item.offset == 4 || abs(item.element - baseline) <= 8
                    })
                else { throw NexArmError.moving }
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
            throw NexArmError.uncertainMotion
        }
        try Task.checkCancellation()
    }

    public struct BaseSweep: Equatable, Sendable {
        public let cycles: Int
        public let start: Int
        public let observed: [Int]
    }
    public private(set) var lastBaseSweep: BaseSweep?
    /// Bounded diagnostics: one baseline, one target and the latest pose/joint sample.
    public private(set) var baseBaseline: [Int] = []
    public private(set) var baseTarget: [Int] = []
    public private(set) var baseObserved: [Int] = []
    public private(set) var completedBaseLegs = 0

    /// One cycle is origin → +2° XY yaw → -2° XY yaw → origin.
    /// Controller IK may make small corrections to the other joints.
    public func shakeBase(cycles: Int) async throws {
        try Task.checkCancellation()
        guard (1...3).contains(cycles) else { throw NexArmError.invalidMotion }
        guard !busy else { throw NexArmError.busy }
        guard !faulted else { throw NexArmError.uncertainMotion }
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
        guard zip(first.joints, origin.joints).allSatisfy({ abs($0 - $1) <= 2 }) else {
            throw NexArmError.moving
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
                    let values = [dx, dy, 0, 0, 0, 0, 1500]
                    let payload = values.flatMap { value -> [UInt8] in
                        let bits = UInt16(bitPattern: Int16(value))
                        return [UInt8(bits & 255), UInt8(bits >> 8)]
                    }
                    _ = try await link.exchange(
                        NexArmPacket(command: 0x32, payload: payload), replyID: 255, replyCommand: 11, replyCount: 24)
                    // Do not count a transient passage through a target as completion.
                    try await Task.sleep(for: .milliseconds(1500))
                    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
                    var stable = 0
                    while ContinuousClock.now < deadline {
                        let state = try await position()
                        baseObserved = state.pose + state.joints
                        guard abs(state.joints[0] - origin.joints[0]) <= 40,
                            zip(state.joints.dropFirst(), origin.joints.dropFirst()).allSatisfy({ abs($0 - $1) <= 16 })
                        else { throw NexArmError.moving }
                        let baseDelta = abs(state.joints[0] - origin.joints[0])
                        let baseOK = degrees == 0 ? baseDelta <= 6 : (12...34).contains(baseDelta)
                        let poseOK =
                            abs(state.pose[0] - targetX) <= 2 && abs(state.pose[1] - targetY) <= 2
                            && zip(state.pose.dropFirst(2), origin.pose.dropFirst(2)).allSatisfy({ abs($0 - $1) <= 2 })
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
                    throw NexArmError.uncertainMotion
                }
                try Task.checkCancellation()
            }
        }
        lastBaseSweep = BaseSweep(cycles: cycles, start: origin.joints[0], observed: samples)
    }

    private func position() async throws -> (position: Int, joints: [Int], roll: Int, pose: [Int]) {
        let response = try await link.exchange(
            NexArmPacket(command: 11), replyID: 255, replyCommand: 11, replyCount: 24)
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
