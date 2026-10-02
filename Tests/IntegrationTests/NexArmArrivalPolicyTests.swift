import ActionRuntime
import Actions
import AgentCore
import Foundation
import Gateway
import PlatformKit
import Testing
import ToolRuntime
import Tools

@Test func arrivalWinsWithoutStabilityAndStaleSamplesCannotComplete() throws {
    let start = ContinuousClock.now
    let policy = try NexArmMotorCompletion(tolerance: 20)
    var tracker = NexArmSegmentTracker(
        targets: [2: 2100], started: start, deadline: start + .seconds(5), policy: policy)
    var joints = NexArmGesture.referenceHomeJoints
    joints[1] = 2100
    tracker.observe(joints: joints, at: start - .milliseconds(1))
    #expect(tracker.outcome(at: start) == .waiting)
    joints[1] = 2119
    tracker.observe(joints: joints, at: start + .milliseconds(1))
    #expect(tracker.outcome(at: start + .milliseconds(1)) == .arrived)
}

@Test func offTargetRequiresFreshStableSpanAndResetsWhenMotorMoves() throws {
    let start = ContinuousClock.now
    let policy = try NexArmMotorCompletion(tolerance: 16, offTargetMilliseconds: 600)
    var tracker = NexArmSegmentTracker(
        targets: [3: 1500], started: start, deadline: start + .seconds(3), policy: policy)
    var joints = NexArmGesture.referenceHomeJoints
    tracker.observe(joints: joints, at: start)
    tracker.observe(joints: joints, at: start + .milliseconds(200))
    #expect(tracker.outcome(at: start + .milliseconds(1000)) == .waiting)
    joints[2] += 20
    tracker.observe(joints: joints, at: start + .milliseconds(1100))
    tracker.observe(joints: joints, at: start + .milliseconds(1400))
    #expect(tracker.outcome(at: start + .milliseconds(1400)) == .waiting)
    tracker.observe(joints: joints, at: start + .milliseconds(1700))
    #expect(tracker.outcome(at: start + .milliseconds(1700)) == .unreached)
    var moving = NexArmSegmentTracker(targets: [3: 2000], started: start, deadline: start + .seconds(1), policy: policy)
    for n in 0...5 {
        joints[2] = 1200 + n * 50
        moving.observe(joints: joints, at: start + .milliseconds(n * 200))
    }
    #expect(moving.outcome(at: start + .seconds(1)) == .timedOut)
}

@Test func measuredMotorProfilesAndDynamicBudgetsCoverErrorAndParameterChanges() throws {
    #expect(NexArmMotorProfiles.profile(for: 3).tolerance >= 26)
    #expect(NexArmMotorProfiles.profile(for: 4).tolerance >= 22)
    let options = try NexArmMotorOptions(speed: 800, acceleration: 50)
    let baseline = NexArmMotorProfiles.budget(motor: 3, from: 1200, target: 1280, options: options)
    let slower = NexArmMotorProfiles.budget(
        motor: 3, from: 1200, target: 1280, options: try .init(speed: 100, acceleration: 50))
    let gentler = NexArmMotorProfiles.budget(
        motor: 3, from: 1200, target: 1280, options: try .init(speed: 800, acceleration: 1))
    let longer = NexArmMotorProfiles.budget(motor: 3, from: 1200, target: 2000, options: options)
    #expect(slower.timeoutMilliseconds > baseline.timeoutMilliseconds)
    #expect(gentler.timeoutMilliseconds > baseline.timeoutMilliseconds)
    #expect(longer.timeoutMilliseconds > baseline.timeoutMilliseconds)
    #expect(baseline.expectedMilliseconds >= 500)
    let unknown = NexArmMotorProfiles.budget(motor: 3, from: nil, target: 1280, options: options)
    #expect(unknown.timeoutMilliseconds > baseline.timeoutMilliseconds)
}

@Test func compositionBudgetsAddSequenceRepeatAndDelayButMaximizeParallel() throws {
    let one = try ActionExecutionBudget(expected: .seconds(1), timeout: .seconds(2))
    let two = try ActionExecutionBudget(expected: .seconds(2), timeout: .seconds(4))
    let composition = try ActionComposition(
        .sequence([
            .parallel([
                .action("one", [.init(rawValue: "one")], budget: one) { .completed },
                .action("two", [.init(rawValue: "two")], budget: two) { .completed },
            ]),
            .repeated(3, .action("repeated", [], budget: one) { .completed }),
            .delay(.seconds(1)),
        ]))
    let budget = try #require(try composition.executionBudget)
    #expect(budget.expected == .seconds(6))
    #expect(budget.timeout == .milliseconds(11_100))
    let unbounded = try ActionComposition(.action("unknown", []) { .completed })
    #expect(try unbounded.executionBudget == nil)
}

private enum MacroFixture {
    @Action(
        module: "Fixture", title: "Generated action", kind: .finite, completion: "Done",
        resources: { _ in [.init(rawValue: "fixture")] },
        timeout: { _ in try .init(expected: .zero, timeout: .milliseconds(30)) })
    public static func run() {}
    @Tool(path: "Fixture.tool", title: "Generated tool", resources: [.init(rawValue: "fixture")])
    public static func tool() {}
}

@Test func macroFactoriesPreserveTitlesResourcesAndTimeoutReportsThroughCleanup() async throws {
    let tool = MacroFixture.toolDefinition(handler: { _ in "ok" })
    #expect(tool.path == "Fixture.tool" && tool.displayName == "Generated tool")
    #expect(tool.resources == [.init(rawValue: "fixture")])
    let action = MacroFixture.runDefinition(completing: { invocation in
        do { try await Task.sleep(for: .seconds(10)) } catch {
            try await invocation.results.record(
                ActionReport(entries: [
                    .init(path: "first", status: .succeeded),
                    .init(path: "running", status: .cancelled, code: .cancelled),
                ]))
            throw error
        }
        return .completed
    })
    let call = ActionCall(
        actionPath: ActionPath(module: action.path.module, function: action.path.function), channel: "Fixture")
    #expect(action.displayName == "Generated action")
    #expect(try action.requiredResources(for: call) == [.init(rawValue: "fixture")])
    let invocation = ActionInvocation(
        source: .assistant, input: .init(sessionID: UUID(), payload: .event("test")), call: call)
    let result = try await ActionExecutor(registry: ActionRegistry(definitions: [action])).execute(invocation)
    guard case .report(let report) = result else {
        Issue.record("Missing timeout report")
        return
    }
    #expect(report.executionFailure == .timedOut)
    #expect(report.status == .partialFailure)
    #expect(report.entries.count == 2)
    #expect(report.entries.first?.status == .succeeded)
    let parent = try ActionComposition(.action("child", [], maximumResults: 2) { result })
    let flattened = try await parent.run()
    #expect(flattened.entries.count == 3)
    #expect(flattened.entries.last?.code == .timedOut)
}

#if os(macOS)
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEXARM_ARRIVAL_TEST"] == "1"))
    func nexArmUSBPhysicalArrivalProfiles() async throws {
        let link = try NexArmSerial(path: #require(ProcessInfo.processInfo.environment["NEXARM_PORT"]))
        let controller = NexArmActionController(link: link)
        do {
            _ = try await controller.verifyCompatibility()
            _ = try await controller.prepareArmControl()
            let gestures: [NexArmGesture] =
                ProcessInfo.processInfo.environment["NEXARM_COMPLEX_ONLY"] == "1"
                ? [.celebrate, .dance] : [.nod, .shakeHead, .celebrate, .dance]
            for gesture in gestures {
                let start = ContinuousClock.now
                do { try await controller.performGesture(gesture, repetitions: 1) } catch {
                    print("PROFILE GESTURE STOP \(gesture) \(error) \(await controller.motorResults)")
                    throw error
                }
                print(
                    "PROFILE GESTURE \(gesture) duration=\(ContinuousClock.now-start) results=\(await controller.motorResults)"
                )
            }
            await link.close()
        } catch {
            await link.close()
            throw error
        }
    }
#endif

@Test func channelPreservesDeadlineOverStoredReportAndContinuesNextAction() async throws {
    let action = MacroFixture.runDefinition(completing: { invocation in
        if invocation.call.parameters["quick"] == "true" { return .completed }
        do { try await Task.sleep(for: .seconds(10)) } catch {
            try await invocation.results.record(
                ActionReport(entries: [
                    .init(path: "prior", status: .succeeded),
                    .init(path: "interrupted", status: .cancelled, code: .cancelled),
                ]))
            throw error
        }
        return .completed
    })
    let resources = try ResourceCoordinator(definitions: [
        .init(id: .init(rawValue: "fixture"), allowedOwners: [.assistant], stop: {})
    ])
    let scheduler = ChannelScheduler(registry: try ActionRegistry(definitions: [action]), resources: resources)
    let owner = ExecutionOwner(agent: .assistant, incarnation: UUID(), sessionID: UUID())
    let input = AgentInput(sessionID: owner.sessionID, payload: .event("deadline"))
    for quick in [false, true] {
        let call = ActionCall(
            actionPath: ActionPath(module: action.path.module, function: action.path.function), channel: "Fixture",
            parameters: ["quick": String(quick)])
        let envelope = OutputEnvelope(source: .assistant, input: input, output: .actionCall(call))
        try await scheduler.enqueue(invocation: ScheduledAction(envelope: envelope, owner: owner, feedback: .terminal))
    }
    try await scheduler.finish(inputID: input.id)
    await scheduler.finishResultDelivery()
    let results = await scheduler.resultSnapshot().compactMap(\.result)
    #expect(results.count == 2)
    #expect(results.first?.report?.executionFailure == .timedOut)
    #expect(results.first?.report?.entries.count == 2)
    #expect(results.first?.status == .partialFailure)
    #expect(results.last?.status == .succeeded)
}

@Test func compositionLeafDeadlineContinuesWithoutDuplicatingTheTimeout() async throws {
    let deadline = try ActionExecutionBudget(expected: .zero, timeout: .milliseconds(20))
    let composition = try ActionComposition(
        .sequence([
            .action("slow", [], budget: deadline) {
                try await Task.sleep(for: .seconds(10))
                return .completed
            },
            .action("next", []) { .completed },
        ]))
    let report = try await composition.run()
    #expect(report.status == .partialFailure)
    #expect(report.entries.count == 2)
    #expect(report.entries.compactMap(\.code) == [.timedOut])
    #expect(report.entries.last?.status == .succeeded)
}

@Test func nativeAdmissionRejectsRetiredFullEncoderRangeFallback() throws {
    for motor in 1...6 {
        let limits = NexArmMotorCommands.positionLimits[motor - 1]
        for target in [limits.lowerBound, limits.upperBound] {
            let packet = try NexArmMotorCommands.move(motor: motor, target: target, options: .init())
            #expect(packet.isLiveControl && packet.isObservedControl)
        }
        for target in [0, limits.lowerBound - 1, limits.upperBound + 1, 4095] {
            let packet = try NexArmPacket(
                id: UInt8(motor), command: 3,
                payload: [41, 30, UInt8(target & 255), UInt8(target >> 8), 0, 0, 100, 0])
            #expect(!packet.isLiveControl && !packet.isObservedControl)
        }
    }
}
