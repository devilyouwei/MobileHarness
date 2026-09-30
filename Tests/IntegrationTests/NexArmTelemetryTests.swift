import Foundation
import PlatformKit
import Testing

private func telemetryPacket(_ pose: [Int]) throws -> NexArmPacket {
    let values = pose + [2048, 2087, 1198, 1238, 2048, 2048]
    return try NexArmPacket(
        command: 11,
        payload: values.flatMap {
            let bits = UInt16(bitPattern: Int16($0))
            return [UInt8(bits & 255), UInt8(bits >> 8)]
        })
}

@Test func nexArmContinuousTelemetryCachesUnsolicitedFragmentedFrames() throws {
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

@Test func nexArmArrivalWatchdogRequiresObservedStabilityAndHasIndependentDeadlines() {
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
    #expect(tracker.outcome(at: now.advanced(by: .milliseconds(300))) == .arrived)
    var stuck = NexArmArrivalTracker(target: target, final: false, started: now, durationMilliseconds: 800)
    for n in 0..<40 {
        let time = now.advanced(by: .milliseconds(n * 100))
        stuck.observe(pose: [200, 0, 250, 0, 0, 0], joints: joints, at: time)
    }
    #expect(stuck.outcome(at: now.advanced(by: .seconds(4))) == .completionTimeout)
}

/// Simulated notification-capable device; no real Bluetooth/serial use.
private actor ObservableArmFixture: NexArmObservableLink {
    enum Mode { case push, queryOnly, silent }
    var mode: Mode
    var cache = NexArmTelemetryCache()
    var session: UUID?
    var pose = [200, 0, 200, 0, 0, 0]
    var lastPush = ContinuousClock.now.advanced(by: .seconds(-1))
    private(set) var writes = 0
    private(set) var queries = 0
    init(_ mode: Mode) { self.mode = mode }
    func configure(_ value: Mode) { mode = value }
    func revoke() { session = nil }
    func beginObservation() -> UUID {
        let token = UUID()
        session = token
        return token
    }
    func endObservation(_ token: UUID) { if session == token { session = nil } }
    func sendObserved(_ packet: NexArmPacket, session token: UUID) throws -> Bool {
        guard session == token else { throw CancellationError() }
        if packet.command == 8 {
            writes += 1
            let v = stride(from: 0, to: 12, by: 2).map {
                Int(Int16(bitPattern: UInt16(packet.payload[$0]) | UInt16(packet.payload[$0 + 1]) << 8))
            }
            pose = [v[1], v[2], v[3], v[0], v[4], v[5]]
            if mode == .push { try publish() }
        } else {
            #expect(packet.command == 11)
            queries += 1
            if mode == .queryOnly { try publish() }
        }
        return true
    }
    private func publish() throws {
        try cache.receive(telemetryPacket(pose).bytes)
        lastPush = .now
    }
    func latestObservation(after sequence: UInt64, session token: UUID) throws -> NexArmTelemetry? {
        guard session == token else { throw CancellationError() }
        if mode == .push, ContinuousClock.now - lastPush >= .milliseconds(100) { try publish() }
        guard let latest = cache.latest, latest.sequence > sequence else { return nil }
        return latest
    }
    func exchange(_ packet: NexArmPacket, replyID: UInt8, replyCommand: UInt8, replyCount: Int) throws -> NexArmPacket {
        #expect(packet.command == 1)  // Compatibility only; completion never uses a blocking exchange.
        return try NexArmPacket(command: 1, payload: [1, 0, 2, 1, 0, 2])
    }
    func write(_ packet: NexArmPacket) throws { throw NexArmError.invalidPacket }
    func close() { session = nil }
}

@Test func nexArmChannelAwaitsPushCompletionWithoutFixedSleepOrQueries() async throws {
    let link = ObservableArmFixture(.push)
    let controller = NexArmController(link: link)
    let began = ContinuousClock.now
    try await controller.performGesture(.tiltLeft, repetitions: 1)
    #expect(ContinuousClock.now - began < .seconds(3))
    #expect(await link.writes == 5)
    #expect(await link.queries == 0)
    #expect(await link.session == nil)
}

@Test func nexArmChannelUsesBoundedQueryFallbackWhenNoPush() async throws {
    let link = ObservableArmFixture(.queryOnly)
    try await NexArmController(link: link).performGesture(.tiltRight, repetitions: 1)
    #expect(await link.writes == 5)
    let queries = await link.queries
    #expect(queries >= 10 && queries <= 20)
}

@Test func nexArmMissingFeedbackEndsAwaitWithoutReplayAndNextRequestCanRun() async throws {
    let link = ObservableArmFixture(.silent)
    let controller = NexArmController(link: link)
    let began = ContinuousClock.now
    await #expect(throws: NexArmError.uncertainMotion) { try await controller.performGesture(.wave, repetitions: 1) }
    #expect(ContinuousClock.now - began < .seconds(3))
    #expect(await controller.motionFailure == .feedbackTimeout)
    #expect(await link.writes == 1)
    #expect(await link.session == nil)
    await link.configure(.push)
    try await controller.performGesture(.tiltLeft, repetitions: 1)
    #expect(await link.writes == 6)
}

@Test func nexArmObservationTakeoverCancelsAwaitAndStopsFurtherFrames() async throws {
    let link = ObservableArmFixture(.silent)
    let controller = NexArmController(link: link)
    let task = Task { try await controller.performGesture(.wave, repetitions: 1) }
    for _ in 0..<100 {
        if await link.writes > 0 { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    await link.revoke()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(await link.writes == 1)
}

@Test func nexArmWholeActionDeadlineCannotBeExtendedByNewSegments() {
    let now = ContinuousClock.now
    let deadline = now.advanced(by: .milliseconds(100))
    let tracker = NexArmArrivalTracker(
        target: [200, 0, 200, 0, 0, 0], final: false,
        started: now, durationMilliseconds: 3000, actionDeadline: deadline)
    #expect(tracker.outcome(at: deadline) == .completionTimeout)
}

@Test func nexArmDanceBudgetIncludesEverySegmentsObservedSettling() {
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
