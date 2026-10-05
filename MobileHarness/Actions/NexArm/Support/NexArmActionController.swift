import ActionRuntime
import Foundation
import PlatformKit

public enum NexArmCompatibilityPolicy: Sendable {
    case passiveBLE
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
    case admission, feedback
    case feedbackTimeout
    case completionTimeout
}

/// Supervised bounded motion owner. Device feedback does not establish physical clearance.
public actor NexArmActionController {
    private let link: any NexArmLink
    private var busy = false
    public private(set) var lockedMotors: Set<Int> = []
    public private(set) var unreachedSegments: [Int] = []
    public private(set) var motorResultRevision: UInt64 = 0
    public private(set) var motorResults: [NexArmMotorResult] = [] {
        didSet { motorResultRevision &+= 1 }
    }
    private var faulted = false
    private let compatibilityPolicy: NexArmCompatibilityPolicy
    private var compatibility: NexArmCompatibility?
    private var armPlan: NexArmArmPlan?
    private var motorHomes: [Int: Int] = [:]
    private var lastAimPositions: [Int]?
    public private(set) var cachedJoints: [Int] = []
    private var cachedPose: [Int] = []
    public var latestState: (joints: [Int], pose: [Int]) { (cachedJoints, cachedPose) }
    public private(set) var lastFailure: String?
    public private(set) var motionFailure: NexArmMotionFailure?
    public init(link: any NexArmLink, compatibilityPolicy: NexArmCompatibilityPolicy = .strictFirmware) {
        self.link = link
        self.compatibilityPolicy = compatibilityPolicy
    }

    /// Cache native unsolicited feedback; no query, compatibility probe or movement is issued.
    public func receivePassiveFeedback(_ packet: NexArmPacket) throws -> (joints: [Int], pose: [Int]) {
        let sample = try decodePosition(packet)
        return (sample.joints, sample.pose)
    }

    /// One controller belongs to one live connection; discard it on disconnect.
    @discardableResult
    public func verifyCompatibility() async throws -> NexArmCompatibility {
        try Task.checkCancellation()
        guard !busy else { throw NexArmExecutionError.busy }
        guard !faulted else { throw NexArmActionError.uncertainMotion }
        busy = true
        defer { busy = false }
        return try await requireCompatibility()
    }

    private func requireCompatibility() async throws -> NexArmCompatibility {
        motionFailure = nil
        try Task.checkCancellation()
        if let compatibility { return compatibility }
        if compatibilityPolicy == .passiveBLE {
            compatibility = .poseProtocol
            return .poseProtocol
        }
        if compatibilityPolicy == .nexArmBLEProtocol {
            // This validates the pose protocol, not any firmware version.
            let first = try await position()
            try await Task.sleep(for: .milliseconds(200))
            let second = try await position()
            for sample in [first, second] {
                guard hypot(Double(sample.pose[0]), Double(sample.pose[1])) <= 450,
                    (50...600).contains(sample.pose[2]), abs(sample.pose[3]) <= 1800,
                    abs(sample.pose[4]) <= 180, abs(sample.pose[5]) <= 180
                else { throw NexArmExecutionError.invalidArguments }
            }
            guard zip(first.joints.prefix(5), second.joints.prefix(5)).allSatisfy({ abs($0 - $1) <= 2 }) else {
                throw NexArmActionError.moving
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
            guard version.payload == [1, 0, 2, 0, 0, 0] else { throw NexArmExecutionError.unsupportedFirmware }
            if attempt < 3 { try await Task.sleep(for: .milliseconds(200)) }
        }
        throw NexArmExecutionError.firmwareUnavailable
    }

    /// Completion-only tracking write; accepted transport does not establish arrival.
    public func aim(base: Double, pitch: Double) async throws {
        try Task.checkCancellation()
        guard !busy else { throw NexArmExecutionError.busy }
        guard !faulted else { throw NexArmActionError.uncertainMotion }
        guard compatibility != nil else { throw NexArmExecutionError.firmwareUnavailable }
        guard let writer = link as? any NexArmWritableLink else { throw NexArmExecutionError.invalidArguments }
        let positions = try NexArmJointCommand.positions(base: base, pitch: pitch)
        let previous =
            lastAimPositions ?? (cachedJoints.count >= 5 ? Array(cachedJoints.prefix(5)) : NexArmJointCommand.armHome)
        let packet = try NexArmJointCommand.packet(positions: positions, previous: previous)
        busy = true
        lockedMotors = Set(1...5)
        motorResults = []
        defer {
            busy = false
            lockedMotors = []
        }
        lastFailure = nil
        motionFailure = .sending
        do {
            try await writer.write(packet)
            lastAimPositions = positions
            motionFailure = nil
        } catch {
            faulted = true
            lastFailure = String(describing: error)
            if error is CancellationError { throw CancellationError() }
            throw NexArmActionError.uncertainMotion
        }
    }

    /// Prepare a bounded, connection-local IK table before any motion/live session.
    public func prepareArmControl() async throws -> NexArmArmPlan {
        guard !busy else { throw NexArmExecutionError.busy }
        busy = true
        defer { busy = false }
        _ = try await requireCompatibility()
        return try await preparedArmPlan()
    }

    private func preparedArmPlan(for frames: [NexArmGesture.TestFrame]? = nil) async throws -> NexArmArmPlan {
        var plan = armPlan ?? NexArmArmPlan()
        let requested = try frames ?? NexArmGesture.allCases.flatMap { try $0.settingsTestFrames() }
        for frame in requested + [try NexArmGesture.homeFrame(milliseconds: 1000)] where frame.packet.command == 8 {
            try Task.checkCancellation()
            if plan.contains(frame) { continue }
            let reply = try await link.exchange(
                NexArmPacket(command: 7, payload: frame.packet.payload),
                replyID: 255, replyCommand: 7, replyCount: 24)
            try plan.insert(frame, reply: reply)
        }
        armPlan = plan
        return plan
    }

    /// Latest measured encoder values and Cartesian pose, never inferred from commands.
    public func readState() async throws -> (joints: [Int], pose: [Int]) {
        try Task.checkCancellation()
        guard !busy else { throw NexArmExecutionError.busy }
        guard !faulted else { throw NexArmActionError.uncertainMotion }
        busy = true
        defer { busy = false }
        let sample = try await position()
        return (sample.joints, sample.pose)
    }

    /// Read-only recovery after an unconfirmed movement. Never replays or rolls back a command.
    public func recoverState() async throws -> (joints: [Int], pose: [Int]) {
        lastAimPositions = nil
        try Task.checkCancellation()
        guard !busy else { throw NexArmExecutionError.busy }
        busy = true
        defer { busy = false }
        var sample = try await position()
        if faulted {
            func validPose(_ pose: [Int]) -> Bool {
                hypot(Double(pose[0]), Double(pose[1])) <= 450
                    && (50...600).contains(pose[2]) && abs(pose[3]) <= 1800
                    && abs(pose[4]) <= 180 && abs(pose[5]) <= 180
            }
            guard validPose(sample.pose) else { throw NexArmExecutionError.invalidArguments }
            let baseline = sample.joints
            for _ in 0..<2 {
                try await Task.sleep(for: .milliseconds(150))
                let next = try await position()
                guard validPose(next.pose) else { throw NexArmExecutionError.invalidArguments }
                guard zip(baseline.prefix(5), next.joints.prefix(5)).allSatisfy({ abs($0 - $1) <= 2 }) else {
                    throw NexArmActionError.moving
                }
                sample = next
            }
            try Task.checkCancellation()
            faulted = false
        }
        return (sample.joints, sample.pose)
    }

    /// Builds the shared recipe without a resource fence. Resolve only missing Cartesian targets;
    /// passive simple/reset plans issue no queries.
    /// A nil gesture selects whole-arm home. App owns cancellation and the live sending session.
    public func manualPlan(gesture: NexArmGesture?, repetitions: Int = 1, speed: Int = 1400, acceleration: Int = 30)
        async throws
        -> NexArmMotionPlan
    {
        try Task.checkCancellation()
        guard (1...3).contains(repetitions) else { throw NexArmExecutionError.invalidArguments }
        if compatibilityPolicy == .passiveBLE, gesture == nil || gesture?.motorID != nil {
            // Ordinary reset home is independent of the elevated Photographer tracking rest.
            let configured = NexArmGesture.referenceHomeJoints
            let home = gesture == nil ? configured : (cachedJoints.count == 6 ? cachedJoints : configured)
            let frames: [NexArmGesture.TestFrame]
            let motors: Set<Int>
            if let gesture {
                frames = try NexArmSimpleActions.frames(gesture, home: home, repetitions: repetitions)
                motors = gesture.lockedMotors
            } else {
                let atoms = try (1...5).map {
                    try NexArmSimpleActions.packet(id: $0, target: home[$0 - 1])
                }
                frames = [.init(packet: try NexArmMotorCommands.simultaneous(atoms), milliseconds: 1000)]
                motors = Set(1...5)
            }
            return try NexArmMotionPlan(lockedMotors: motors, frames: frames).configured(
                speed: speed, acceleration: acceleration)
        }
        let frames = try gesture.map { try $0.settingsTestFrames() } ?? [NexArmGesture.homeFrame(milliseconds: 1000)]
        let armPlan = try await preparedArmPlan(for: frames)
        let startingJoints = cachedJoints.count == 6 ? cachedJoints : NexArmGesture.referenceHomeJoints
        let plan =
            try gesture.map { try armPlan.motion($0, repetitions: repetitions, from: startingJoints) }
            ?? NexArmMotionPlan(lockedMotors: Set(1...5), frames: [armPlan.home(from: startingJoints)])
        return try plan.configured(speed: speed, acceleration: acceleration)
    }

    /// Explicit whole-arm reset, the only reset operation that owns all motors1–5.
    public func resetPosition(speed: Int = 1400, acceleration: Int = 30) async throws {
        try Task.checkCancellation()
        guard !busy else { throw NexArmExecutionError.busy }
        busy = true
        defer { busy = false }
        motorResults = []
        _ = try await requireCompatibility()
        if compatibilityPolicy == .passiveBLE {
            try await execute(manualPlan(gesture: nil, speed: speed, acceleration: acceleration))
            return
        }
        let plan = try await preparedArmPlan(for: [NexArmGesture.homeFrame(milliseconds: 1000)])
        if cachedJoints.count != 6 { _ = try await position() }
        try await execute(
            NexArmMotionPlan(lockedMotors: Set(1...5), frames: [plan.home(from: cachedJoints)]).configured(
                speed: speed, acceleration: acceleration))
    }

    /// Feedback-based Channel execution shares its recipe with manualPlan, not its arrival policy.
    public func performGesture(_ gesture: NexArmGesture, repetitions: Int, speed: Int = 1400, acceleration: Int = 30)
        async throws
    {
        try Task.checkCancellation()
        guard (1...3).contains(repetitions),
            (gesture != .tiltLeft && gesture != .tiltRight) || repetitions == 1
        else { throw NexArmExecutionError.invalidArguments }
        guard !busy else { throw NexArmExecutionError.busy }
        busy = true
        defer { busy = false }
        motorResults = []
        _ = try await requireCompatibility()
        if compatibilityPolicy == .passiveBLE {
            try await execute(
                manualPlan(gesture: gesture, repetitions: repetitions, speed: speed, acceleration: acceleration))
            return
        }
        let plan = try await preparedArmPlan(for: gesture.settingsTestFrames())
        if cachedJoints.count != 6 { _ = try await position() }
        try await execute(
            plan.motion(gesture, repetitions: repetitions, from: cachedJoints).configured(
                speed: speed, acceleration: acceleration))
    }

    /// Software reset target only; does not write calibration or firmware registers.
    public func configureMotorHome(id: Int, target: Int) throws {
        guard !busy, (1...6).contains(id), NexArmJogPlanner.limits[id - 1].contains(target) else {
            throw NexArmExecutionError.invalidArguments
        }
        motorHomes[id] = target
    }
    public func performPlan(_ plan: NexArmMotionPlan, completion: NexArmMotorCompletion) async throws {
        guard !busy else { throw NexArmExecutionError.busy }
        busy = true
        defer { busy = false }
        motorResults = []
        _ = try await requireCompatibility()
        try await execute(plan, policy: completion)
    }
    public func moveMotor(
        id: Int, target: Int, options: NexArmMotorOptions,
        completion: NexArmMotorCompletion
    ) async throws {
        guard !busy else { throw NexArmExecutionError.busy }
        busy = true
        defer { busy = false }
        motorResults = []
        _ = try await requireCompatibility()
        let packet = try NexArmMotorCommands.move(motor: id, target: target, options: options)
        try await execute(
            NexArmMotionPlan(lockedMotors: [id], frames: [.init(packet: packet, milliseconds: 1000)]),
            policy: completion)
    }
    public func resetMotor(
        id: Int, options: NexArmMotorOptions,
        completion: NexArmMotorCompletion
    ) async throws {
        let target: Int
        if let configured = motorHomes[id] {
            target = configured
        } else {
            guard (1...5).contains(id) else { throw NexArmExecutionError.invalidArguments }
            if compatibilityPolicy == .passiveBLE {
                target = NexArmGesture.referenceHomeJoints[id - 1]
            } else {
                let prepared = try await prepareArmControl()
                target = try prepared.homeJoints[id - 1]
            }
        }
        let packet = try NexArmMotorReset.reset(motor: id, home: [id: target], options: options)
        try await performPlan(
            NexArmMotionPlan(lockedMotors: [id], frames: [.init(packet: packet, milliseconds: 1000)]),
            completion: completion)
    }
    private func execute(_ plan: NexArmMotionPlan, policy suppliedPolicy: NexArmMotorCompletion? = nil) async throws {
        lastAimPositions = nil
        guard let observable = link as? any NexArmObservableLink else { throw NexArmExecutionError.invalidArguments }
        guard lockedMotors.isDisjoint(with: plan.lockedMotors) else { throw NexArmExecutionError.busy }
        lockedMotors = plan.lockedMotors
        defer { lockedMotors = [] }
        motorResults = []
        unreachedSegments = []
        faulted = false
        lastFailure = nil
        motionFailure = nil
        let policy = try suppliedPolicy ?? NexArmMotorCompletion()
        var session: UUID?
        var sequence: UInt64 = 0
        var lastFeedback = ContinuousClock.now
        var receivedFeedback = false
        var connectionFailure: NexArmMotorResult.Failure?
        var executionError: (any Error)?
        var cancelled = false
        do { session = try await observable.beginObservation() } catch {
            executionError = error
            if error is CancellationError {
                connectionFailure = .cancelled
                cancelled = true
            } else if error as? NexArmExecutionError == .feedbackTimeout {
                connectionFailure = .feedbackLost
            } else if error as? NexArmError == .disconnected {
                connectionFailure = .disconnected
            } else {
                connectionFailure = .admissionFailed
            }
        }
        for (index, step) in plan.steps.enumerated() {
            var pending = step.targets
            func result(_ motor: Int, _ failure: NexArmMotorResult.Failure?, started: Bool) -> NexArmMotorResult {
                NexArmMotorResult(
                    step: index + 1, motor: motor, target: step.targets[motor]!,
                    observed: cachedJoints.count == 6 ? cachedJoints[motor - 1] : nil,
                    failure: failure, started: started)
            }
            if Task.isCancelled || cancelled {
                motorResults += pending.keys.sorted().map { result($0, .cancelled, started: false) }
                continue
            }
            if let connectionFailure {
                motorResults += pending.keys.sorted().map { result($0, connectionFailure, started: false) }
                continue
            }
            guard let session else { continue }
            var committed = false
            var stage: NexArmMotorResult.Failure = .feedbackFailed
            do {
                let admissionDeadline = ContinuousClock.now.advanced(by: .seconds(1))
                var sentAt = ContinuousClock.now
                while true {
                    try Task.checkCancellation()
                    if let sample = try await observable.latestObservation(after: sequence, session: session) {
                        _ = try decodePosition(sample.packet)
                        sequence = sample.sequence
                        lastFeedback = sample.receivedAt
                        receivedFeedback = true
                    }
                    guard ContinuousClock.now - lastFeedback < .milliseconds(policy.feedbackMilliseconds) else {
                        throw NexArmExecutionError.feedbackTimeout
                    }
                    guard ContinuousClock.now < admissionDeadline else { throw NexArmExecutionError.admissionTimeout }
                    sentAt = .now
                    stage = .sendingFailed
                    if try await observable.sendObserved(step.packet, session: session) {
                        committed = true
                        break
                    }
                    stage = .feedbackFailed
                    try await Task.sleep(for: .milliseconds(20))
                }
                stage = .feedbackFailed
                var trackers: [Int: NexArmSegmentTracker] = [:]
                for (motor, target) in step.targets {
                    let options = try step.options(for: motor)
                    let estimate = NexArmMotorProfiles.budget(
                        motor: motor, from: receivedFeedback && cachedJoints.count == 6 ? cachedJoints[motor - 1] : nil,
                        target: target, options: options)
                    let timeout = policy.timeoutMilliseconds ?? estimate.timeoutMilliseconds
                    let motorPolicy = try NexArmMotorCompletion(
                        tolerance: policy.tolerance ?? NexArmMotorProfiles.profile(for: motor).tolerance,
                        stableTolerance: policy.stableTolerance,
                        offTargetMilliseconds: max(policy.offTargetMilliseconds, estimate.offTargetMilliseconds),
                        feedbackMilliseconds: policy.feedbackMilliseconds, timeoutMilliseconds: timeout)
                    trackers[motor] = NexArmSegmentTracker(
                        targets: [motor: target], started: sentAt,
                        deadline: sentAt.advanced(by: .milliseconds(timeout)), policy: motorPolicy)
                }
                while !pending.isEmpty {
                    try Task.checkCancellation()
                    if let sample = try await observable.latestObservation(after: sequence, session: session) {
                        sequence = sample.sequence
                        lastFeedback = sample.receivedAt
                        receivedFeedback = true
                        let state = try decodePosition(sample.packet)
                        for motor in pending.keys {
                            trackers[motor]?.observe(joints: state.joints, at: sample.receivedAt)
                        }
                    }
                    guard ContinuousClock.now - lastFeedback < .milliseconds(policy.feedbackMilliseconds) else {
                        throw NexArmExecutionError.feedbackTimeout
                    }
                    for motor in pending.keys.sorted() {
                        switch trackers[motor]?.outcome(at: .now) {
                        case .arrived:
                            motorResults.append(result(motor, nil, started: true))
                            pending[motor] = nil
                        case .timedOut:
                            motorResults.append(result(motor, .timedOut, started: true))
                            pending[motor] = nil
                        case .unreached:
                            motorResults.append(result(motor, .targetNotReached, started: true))
                            pending[motor] = nil
                        default: break
                        }
                    }
                    if !pending.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
                }
            } catch {
                if executionError == nil { executionError = error }
                let failure: NexArmMotorResult.Failure
                if error is CancellationError {
                    failure = .cancelled
                    cancelled = true
                } else if error as? NexArmExecutionError == .feedbackTimeout {
                    failure = .feedbackLost
                    connectionFailure = failure
                } else if error as? NexArmError == .disconnected {
                    failure = .disconnected
                    connectionFailure = failure
                } else {
                    failure = error as? NexArmExecutionError == .admissionTimeout ? .admissionFailed : stage
                }
                motorResults += pending.keys.sorted().map { result($0, failure, started: committed) }
            }
        }
        if let session { await observable.endObservation(session) }
        if cancelled { throw CancellationError() }
        unreachedSegments = Array(Set(motorResults.filter { $0.failure == .targetNotReached }.map(\.step))).sorted()
        try Task.checkCancellation()
        if let failure = motorResults.first(where: { $0.failure != nil })?.failure {
            faulted = true
            lastFailure = failure.rawValue
            switch failure {
            case .feedbackLost: motionFailure = .feedbackTimeout
            case .sendingFailed, .disconnected: motionFailure = .sending
            case .admissionFailed: motionFailure = .admission
            case .feedbackFailed: motionFailure = .feedback
            default: motionFailure = .completionTimeout
            }
            if let executionError { throw executionError }
            switch failure {
            case .timedOut:
                throw NexArmActionError.motionTimedOut(
                    Array(Set(motorResults.filter { $0.failure == .timedOut }.map(\.step))).sorted())
            case .targetNotReached:
                throw NexArmActionError.targetsNotReached(unreachedSegments)
            default:
                // Native/observation errors were retained above; never synthesize a different device error.
                throw NexArmActionError.uncertainMotion
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
