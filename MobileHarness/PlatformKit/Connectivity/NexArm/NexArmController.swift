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

public enum NexArmMotionFailure: Sendable, Equatable {
    case sending
    case feedback
    case feedbackTimeout
    case completionTimeout
    case target(joints: [Int])
    case pose
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
    public private(set) var cachedJoints: [Int] = []
    private var cachedPose: [Int] = []
    public var latestState: (joints: [Int], pose: [Int]) { (cachedJoints, cachedPose) }
    public private(set) var lastFailure: String?
    public private(set) var motionFailure: NexArmMotionFailure?
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
        motionFailure = nil
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
        let home = try await resetAndSettle(writer)
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

    /// Latest measured encoder values and Cartesian pose, never inferred from commands.
    public func readState() async throws -> (joints: [Int], pose: [Int]) {
        try Task.checkCancellation()
        guard !busy else { throw NexArmError.busy }
        guard !faulted else { throw NexArmError.uncertainMotion }
        busy = true
        defer { busy = false }
        let sample = try await position()
        return (sample.joints, sample.pose)
    }

    /// Read-only recovery after an unconfirmed movement. Never replays or rolls back a command.
    public func recoverState() async throws -> (joints: [Int], pose: [Int]) {
        try Task.checkCancellation()
        guard !busy else { throw NexArmError.busy }
        busy = true
        defer { busy = false }
        var sample = try await position()
        if faulted {
            func validPose(_ pose: [Int]) -> Bool {
                hypot(Double(pose[0]), Double(pose[1])) <= 450
                    && (50...600).contains(pose[2]) && abs(pose[3]) <= 1800
                    && abs(pose[4]) <= 180 && abs(pose[5]) <= 180
            }
            guard validPose(sample.pose) else { throw NexArmError.invalidMotion }
            let baseline = sample.joints
            for _ in 0..<2 {
                try await Task.sleep(for: .milliseconds(150))
                let next = try await position()
                guard validPose(next.pose) else { throw NexArmError.invalidMotion }
                guard zip(baseline, next.joints).allSatisfy({ abs($0 - $1) <= 2 }) else {
                    throw NexArmError.moving
                }
                sample = next
            }
            try Task.checkCancellation()
            faulted = false
        }
        return (sample.joints, sample.pose)
    }

    public func resetPosition() async throws {
        try Task.checkCancellation()
        guard !busy else { throw NexArmError.busy }
        guard !faulted else { throw NexArmError.uncertainMotion }
        guard let writer = link as? any NexArmWritableLink else { throw NexArmError.invalidMotion }
        busy = true
        defer { busy = false }
        _ = try await requireCompatibility()
        let first = try await position()
        try await Task.sleep(for: .milliseconds(150))
        let second = try await position()
        guard zip(first.joints, second.joints).allSatisfy({ abs($0 - $1) <= 2 }) else { throw NexArmError.moving }
        try Task.checkCancellation()
        _ = try await resetAndSettle(writer)
        try Task.checkCancellation()
    }

    private func resetAndSettle(_ writer: any NexArmWritableLink) async throws -> [Int] {
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
        do { return try await reset.value } catch {
            faulted = true
            lastFailure = String(describing: error)
            throw NexArmError.uncertainMotion
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

    /// Absolute choreography: prepare, perform, then finish at the vendor home pose.
    public func performGesture(_ gesture: NexArmGesture, repetitions: Int) async throws {
        try Task.checkCancellation()
        guard (1...3).contains(repetitions),
            (gesture != .tiltLeft && gesture != .tiltRight) || repetitions == 1
        else { throw NexArmError.invalidMotion }
        guard !busy else { throw NexArmError.busy }
        guard let writer = link as? any NexArmWritableLink else { throw NexArmError.invalidMotion }
        busy = true
        defer { busy = false }
        // A new explicit request owns a new result; a previous timeout is not an admission lock.
        faulted = false
        lastFailure = nil
        motionFailure = nil
        _ = try await requireCompatibility()
        // Targets are fixed Cartesian poses. Factory/example encoder positions are not calibration.
        let home = NexArmGesture.home
        let ready = NexArmGesture.ready
        let targets = [home, ready] + (0..<repetitions).flatMap { _ in gesture.frames } + [ready, home]
        guard targets.count <= 22, targets.allSatisfy(NexArmGesture.validPose)
        else { throw NexArmError.invalidMotion }
        let durations = targets.indices.map { $0 == 0 ? 3000 : ($0 == targets.count - 1 ? 1200 : 800) }
        // Sum segment budgets once: repeated arrival checks must not consume the ending's allowance.
        // The deadline remains fixed, and each segment still fails independently on silence/timeout.
        let actionBudget = durations.reduce(Duration.zero) {
            $0 + NexArmArrivalTracker.completionBudget(durationMilliseconds: $1)
        }
        let actionDeadline = ContinuousClock.now.advanced(by: actionBudget)
        for (index, target) in targets.enumerated() {
            try Task.checkCancellation()
            guard ContinuousClock.now < actionDeadline else {
                motionFailure = .completionTimeout
                faulted = true
                lastFailure = "action deadline"
                throw NexArmError.uncertainMotion
            }
            let final = index == targets.count - 1
            // Fixed approach does not require old feedback or a stationary recovery sample.
            let milliseconds = durations[index]
            // Vendor move/reset uses CMD8: pitch, X, Y, Z, roll, claw, duration.
            // CMD50 increments the device's commanded pose, not this host's measured pose.
            let values = [target[3], target[0], target[1], target[2], target[4], target[5], milliseconds]
            let packet = try NexArmPacket(
                command: 8,
                payload: values.flatMap { value -> [UInt8] in
                    let bits = UInt16(bitPattern: Int16(value))
                    return [UInt8(bits & 255), UInt8(bits >> 8)]
                })
            let leg = Task {
                try await observeGestureLeg(
                    writer: writer, packet: packet, target: target,
                    milliseconds: milliseconds, final: final, actionDeadline: actionDeadline)
            }
            do { _ = try await leg.value } catch {
                if error is CancellationError { throw error }
                faulted = true
                lastFailure = String(describing: error)
                throw NexArmError.uncertainMotion
            }
            motionFailure = nil
            try Task.checkCancellation()
        }
    }

    private func observeGestureLeg(
        writer: any NexArmWritableLink, packet: NexArmPacket, target: [Int], milliseconds: Int, final: Bool,
        actionDeadline: ContinuousClock.Instant
    ) async throws {
        if let observable = writer as? any NexArmObservableLink {
            let session = try await observable.beginObservation()
            do {
                let baseline = try await observable.latestObservation(after: 0, session: session)?.sequence ?? 0
                motionFailure = .sending
                let admissionDeadline = min(actionDeadline, ContinuousClock.now.advanced(by: .seconds(1)))
                let sentAt = ContinuousClock.now
                while true {
                    guard ContinuousClock.now < admissionDeadline else { throw NexArmError.timeout }
                    if try await observable.sendObserved(packet, session: session) { break }
                    try await Task.sleep(for: .milliseconds(25))
                }
                try await awaitArrival(
                    target: target, milliseconds: milliseconds, final: final,
                    started: sentAt, observable: observable, session: session, sequence: baseline,
                    actionDeadline: actionDeadline)
                await observable.endObservation(session)
            } catch {
                await observable.endObservation(session)
                throw error
            }
        } else {
            motionFailure = .sending
            try await writer.write(packet)
            try await awaitArrival(
                target: target, milliseconds: milliseconds, final: final,
                started: .now, observable: nil, session: nil, sequence: 0, actionDeadline: actionDeadline)
        }
    }

    private func awaitArrival(
        target: [Int], milliseconds: Int, final: Bool, started: ContinuousClock.Instant,
        observable: (any NexArmObservableLink)?, session: UUID?, sequence initialSequence: UInt64,
        actionDeadline: ContinuousClock.Instant
    ) async throws {
        var tracker = NexArmArrivalTracker(
            target: target, final: final, started: started, durationMilliseconds: milliseconds,
            actionDeadline: actionDeadline)
        var sequence = initialSequence
        var nextQuery = started
        var lastReceipt = started.advanced(by: .seconds(-1))
        while true {
            switch tracker.outcome(at: .now) {
            case .arrived: return
            case .feedbackTimeout:
                motionFailure = .feedbackTimeout
                throw NexArmError.timeout
            case .completionTimeout:
                motionFailure = .completionTimeout
                throw NexArmError.timeout
            case .waiting: break
            }
            motionFailure = .feedback
            if let observable, let session {
                if let update = try await observable.latestObservation(after: sequence, session: session) {
                    sequence = update.sequence
                    if update.receivedAt >= started {
                        let sample = try decodePosition(update.packet)
                        guard NexArmGesture.validPose(sample.pose) else {
                            motionFailure = .pose
                            throw NexArmError.invalidMotion
                        }
                        tracker.observe(pose: sample.pose, joints: sample.joints, at: update.receivedAt)
                        lastReceipt = update.receivedAt
                    }
                }
                // Query only when notifications are quiet; one attempt at most every200ms.
                if ContinuousClock.now >= nextQuery, ContinuousClock.now - lastReceipt >= .milliseconds(200) {
                    _ = try await observable.sendObserved(NexArmPacket(command: 11), session: session)
                    nextQuery = .now.advanced(by: .milliseconds(200))
                }
                try await Task.sleep(for: .milliseconds(50))
            } else {
                let sample = try await position()
                guard NexArmGesture.validPose(sample.pose) else {
                    motionFailure = .pose
                    throw NexArmError.invalidMotion
                }
                tracker.observe(pose: sample.pose, joints: sample.joints, at: .now)
                try await Task.sleep(for: .milliseconds(200))
            }
        }
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
        cachedJoints = joints
        cachedPose = pose
        return (joints[4], joints, roll, pose)
    }
}

/// Presets own their mechanical meaning; callers cannot supply arbitrary joint positions or speed.
public enum NexArmGesture: Sendable, CaseIterable {
    case baseSway, wave, tiltLeft, tiltRight, lookAround, celebrate, dance

    public var displayName: String {
        switch self {
        case .baseSway: "底座晃动"
        case .wave: "挥手"
        case .tiltLeft, .tiltRight: "歪头"
        case .lookAround: "左右张望"
        case .celebrate: "庆祝"
        case .dance: "小舞蹈"
        }
    }
    /// Settings-only open-loop test sequence. Timings are trajectory durations, not feedback waits.
    public struct TestFrame: Sendable {
        public let packet: NexArmPacket
        public let milliseconds: Int
    }
    public func settingsTestFrames() throws -> [TestFrame] {
        let poses = [Self.ready] + frames + [Self.home]
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
    fileprivate static func validPose(_ pose: [Int]) -> Bool {
        pose.count == 6 && hypot(Double(pose[0]), Double(pose[1])) <= 450
            && (50...600).contains(pose[2]) && abs(pose[3]) <= 1800
            && abs(pose[4]) <= 180 && abs(pose[5]) <= 180
    }
    fileprivate static let home = [200, 0, 200, 0, 0, 0]
    fileprivate static let ready = [200, 0, 240, 0, 0, 0]

    /// Absolute XYZ(mm), pitch(tenths of degree), roll/claw(degrees).
    fileprivate var frames: [[Int]] {
        func pose(_ yaw: Int, _ roll: Int, height: Int = 240) -> [Int] {
            let angle = Double(yaw) * .pi / 180
            return [Int((200 * cos(angle)).rounded()), Int((200 * sin(angle)).rounded()), height, 0, roll, 0]
        }
        switch self {
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

/// Bounded velocity shaping with finite look-ahead position goals; no telemetry/ACK dependency.
public struct NexArmJogPlanner: Sendable {
    public static let home = [2048, 2087, 1198, 1238, 2048, 2048]
    public static let limits = [210...3826, 200...3800, 968...3200, 728...3218, 908...3128, 1118...2828]
    public static let period = 0.03
    public static let maximumSpeed = 600.0
    public static let maximumAcceleration = 1800.0
    public static let maximumJerk = 12000.0
    private struct State: Sendable {
        var position: Double
        var velocity = 0.0
        var acceleration = 0.0
        var lastTarget: Int
    }
    private var states: [State]
    public var targets: [Double] { states.map { Double($0.lastTarget) } }
    public var velocities: [Double] { states.map(\.velocity) }
    public var accelerations: [Double] { states.map(\.acceleration) }
    public struct Proposal: Sendable {
        public let id: Int
        public let packet: NexArmPacket?
        public let target: Double
        fileprivate let position: Double
        fileprivate let velocity: Double
        fileprivate let acceleration: Double
    }
    public init(positions: [Int]) throws {
        guard positions.count == 6, positions.allSatisfy({ (0...4095).contains($0) }) else {
            throw NexArmError.invalidPacket
        }
        states = positions.map { State(position: Double($0), lastTarget: $0) }
    }
    public func proposal(id: Int, deflection: Double, elapsed: Double = period) throws -> Proposal? {
        guard (1...6).contains(id), deflection.isFinite, (-1...1).contains(deflection),
            elapsed.isFinite, elapsed > 0
        else { throw NexArmError.invalidMotion }
        guard abs(deflection) > 0.04 else { return nil }
        let dt = min(elapsed, 0.06)  // Never catch up an accumulated transport stall.
        let index = id - 1
        let old = states[index]
        let input = (abs(deflection) - 0.04) / 0.96
        let desiredVelocity = (deflection < 0 ? -1.0 : 1.0) * input * input * Self.maximumSpeed
        func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double { min(upper, max(lower, value)) }
        let desiredAcceleration = clamp(
            (desiredVelocity - old.velocity) * 8, -Self.maximumAcceleration, Self.maximumAcceleration)
        var acceleration =
            old.acceleration
            + clamp(desiredAcceleration - old.acceleration, -Self.maximumJerk * dt, Self.maximumJerk * dt)
        var velocity = clamp(
            old.velocity + (old.acceleration + acceleration) * 0.5 * dt, -Self.maximumSpeed, Self.maximumSpeed)
        let lower = min(Double(Self.limits[index].lowerBound), old.position, Double(old.lastTarget))
        let upper = max(Double(Self.limits[index].upperBound), old.position, Double(old.lastTarget))
        let position = clamp(old.position + (old.velocity + velocity) * 0.5 * dt, lower, upper)
        if (position >= upper && velocity > 0) || (position <= lower && velocity < 0) {
            velocity = 0
            acceleration = 0
        }
        // A short finite lead bridges transport jitter; it never becomes an endless velocity command.
        var goal = clamp(position + velocity * 0.06, lower, upper)
        if old.velocity * velocity > 0 {
            goal = velocity > 0 ? max(goal, Double(old.lastTarget)) : min(goal, Double(old.lastTarget))
        }
        let target = Int(goal.rounded())
        let packet: NexArmPacket?
        if target == old.lastTarget {
            packet = nil  // Preserve fractional integration without restarting an identical servo goal.
        } else {
            let speed = min(600, max(1, Int(abs(velocity).rounded())))
            // Vendor HX_30HM write_pos_ex: ACC, position, PWM=0, speed. No unsolicited pose query.
            packet = try NexArmPacket(
                id: UInt8(id), command: 3,
                payload: [41, 30, UInt8(target & 255), UInt8(target >> 8), 0, 0, UInt8(speed & 255), UInt8(speed >> 8)])
        }
        return Proposal(
            id: id, packet: packet, target: Double(target), position: position,
            velocity: velocity, acceleration: acceleration)
    }
    public mutating func accept(_ proposal: Proposal) {
        let index = proposal.id - 1
        states[index].position = proposal.position
        states[index].velocity = proposal.velocity
        states[index].acceleration = proposal.acceleration
        if proposal.packet != nil { states[index].lastTarget = Int(proposal.target) }
    }
    /// Release discards future velocity, keeping the last finite target; never sends a return move.
    public mutating func stop(id: Int) {
        guard (1...6).contains(id) else { return }
        let target = states[id - 1].lastTarget
        states[id - 1] = State(position: Double(target), lastTarget: target)
    }
}
