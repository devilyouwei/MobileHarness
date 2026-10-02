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
    private var armPlan: NexArmArmPlan?
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
            guard zip(first.joints.prefix(5), second.joints.prefix(5)).allSatisfy({ abs($0 - $1) <= 2 }) else {
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

    /// Prepare a bounded, connection-local IK table before any motion/live session.
    public func prepareArmControl() async throws -> NexArmArmPlan {
        guard !busy else { throw NexArmError.busy }
        busy = true
        defer { busy = false }
        _ = try await requireCompatibility()
        return try await preparedArmPlan()
    }

    private func preparedArmPlan() async throws -> NexArmArmPlan {
        if let armPlan { return armPlan }
        var plan = NexArmArmPlan()
        for gesture in NexArmGesture.allCases {
            for frame in try gesture.settingsTestFrames() where frame.packet.command == 8 {
                try Task.checkCancellation()
                if plan.contains(frame) { continue }
                let reply = try await link.exchange(
                    NexArmPacket(command: 7, payload: frame.packet.payload),
                    replyID: 255, replyCommand: 7, replyCount: 24)
                try plan.insert(frame, reply: reply)
            }
        }
        armPlan = plan
        return plan
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
        guard zip(first.joints.prefix(5), second.joints.prefix(5)).allSatisfy({ abs($0 - $1) <= 2 }) else {
            throw NexArmError.moving
        }
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
                        zip(sample.joints.prefix(5).enumerated(), home).allSatisfy({ pair, start in
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
                guard zip(baseline.prefix(5), next.joints.prefix(5)).allSatisfy({ abs($0 - $1) <= 2 }) else {
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
        guard zip(first.joints.prefix(5), second.joints.prefix(5)).allSatisfy({ abs($0 - $1) <= 2 }) else {
            throw NexArmError.moving
        }
        try Task.checkCancellation()
        _ = try await resetAndSettle(writer)
        try Task.checkCancellation()
    }

    private func resetAndSettle(_ writer: any NexArmWritableLink) async throws -> [Int] {
        let plan = try await preparedArmPlan()
        let frame = try plan.compile([NexArmGesture.homeFrame(milliseconds: 2000)], from: cachedJoints)[0]
        let reset = Task {
            try await writer.write(frame.packet)
            try await Task.sleep(for: .seconds(2))
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            var stable = 0
            var previous: [Int]?
            while ContinuousClock.now < deadline {
                let sample = try await position()
                let atHome =
                    zip(sample.pose.prefix(3), [200, 0, 200]).allSatisfy { abs($0 - $1) <= 5 }
                    && abs(sample.pose[3]) <= 20 && abs(sample.pose[4]) <= 2
                let still =
                    previous.map { zip(sample.joints.prefix(5), $0.prefix(5)).allSatisfy { abs($0 - $1) <= 2 } }
                    ?? false
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
        guard zip(first.joints.prefix(5), second.joints.prefix(5)).allSatisfy({ abs($0 - $1) <= 2 }) else {
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
        guard let writer = link as? any NexArmWritableLink else { throw NexArmError.invalidMotion }
        let movement = Task {
            try await writer.write(NexArmArmPlan.singleMotor(id: 5, target: target, speed: 100))
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            var stable = 0
            while ContinuousClock.now < deadline {
                let state = try await position()
                lastObserved = state.position
                guard
                    zip(state.joints.prefix(5).enumerated(), second.joints).allSatisfy({ item, baseline in
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
    /// Native motor1 movement preserves the other four arm joints and never addresses the gripper.
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
        guard zip(first.joints.prefix(5), origin.joints.prefix(5)).allSatisfy({ abs($0 - $1) <= 2 }) else {
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
                    guard let writer = link as? any NexArmWritableLink else { throw NexArmError.invalidMotion }
                    let target = origin.joints[0] - Int((degrees * 4096 / 360).rounded())
                    try await writer.write(NexArmArmPlan.singleMotor(id: 1, target: target, speed: 100))
                    // Do not count a transient passage through a target as completion.
                    try await Task.sleep(for: .milliseconds(1500))
                    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
                    var stable = 0
                    while ContinuousClock.now < deadline {
                        let state = try await position()
                        baseObserved = state.pose + state.joints
                        guard abs(state.joints[0] - origin.joints[0]) <= 40,
                            zip(state.joints[1..<5], origin.joints[1..<5]).allSatisfy({ abs($0 - $1) <= 16 })
                        else { throw NexArmError.moving }
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
                    throw NexArmError.uncertainMotion
                }
                try Task.checkCancellation()
            }
        }
        lastBaseSweep = BaseSweep(cycles: cycles, start: origin.joints[0], observed: samples)
    }

    /// One motors-1–5 target. Returns when the link accepts the write, not when the joints arrive.
    public func aim(base: Double, pitch: Double) async throws {
        try Task.checkCancellation()
        guard !busy else { throw NexArmError.busy }
        guard compatibility != nil else { throw NexArmError.firmwareUnavailable }
        guard let writer = link as? any NexArmWritableLink else { throw NexArmError.invalidMotion }
        let packet = try NexArmJointCommand.aimPacket(base: base, pitch: pitch)
        busy = true
        defer { busy = false }
        faulted = false
        lastFailure = nil
        motionFailure = .sending
        do {
            try await writer.write(packet)
            motionFailure = nil
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            faulted = true
            lastFailure = String(describing: error)
            throw NexArmError.uncertainMotion
        }
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
        _ = try await preparedArmPlan()
        if cachedJoints.count != 6 { _ = try await position() }
        if gesture.motorID != nil {
            try await performHeadGesture(gesture, repetitions: repetitions, writer: writer)
            return
        }
        let plan = try await preparedArmPlan()
        let frames = try plan.compile(gesture.cartesianPlaybackFrames(repetitions: repetitions), from: cachedJoints)
        try await performCartesianPlayback(frames, writer: writer)
    }

    /// Same finite packets and cadence as Settings; only the final home is observed.
    private func performCartesianPlayback(_ frames: [NexArmGesture.TestFrame], writer: any NexArmWritableLink)
        async throws
    {
        let observable = writer as? any NexArmObservableLink
        let session = try await observable?.beginObservation()
        // One bounded plan, at most 20 frames; allow one second of admission per frame
        // and three seconds for final observation. No catch-up or motion replay.
        let budget = frames.reduce(Duration.seconds(3)) { $0 + .milliseconds($1.milliseconds + 1000) }
        let deadline = ContinuousClock.now.advanced(by: budget)
        do {
            for (index, frame) in frames.enumerated() {
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else {
                    motionFailure = .completionTimeout
                    throw NexArmError.timeout
                }
                let final = index == frames.count - 1
                // Cancellation joins this one finite frame, not the remainder of the plan.
                let leg = Task {
                    motionFailure = .sending
                    if let observable, let session {
                        let admissionDeadline = min(deadline, ContinuousClock.now.advanced(by: .seconds(1)))
                        while true {
                            guard ContinuousClock.now < admissionDeadline else { throw NexArmError.timeout }
                            if try await observable.sendObserved(frame.packet, session: session) { break }
                            try await Task.sleep(for: .milliseconds(25))
                        }
                    } else {
                        try await writer.write(frame.packet)
                    }
                    // Anchor each duration to this admission, like Settings. A delayed write
                    // never causes subsequent targets to be emitted in a catch-up burst.
                    try await Task.sleep(for: .milliseconds(frame.milliseconds))
                    if final {
                        let began = ContinuousClock.now
                        let baseline: UInt64
                        if let observable, let session {
                            baseline = try await observable.latestObservation(after: 0, session: session)?.sequence ?? 0
                        } else {
                            baseline = 0
                        }
                        try await awaitArrival(
                            target: NexArmGesture.home, milliseconds: 0, final: true,
                            started: began, observable: observable, session: session, sequence: baseline,
                            actionDeadline: deadline, initialQueryDelayMilliseconds: 200)
                    }
                }
                try await leg.value
                try Task.checkCancellation()
            }
            if let observable, let session { await observable.endObservation(session) }
            motionFailure = nil
        } catch {
            if let observable, let session { await observable.endObservation(session) }
            if error is CancellationError { throw error }
            faulted = true
            lastFailure = String(describing: error)
            throw NexArmError.uncertainMotion
        }
    }

    private func performHeadGesture(_ gesture: NexArmGesture, repetitions: Int, writer: any NexArmWritableLink)
        async throws
    {
        let plan = try await preparedArmPlan()
        // First establish calibrated home. Never interpret a previous arbitrary posture as the neutral head.
        let durations =
            [800, 800] + Array(repeating: NexArmGesture.headFrameMilliseconds, count: repetitions * 5) + [1200]
        let budget = durations.reduce(Duration.zero) {
            $0 + NexArmArrivalTracker.completionBudget(durationMilliseconds: $1)
        }
        let deadline = ContinuousClock.now.advanced(by: budget)
        func run(
            _ frame: NexArmGesture.TestFrame, target: [Int] = NexArmGesture.home,
            joints: [Int]? = nil, final: Bool = false, handoff: Bool = false
        ) async throws {
            try Task.checkCancellation()
            let compiled = try plan.compile([frame], from: cachedJoints)[0]
            let leg = Task {
                try await self.observeGestureLeg(
                    writer: writer, packet: compiled.packet, target: target,
                    milliseconds: frame.milliseconds, final: final, actionDeadline: deadline, jointTarget: joints,
                    minimumObservationMilliseconds: handoff ? frame.milliseconds : 0)
            }
            try await leg.value
            try Task.checkCancellation()
        }
        do {
            // Every preparation and ending frame explicitly addresses only arm motors.
            try await run(NexArmGesture.homeFrame(milliseconds: 800))
            try await run(
                NexArmGesture.poseFrame(NexArmGesture.ready, milliseconds: 800),
                target: NexArmGesture.ready, handoff: true)
            let center = cachedJoints
            let frames = try gesture.headFrames(center: center)
            for _ in 0..<repetitions {
                for frame in frames {
                    var target = center
                    guard let id = gesture.motorID else { throw NexArmError.invalidMotion }
                    target[id - 1] = Int(frame.packet.payload[2]) | Int(frame.packet.payload[3]) << 8
                    try await run(frame, joints: target)
                }
            }
            try await run(NexArmGesture.homeFrame(milliseconds: 1200), final: true)
            motionFailure = nil
        } catch {
            if error is CancellationError { throw error }
            faulted = true
            lastFailure = String(describing: error)
            throw NexArmError.uncertainMotion
        }
    }

    private func observeGestureLeg(
        writer: any NexArmWritableLink, packet: NexArmPacket, target: [Int], milliseconds: Int, final: Bool,
        actionDeadline: ContinuousClock.Instant, jointTarget: [Int]? = nil,
        minimumObservationMilliseconds: Int = 0
    ) async throws {
        if let observable = writer as? any NexArmObservableLink {
            let session = try await observable.beginObservation()
            do {
                let baseline = try await observable.latestObservation(after: 0, session: session)?.sequence ?? 0
                motionFailure = .sending
                let admissionDeadline = min(actionDeadline, ContinuousClock.now.advanced(by: .seconds(1)))
                var sentAt = ContinuousClock.now
                while true {
                    guard ContinuousClock.now < admissionDeadline else { throw NexArmError.timeout }
                    // A transport may synchronously receive telemetry during admission.
                    sentAt = .now
                    if try await observable.sendObserved(packet, session: session) { break }
                    try await Task.sleep(for: .milliseconds(25))
                }
                try await awaitArrival(
                    target: target, milliseconds: milliseconds, final: final,
                    started: sentAt, observable: observable, session: session, sequence: baseline,
                    actionDeadline: actionDeadline, jointTarget: jointTarget,
                    minimumObservationMilliseconds: minimumObservationMilliseconds)
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
                started: .now, observable: nil, session: nil, sequence: 0, actionDeadline: actionDeadline,
                jointTarget: jointTarget, minimumObservationMilliseconds: minimumObservationMilliseconds)
        }
    }

    private func awaitArrival(
        target: [Int], milliseconds: Int, final: Bool, started: ContinuousClock.Instant,
        observable: (any NexArmObservableLink)?, session: UUID?, sequence initialSequence: UInt64,
        actionDeadline: ContinuousClock.Instant, jointTarget: [Int]? = nil,
        minimumObservationMilliseconds: Int = 0, initialQueryDelayMilliseconds: Int = 0
    ) async throws {
        var tracker = NexArmArrivalTracker(
            target: target, final: final, started: started, durationMilliseconds: milliseconds,
            actionDeadline: actionDeadline, jointTarget: jointTarget,
            // Performance gestures promise arm motion, not a verified gripper position.
            // Keep all pose/encoder validation; only completion excludes claw and motor6.
            minimumObservationMilliseconds: minimumObservationMilliseconds, includeClaw: false)
        var sequence = initialSequence
        var nextQuery = started.advanced(by: .milliseconds(initialQueryDelayMilliseconds))
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
    }
    public func settingsTestFrames() throws -> [TestFrame] {
        if motorID != nil {
            return [try Self.homeFrame(milliseconds: 800)] + (try headFrames(center: NexArmJogPlanner.home))
                + [try Self.homeFrame(milliseconds: 800)]
        }
        return try cartesianPlaybackFrames(repetitions: 1)
    }
    /// Shared by Settings and scheduled Cartesian Actions; only their completion policy differs.
    fileprivate func cartesianPlaybackFrames(repetitions: Int) throws -> [TestFrame] {
        guard motorID == nil, (1...3).contains(repetitions),
            (self != .tiltLeft && self != .tiltRight) || repetitions == 1
        else { throw NexArmError.invalidMotion }
        let poses = [Self.ready] + (0..<repetitions).flatMap { _ in frames } + [Self.home]
        guard poses.count <= 20, poses.allSatisfy(Self.validPose) else { throw NexArmError.invalidMotion }
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
    fileprivate static let headFrameMilliseconds = 750
    public var motorID: Int? {
        switch self {
        case .nod: 4
        case .shakeHead: 5
        default: nil
        }
    }
    /// Two obvious back-and-forth sweeps, then center. Firmware acceleration smooths each reversal.
    public func headFrames(center: [Int]) throws -> [TestFrame] {
        guard let id = motorID, center.count == 6 else { throw NexArmError.invalidMotion }
        let amplitude = id == 4 ? 380 : 500  // About +/-33 and +/-44 degrees (4096 counts/revolution).
        return try [-amplitude, amplitude, -amplitude, amplitude, 0].map { offset in
            let target = center[id - 1] + offset
            guard NexArmJogPlanner.limits[id - 1].contains(target) else { throw NexArmError.invalidMotion }
            let speed = 1400
            return TestFrame(
                packet: try NexArmPacket(
                    id: UInt8(id), command: 3,
                    payload: [
                        41, 30, UInt8(target & 255), UInt8(target >> 8), 0, 0,
                        UInt8(speed & 255), UInt8(speed >> 8),
                    ]), milliseconds: Self.headFrameMilliseconds)
        }
    }
    fileprivate static func homeFrame(milliseconds: Int) throws -> TestFrame {
        return try poseFrame(home, milliseconds: milliseconds)
    }
    fileprivate static func poseFrame(_ pose: [Int], milliseconds: Int) throws -> TestFrame {
        let values = [pose[3], pose[0], pose[1], pose[2], pose[4], pose[5], milliseconds]
        return TestFrame(
            packet: try NexArmPacket(
                command: 8,
                payload: values.flatMap { value -> [UInt8] in
                    let bits = UInt16(bitPattern: Int16(value))
                    return [UInt8(bits & 255), UInt8(bits >> 8)]
                }), milliseconds: milliseconds)
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
        else { throw NexArmError.invalidMotion }
        let joints = Array(values[6..<11])
        guard zip(joints, NexArmJogPlanner.limits).allSatisfy({ $1.contains($0) }) else {
            throw NexArmError.invalidMotion
        }
        guard targets[key(frame)] != nil || targets.count < 64 else { throw NexArmError.overflow }
        targets[key(frame)] = joints
    }

    public func home(from joints: [Int]) throws -> NexArmGesture.TestFrame {
        try compile([NexArmGesture.homeFrame(milliseconds: 2000)], from: joints)[0]
    }

    public func compile(_ frames: [NexArmGesture.TestFrame], from joints: [Int]) throws -> [NexArmGesture.TestFrame] {
        guard joints.count == 6, joints.allSatisfy({ (0...4095).contains($0) }), frames.count <= 20 else {
            throw NexArmError.invalidMotion
        }
        var previous = Array(joints.prefix(5))
        return try frames.map { frame in
            if frame.packet.command == 3, let index = Int(exactly: frame.packet.id), (4...5).contains(index),
                frame.packet.isObservedControl
            {
                previous[index - 1] = Int(frame.packet.payload[2]) | Int(frame.packet.payload[3]) << 8
                return frame
            }
            guard let target = targets[key(frame)], frame.packet.command == 8, frame.packet.payload.count == 14,
                (400...2000).contains(frame.milliseconds)
            else { throw NexArmError.invalidMotion }
            var payload: [UInt8] = [41, 7]
            for index in 0..<5 {
                // Leave a fifth of each cadence for acceleration/deceleration; never use speed=0 (unbounded).
                let distance = abs(target[index] - previous[index])
                let speed = max(1, min(1400, Int(ceil(Double(distance) * 1250 / Double(frame.milliseconds)))))
                payload += [
                    UInt8(index + 1), 30, UInt8(target[index] & 255), UInt8(target[index] >> 8), 0, 0,
                    UInt8(speed & 255), UInt8(speed >> 8),
                ]
            }
            previous = target
            return NexArmGesture.TestFrame(
                packet: try NexArmPacket(id: 254, command: 131, payload: payload), milliseconds: frame.milliseconds)
        }
    }

    /// Command estimate for manual takeover, never reported as measured feedback; preserves motor6.
    public static func applying(_ packet: NexArmPacket, to previous: [Int]) throws -> [Int] {
        guard previous.count == 6 else { throw NexArmError.invalidMotion }
        var result = previous
        if packet.isArmControl {
            for index in 0..<5 {
                let offset = 2 + index * 8
                result[index] = Int(packet.payload[offset + 2]) | Int(packet.payload[offset + 3]) << 8
            }
        } else if packet.command == 3, (4...5).contains(packet.id), packet.isObservedControl {
            result[Int(packet.id) - 1] = Int(packet.payload[2]) | Int(packet.payload[3]) << 8
        } else {
            throw NexArmError.invalidMotion
        }
        return result
    }

    fileprivate static func singleMotor(id: Int, target: Int, speed: Int) throws -> NexArmPacket {
        guard (1...5).contains(id), NexArmJogPlanner.limits[id - 1].contains(target), (1...600).contains(speed) else {
            throw NexArmError.invalidMotion
        }
        return try NexArmPacket(
            id: UInt8(id), command: 3,
            payload: [41, 30, UInt8(target & 255), UInt8(target >> 8), 0, 0, UInt8(speed & 255), UInt8(speed >> 8)])
    }

    private static func words(_ bytes: [UInt8]) -> [Int] {
        stride(from: 0, to: bytes.count, by: 2).map {
            Int(Int16(bitPattern: UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8))
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
