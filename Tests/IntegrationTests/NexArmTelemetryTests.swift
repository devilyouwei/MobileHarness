import Actions
import AgentCore
import CallRuntime
import ExecutionRuntime
import Foundation
import FunctionContracts
import Gateway
import PlatformKit
import StorageCore
import Testing

@testable import Agents

private func telemetryPacket(_ pose: [Int]) throws -> NexArmPacket {
    let values = pose + [2048, 2087, 1198, 1238, 2048, 2048]
    return try NexArmPacket(
        command: 11,
        payload: values.flatMap {
            let bits = UInt16(bitPattern: Int16($0))
            return [UInt8(bits & 255), UInt8(bits >> 8)]
        })
}

@Test(.actionCatalog) func nexArmContinuousTelemetryCachesUnsolicitedFragmentedFrames() throws {
    var cache = NexArmTelemetryCache()
    let packet = try telemetryPacket([200, 0, 200, 0, 0, 0])
    try cache.receive(Array(packet.bytes.prefix(8)))
    #expect(cache.latest == nil)
    try cache.receive(Array(packet.bytes.dropFirst(8)))
    #expect(cache.latest?.packet == packet)
    for _ in 0..<1000 { try cache.receive(packet.bytes) }
    #expect(cache.latest?.sequence == 1001)
    try cache.receive(NexArmPacket(command: 1, payload: [1, 0, 2]).bytes)
    #expect(cache.latest?.sequence == 1001)
    #expect(throws: NexArmError.overflow) { try cache.receive(Array(repeating: 0, count: 4097)) }
}

@Test(.actionCatalog) func nexArmArrivalWatchdogRequiresObservedStabilityAndHasIndependentDeadlines() {
    let now = ContinuousClock.now
    let target = [200, 0, 200, 0, 0, 0]
    let joints = [2048, 2087, 1198, 1238, 2048, 2048]
    var tracker = NexArmArrivalTracker(target: target, final: true, started: now, durationMilliseconds: 800)
    tracker.observe(pose: target, joints: joints, at: now.advanced(by: .milliseconds(-1)))
    #expect(tracker.outcome(at: now) == .waiting)
    tracker.observe(pose: target, joints: joints, at: now)
    #expect(tracker.outcome(at: now.advanced(by: .seconds(1))) == .waiting)
    #expect(tracker.outcome(at: now.advanced(by: .seconds(2))) == .feedbackTimeout)
    tracker.observe(pose: target, joints: joints, at: now.advanced(by: .milliseconds(300)))
    #expect(tracker.outcome(at: now.advanced(by: .milliseconds(300))) == .waiting)
    tracker.observe(pose: target, joints: joints, at: now.advanced(by: .milliseconds(800)))
    #expect(tracker.outcome(at: now.advanced(by: .milliseconds(800))) == .arrived)
    var stuck = NexArmArrivalTracker(target: target, final: false, started: now, durationMilliseconds: 800)
    for n in 0..<40 {
        let time = now.advanced(by: .milliseconds(n * 100))
        stuck.observe(pose: [200, 0, 250, 0, 0, 0], joints: joints, at: time)
    }
    #expect(stuck.outcome(at: now.advanced(by: .seconds(4))) == .completionTimeout)
}

/// Simulated notification-capable device; no real Bluetooth/serial use.
private actor ObservableArmFixture: NexArmObservableLink {
    var ik = NexArmTestIK()
    enum Mode { case push, queryOnly, silent, cachedOnly }
    var mode: Mode
    var independentClaw = false
    func offsetClaw() { independentClaw = true }
    var cache = NexArmTelemetryCache()
    var session: String?
    var pose = [200, 0, 200, 0, 0, 0]
    var joints = NexArmGesture.referenceHomeJoints
    var skippedWrite: Int?
    func skip(_ index: Int) { skippedWrite = index }
    var lastPush = ContinuousClock.now.advanced(by: .seconds(-1))
    private(set) var writes = 0
    private(set) var queries = 0
    private var trajectoryEnds: ContinuousClock.Instant?
    private(set) var earlyHandoffs = 0
    private(set) var packets: [NexArmPacket] = []
    private(set) var sentAt: [ContinuousClock.Instant] = []
    private(set) var earlyQueries = 0
    private(set) var queriedAfterWrites: [Int] = []
    private var admissionBlocked = false
    func blockAdmission() { admissionBlocked = true }
    init(_ mode: Mode) { self.mode = mode }
    func configure(_ value: Mode) { mode = value }
    func revoke() { session = nil }
    func beginObservation() -> String {
        let token = UUID().uuidString
        session = token
        return token
    }
    func endObservation(_ token: String) { if session == token { session = nil } }
    func sendObserved(_ packet: NexArmPacket, session token: String) throws -> Bool {
        guard session == token else { throw CancellationError() }
        if packet.isSynchronousPositionWrite {
            let intent = try ik.intent(packet)
            if admissionBlocked { return false }
            guard packets.count < 40 else { throw NexArmError.overflow }
            packets.append(packet)
            sentAt.append(.now)
            if let trajectoryEnds, ContinuousClock.now < trajectoryEnds { earlyHandoffs += 1 }
            let values = ik.words(intent.payload)
            let duration = values[3] == 200 ? 600 : (values[1] == 200 && values[2] == 0 && values[4] == 0 ? 400 : 800)
            trajectoryEnds = .now.advanced(by: .milliseconds(duration))
            writes += 1
            if writes != skippedWrite {
                for (id, target) in packet.motorTargets ?? [:] { joints[id - 1] = target }
            }
            let v = stride(from: 0, to: 12, by: 2).map {
                Int(Int16(bitPattern: UInt16(intent.payload[$0]) | UInt16(intent.payload[$0 + 1]) << 8))
            }
            pose = [v[1], v[2], v[3], v[0], v[4], v[5]]
            if mode == .push || mode == .cachedOnly { try publish() }
        } else {
            #expect(packet.command == 11)
            if let trajectoryEnds, ContinuousClock.now < trajectoryEnds { earlyQueries += 1 }
            guard queriedAfterWrites.count < 64 else { throw NexArmError.overflow }
            queriedAfterWrites.append(writes)
            queries += 1
            if mode == .queryOnly { try publish() }
        }
        return true
    }
    private func publish() throws {
        var reported = pose
        if independentClaw { reported[5] = -6 }
        var payload = try telemetryPacket(reported).payload
        for (index, joint) in joints.enumerated() {
            payload[12 + index * 2] = UInt8(joint & 255)
            payload[13 + index * 2] = UInt8(joint >> 8)
        }
        if independentClaw {
            // An unrelated gripper can move while the five arm joints are stable.
            let encoder = (cache.latest?.sequence ?? 0).isMultiple(of: 2) ? 1977 : 2000
            payload[22] = UInt8(encoder & 255)
            payload[23] = UInt8(encoder >> 8)
        }
        try cache.receive(NexArmPacket(command: 11, payload: payload).bytes)
        lastPush = .now
    }
    func latestObservation(after sequence: UInt64, session token: String) throws -> NexArmTelemetry? {
        guard session == token else { throw CancellationError() }
        if mode == .push, ContinuousClock.now - lastPush >= .milliseconds(100) { try publish() }
        guard let latest = cache.latest, latest.sequence > sequence else { return nil }
        return latest
    }
    func exchange(_ packet: NexArmPacket, replyID: UInt8, replyCommand: UInt8, replyCount: Int) throws -> NexArmPacket {
        if packet.command == 7 { return try ik.reply(packet) }
        if packet.command == 11 { return try telemetryPacket(pose) }
        #expect(packet.command == 1)  // Exchanges are preparation-only, never during playback.
        return try NexArmPacket(command: 1, payload: [1, 0, 2, 1, 0, 2])
    }
    func write(_ packet: NexArmPacket) throws { throw NexArmError.invalidPacket }
    func close() { session = nil }
}

extension LiveRuntimeTests {
    @Test(.actionCatalog) func nexArmPerformanceCompletionDoesNotRequireClawConvergence() async throws {
        let link = ObservableArmFixture(.push)
        await link.offsetClaw()
        let controller = NexArmActionController(link: link)
        try await controller.performGesture(.tiltLeft, repetitions: 1)
        #expect(await link.writes == 3)
        #expect(await controller.latestState.pose[5] == -6)
        #expect(await controller.motionFailure == nil)
    }
}

@Test(.actionCatalog, arguments: [false, true])
func nexArmArmOnlyArrivalRetainsPoseJointAndDeadlineGates(nativeTarget: Bool) {
    let start = ContinuousClock.now
    let pose = [200, 0, 200, 0, 0, 0]
    let joints = [2048, 2087, 1198, 1238, 2048, 2048]
    func make(includeClaw: Bool = false) -> NexArmArrivalTracker {
        NexArmArrivalTracker(
            target: pose, final: true, started: start, durationMilliseconds: 0,
            jointTarget: nativeTarget ? joints : nil, includeClaw: includeClaw)
    }
    var arm = make()
    var strict = make(includeClaw: true)
    var measured = pose
    measured[5] = -6
    for n in 0...3 {
        var movingClaw = joints
        movingClaw[5] = 1977 + n * 10
        let time = start.advanced(by: .milliseconds(n * 100))
        arm.observe(pose: measured, joints: movingClaw, at: time)
        strict.observe(pose: measured, joints: movingClaw, at: time)
    }
    #expect(arm.outcome(at: start.advanced(by: .milliseconds(300))) == .arrived)
    #expect(strict.outcome(at: start.advanced(by: .milliseconds(300))) == .waiting)
    for axis in 0..<5 {
        var unstable = make()
        for n in 0...3 {
            var moved = joints
            moved[axis] += n * 4
            unstable.observe(pose: measured, joints: moved, at: start.advanced(by: .milliseconds(n * 100)))
        }
        #expect(unstable.outcome(at: start.advanced(by: .milliseconds(300))) == .waiting)
    }
    var missed = make()
    var outside = measured
    outside[0] += 6
    var outsideJoints = joints
    outsideJoints[3] += 17
    for n in 0...30 {
        missed.observe(pose: outside, joints: outsideJoints, at: start.advanced(by: .milliseconds(n * 100)))
    }
    #expect(missed.outcome(at: start.advanced(by: .seconds(3))) == .completionTimeout)
}

extension LiveRuntimeTests {
    @Test(.actionCatalog, arguments: [NexArmGesture.tiltLeft, .celebrate, .dance])
    func nexArmChannelUsesFreshMotorFeedbackWithoutNominalWait(_ gesture: NexArmGesture) async throws {
        let link = ObservableArmFixture(.push)
        let controller = NexArmActionController(link: link)
        let began = ContinuousClock.now
        try await controller.performGesture(gesture, repetitions: 1)
        let plan = try await controller.prepareArmControl()
        let frames = try plan.motion(gesture, repetitions: 1, from: NexArmGesture.referenceHomeJoints).steps
        #expect(await link.packets == frames.map(\.packet))
        #expect(ContinuousClock.now - began < .seconds(3))
        let times = await link.sentAt
        for index in 1..<times.count {
            #expect(times[index] - times[index - 1] < .milliseconds(400))
        }
        #expect(await link.queries == 0)
        #expect(await link.session == nil)
    }
}

extension LiveRuntimeTests {
    @Test(.actionCatalog) func nexArmFeedbackLossAbortsWithoutQueryFallback() async throws {
        let link = ObservableArmFixture(.queryOnly)
        let controller = NexArmActionController(link: link)
        await #expect(throws: NexArmExecutionError.feedbackTimeout) {
            try await controller.performGesture(.tiltRight, repetitions: 1)
        }
        #expect(await link.queries == 0)
        #expect(await controller.motionFailure == .feedbackTimeout)
        #expect(await link.writes < 3)
        #expect(await controller.motorResults.count == 15)
        #expect(await controller.motorResults.allSatisfy { $0.failure == .feedbackLost })
        #expect(await controller.motorResults.contains { !$0.started && $0.step == 3 })
    }
}

extension LiveRuntimeTests {
    @Test(.actionCatalog) func nexArmMissingFeedbackEndsAwaitWithoutReplayAndNextRequestCanRun() async throws {
        let link = ObservableArmFixture(.silent)
        let controller = NexArmActionController(link: link)
        let began = ContinuousClock.now
        await #expect(throws: NexArmExecutionError.feedbackTimeout) {
            try await controller.performGesture(.wave, repetitions: 1)
        }
        #expect(ContinuousClock.now - began < .seconds(8))
        #expect(await controller.motionFailure == .feedbackTimeout)
        let sentBeforeLoss = await link.writes
        #expect(sentBeforeLoss < 6)
        #expect(await link.session == nil)
        await link.configure(.push)
        try await controller.performGesture(.tiltLeft, repetitions: 1)
        #expect(await link.writes == sentBeforeLoss + 3)
    }
}

extension LiveRuntimeTests {
    @Test(.actionCatalog) func nexArmObservationTakeoverCancelsAwaitAndStopsFurtherFrames() async throws {
        let link = ObservableArmFixture(.silent)
        let controller = NexArmActionController(link: link)
        let task = Task { try await controller.performGesture(.wave, repetitions: 1) }
        for _ in 0..<100 {
            if await link.writes > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        await link.revoke()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await link.writes == 1)
    }
}

@Test(.actionCatalog) func nexArmWholeActionDeadlineCannotBeExtendedByNewSegments() {
    let now = ContinuousClock.now
    let deadline = now.advanced(by: .milliseconds(100))
    let tracker = NexArmArrivalTracker(
        target: [200, 0, 200, 0, 0, 0], final: false,
        started: now, durationMilliseconds: 3000, actionDeadline: deadline)
    #expect(tracker.outcome(at: deadline) == .completionTimeout)
}

@Test(.actionCatalog, arguments: [false, true])
func nexArmEverySegmentRequiresFreshArrivalAfterNominalDuration(_ final: Bool) {
    let start = ContinuousClock.now
    let pose = [200, 0, 240, 0, 0, 0]
    let joints = NexArmGesture.referenceHomeJoints
    var tracker = NexArmArrivalTracker(
        target: pose, final: final, started: start, durationMilliseconds: 800,
        minimumObservationMilliseconds: 100)
    tracker.observe(pose: pose, joints: joints, at: start)
    tracker.observe(pose: pose, joints: joints, at: start.advanced(by: .milliseconds(350)))
    #expect(tracker.outcome(at: start.advanced(by: .milliseconds(350))) == .waiting)
    // Neither early stability nor a delayed host wakeup may release the next command.
    #expect(tracker.outcome(at: start.advanced(by: .milliseconds(900))) == .waiting)
    tracker.observe(pose: pose, joints: joints, at: start.advanced(by: .milliseconds(900)))
    #expect(tracker.outcome(at: start.advanced(by: .milliseconds(900))) == .arrived)
}

@Test(.actionCatalog) func nexArmEarlyPlateauCannotHideLaterMovementOrFeedbackLoss() {
    let start = ContinuousClock.now
    let pose = [200, 0, 240, 0, 0, 0]
    let joints = NexArmGesture.referenceHomeJoints
    var tracker = NexArmArrivalTracker(target: pose, final: false, started: start, durationMilliseconds: 3000)
    tracker.observe(pose: pose, joints: joints, at: start)
    tracker.observe(pose: pose, joints: joints, at: start.advanced(by: .milliseconds(300)))
    #expect(tracker.outcome(at: start.advanced(by: .milliseconds(300))) == .waiting)
    // The motion-duration gate must not postpone the independent silence watchdog.
    #expect(tracker.outcome(at: start.advanced(by: .milliseconds(2300))) == .feedbackTimeout)
    tracker.observe(pose: [200, 0, 210, 0, 0, 0], joints: joints, at: start.advanced(by: .milliseconds(1000)))
    tracker.observe(pose: pose, joints: joints, at: start.advanced(by: .milliseconds(3000)))
    #expect(tracker.outcome(at: start.advanced(by: .milliseconds(3000))) == .waiting)
    tracker.observe(pose: pose, joints: joints, at: start.advanced(by: .milliseconds(3200)))
    #expect(tracker.outcome(at: start.advanced(by: .milliseconds(3200))) == .arrived)
}

@Test(.actionCatalog) func nexArmObservedSegmentBudgetRetainsItsOwnDeadline() {
    let started = ContinuousClock.now
    let durations = [3000] + Array(repeating: 800, count: 8) + [1200]
    let budget = durations.reduce(Duration.zero) {
        $0 + NexArmArrivalTracker.completionBudget(durationMilliseconds: $1)
    }
    #expect(budget == .milliseconds(40600))
    let deadline = started.advanced(by: budget)
    // Hardware reached dance leg 8 at 12.738s. The old 13.6s global deadline cut it mid-motion.
    let legStart = started.advanced(by: .milliseconds(12738))
    let target = [193, 52, 240, 0, 30, 0]
    let joints = [1877, 2269, 1337, 1591, 2388, 2026]
    var tracker = NexArmArrivalTracker(
        target: target, final: false, started: legStart, durationMilliseconds: 800,
        actionDeadline: deadline)
    tracker.observe(pose: target, joints: joints, at: started.advanced(by: .milliseconds(13900)))
    #expect(tracker.outcome(at: started.advanced(by: .milliseconds(13900))) == .waiting)
    tracker.observe(pose: target, joints: joints, at: started.advanced(by: .milliseconds(14100)))
    #expect(tracker.outcome(at: started.advanced(by: .milliseconds(14100))) == .arrived)
    // The larger aggregate budget cannot extend an individual stalled leg.
    #expect(tracker.outcome(at: legStart.advanced(by: .milliseconds(3800))) == .completionTimeout)
}

extension LiveRuntimeTests {
    @Test(.actionCatalog) func nexArmPlaybackCongestionRejectsWithoutReplayingMotion() async throws {
        let link = ObservableArmFixture(.queryOnly)
        // Keep the fixture congested for the whole operation. A timed unblock races the
        // next child admission after preparation and cannot prove zero committed writes.
        await link.blockAdmission()
        let controller = NexArmActionController(link: link)
        await #expect(throws: NexArmExecutionError.admissionTimeout) {
            try await controller.performGesture(.dance, repetitions: 1)
        }
        #expect(await link.writes == 0)
        #expect(await link.queries == 0)
        #expect(await link.session == nil)
        #expect(await controller.motionFailure == .admission)
    }
}

extension LiveRuntimeTests {
    @Test(.actionCatalog) func nexArmChannelKeepsNextActionQueuedUntilFreshFinalHome() async throws {
        let link = ObservableArmFixture(.push)
        let controller = NexArmActionController(link: link)
        let registry = try ActionRegistry(modules: [
            NexArmGestureModule { request, _ in
                try await controller.performGesture(
                    request.gesture == .celebrate ? .celebrate : .dance,
                    repetitions: request.repetitions)
            }
        ])
        let scheduler = ChannelScheduler(registry: registry, resources: try nexArmTestResources())
        let input = AgentInput(
            id: UUID().uuidString, sessionID: UUID().uuidString, payload: .text("two gestures"))
        for (function, channel) in [("celebrate", "Robot"), ("dance", "Robot")] {
            try await scheduler.enqueue(
                invocation: ActionInvocation(
                    source: .assistant, input: input,
                    call: ActionCall(
                        actionPath: ActionPath(
                            domain: "NexArm",
                            module: ["shakeBase", "reset", "moveMotor", "resetMotor"].contains(function)
                                ? "Motion" : "Gesture", function: function),
                        channel: channel, parameters: ["cycles": "1"])))
        }
        try await scheduler.finish(inputID: input.id, source: AgentID(rawValue: "assistant"))
        #expect(await link.writes == 14)
        #expect(await link.queries == 0)
        #expect(await controller.lockedMotors.isEmpty)
    }
}

extension LiveRuntimeTests {
    @Test(.actionCatalog) func nexArmCachedHomeDuringPlaybackCannotConfirmFinalCompletion() async throws {
        let link = ObservableArmFixture(.silent)
        let controller = NexArmActionController(link: link)
        await #expect(throws: NexArmExecutionError.feedbackTimeout) {
            try await controller.performGesture(.tiltLeft, repetitions: 1)
        }
        #expect(await link.writes < 3)
        #expect(await link.queries == 0)
        #expect(await controller.motionFailure == .feedbackTimeout)
    }
}

extension LiveRuntimeTests {
    @Test(.actionCatalog) func nexArmIntermediateTimeoutAdvancesAndReportsMissingSegmentAfterEnding() async throws {
        let link = ObservableArmFixture(.push)
        await link.skip(2)
        let controller = NexArmActionController(link: link)
        await #expect(throws: NexArmActionError.targetsNotReached([2])) {
            try await controller.performGesture(.dance, repetitions: 1)
        }
        #expect(await link.writes == 8)
        #expect(await link.queries == 0)
        #expect(await controller.unreachedSegments == [2])
        #expect(await controller.lockedMotors.isEmpty)
        #expect(await controller.cachedJoints.prefix(5) == [2048, 2087, 1225, 1238, 2048])
    }
}

@Test(.actionCatalog) func nexArmMotorScopeFreshnessAndFeedbackWatchdogAreIndependent() {
    let start = ContinuousClock.now
    var tracker = NexArmSegmentTracker(
        targets: [4: 1500], started: start,
        deadline: start.advanced(by: .seconds(1)))
    var joints = NexArmGesture.referenceHomeJoints
    joints[3] = 1500
    tracker.observe(joints: joints, at: start.advanced(by: .milliseconds(-1)))
    #expect(tracker.outcome(at: start) == .waiting)
    tracker.observe(joints: joints, at: start)
    #expect(tracker.outcome(at: start.advanced(by: .milliseconds(500))) == .arrived)
    joints[0] += 100
    joints[1] += 200
    joints[5] -= 300
    tracker.observe(joints: joints, at: start.advanced(by: .milliseconds(200)))
    #expect(tracker.outcome(at: start.advanced(by: .milliseconds(200))) == .arrived)
    var stuck = NexArmSegmentTracker(
        targets: [4: 1600], started: start,
        deadline: start.advanced(by: .seconds(1)))
    var health = NexArmFeedbackWatchdog(started: start)
    for n in 0...5 {
        let time = start.advanced(by: .milliseconds(n * 200))
        stuck.observe(joints: joints, at: time)
        health.observe(at: time)
    }
    #expect(stuck.outcome(at: start.advanced(by: .seconds(1))) == .timedOut)
    #expect(!health.isLost(at: start.advanced(by: .seconds(1))))
    #expect(health.isLost(at: start.advanced(by: .seconds(3))))
}

@Test(.actionCatalog) func nexArmPlanRejectsWritesOutsideDeclaredMotorLocks() throws {
    let frames = try NexArmGesture.nod.settingsTestFrames()
    #expect(throws: NexArmExecutionError.invalidArguments) { try NexArmMotionPlan(lockedMotors: [5], frames: frames) }
    let plan = try NexArmMotionPlan(lockedMotors: [4], frames: frames)
    #expect(plan.steps.allSatisfy { Set($0.targets.keys) == [4] })
}
