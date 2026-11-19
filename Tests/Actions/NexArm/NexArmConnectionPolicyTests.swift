import Actions
import Foundation
import PlatformKit
import Testing

@Test func bluetoothFailureIdentifiesNativeStep() {
    #expect(BluetoothPresentation.failure(.timeout(.connecting)) == "Bluetooth connection timed out")
    #expect(BluetoothPresentation.failure(.timeout(.notifications)) == "Enabling notifications timed out")
    #expect(BluetoothPresentation.failure(.timeout(.response)) == "Waiting for device response timed out")
    let native = NexArmBluetoothFailure(step: .writing, error: NSError(domain: "fixture.transport", code: 42))
    #expect(native == .native(step: .writing, domain: "fixture.transport", code: 42))
    #expect(BluetoothPresentation.failure(native) == "Sending device command failed (fixture.transport 42)")
    #expect(
        BluetoothPresentation.failure(.incompatibleService(.services))
            == "Service discovery failed: incompatible Bluetooth service")
    #expect(
        BluetoothPresentation.failure(.disconnectUnconfirmed)
            == "Bluetooth disconnection unconfirmed. Turn Bluetooth off, then retry.")
}

@Test func bluetoothDiscoveryPrioritizesNamesButKeepsRenamedAndOtherDevices() {
    let renamed = NexArmBluetoothDevice(id: UUID().uuidString, name: "桌上的手臂", rssi: -20)
    let other = NexArmBluetoothDevice(id: UUID().uuidString, name: "温度计", rssi: -30)
    let arm = NexArmBluetoothDevice(id: UUID().uuidString, name: "Nex_Arm", rssi: -80)
    let unnamed = NexArmBluetoothDevice(id: UUID().uuidString, name: "未命名设备", rssi: -60)
    let rows = [renamed, other, arm, unnamed].sorted(by: BluetoothPresentation.discoveryOrder)
    #expect(rows.map(\.id) == [arm.id, renamed.id, other.id, unnamed.id])
}

@Test func bluetoothJogPlannerUsesSpeedCurveAndVendorJointLimits() throws {
    for id in 1...6 {
        var planner = try NexArmJogPlanner(positions: NexArmGesture.referenceHomeJoints)
        #expect(try planner.proposal(id: id, deflection: 0) == nil)
        for _ in 0..<200 {
            if let proposal = try planner.proposal(id: id, deflection: 1) {
                planner.accept(proposal)
            }
        }
        #expect(Int(planner.targets[id - 1]) == NexArmJogPlanner.limits[id - 1].upperBound)
        #expect(planner.targets[id - 1] - Double(NexArmGesture.referenceHomeJoints[id - 1]) > 91)
    }
}

@Test func bluetoothDiscoverySeparatesDeviceNamesFromPresentationPolicy() {
    #expect(BluetoothPresentation.deviceName("未命名设备") == nil)
    #expect(NexArmBluetoothDevice.discoveryName(advertised: nil, cached: nil) == nil)
    #expect(NexArmBluetoothDevice.discoveryName(advertised: "  \n", cached: "未命名设备") == "未命名设备")
    #expect(NexArmBluetoothDevice.discoveryName(advertised: "", cached: " NexArm ") == "NexArm")
    #expect(NexArmBluetoothDevice.discoveryName(advertised: "桌上的机械臂", cached: "旧名字") == "桌上的机械臂")
}

@Test func aimFollowApproachesTheLatestCountWithoutJumpingThere() throws {
    var planner = try NexArmJogPlanner(positions: NexArmGesture.referenceHomeJoints)
    let start = Int(planner.targets[0])
    let goal = start - 80
    var last = start
    var moved = false
    for _ in 0..<100 {
        guard let proposal = try planner.approach(id: 1, target: goal) else { break }
        if let packet = proposal.packet {
            #expect(packet.isLiveControl)
            #expect(packet.id == 1)
            let position = Int(packet.payload[2]) | Int(packet.payload[3]) << 8
            #expect(abs(position - last) <= 40)
            last = position
            moved = true
        }
        planner.accept(proposal)
        #expect(abs(planner.accelerations[0]) <= NexArmJogPlanner.maximumAcceleration)
    }
    #expect(moved)
    #expect(abs(Int(planner.targets[0]) - goal) <= 2)
    #expect(try planner.approach(id: 1, target: goal) == nil)
    #expect(throws: NexArmExecutionError.invalidArguments) { try planner.approach(id: 6, target: goal) }
}

@Test func aimFollowBrakesBeforeReversing() throws {
    var planner = try NexArmJogPlanner(positions: NexArmGesture.referenceHomeJoints)
    let start = Int(planner.targets[3])
    for _ in 0..<25 {
        if let proposal = try planner.approach(id: 4, target: start + 200) {
            planner.accept(proposal)
        }
    }
    #expect(planner.velocities[3] > 8)
    let lead = planner.targets[3]
    let brake = try #require(try planner.approach(id: 4, target: start))
    if let packet = brake.packet {
        let position = Int(packet.payload[2]) | Int(packet.payload[3]) << 8
        #expect(position <= Int(lead))
        #expect(packet.id == 4)
    }
    planner.accept(brake)
    #expect(planner.velocities[3] == 0)
    #expect(planner.targets[3] <= lead)
}

@Test(arguments: 1...5, [-2, -1, 1, 2])
func aimFinalCountRemainsPendingUntilNativeAdmission(motor: Int, delta: Int) throws {
    let initial = NexArmGesture.referenceHomeJoints
    var planner = try NexArmJogPlanner(positions: initial)
    let target = initial[motor - 1] + delta
    let proposal = try #require(try planner.approach(id: motor, target: target))
    let packet = try #require(proposal.packet)
    #expect(packet.motorTargets == [motor: target])
    // A deferred native write must leave the final intent pending, not claim it was accepted.
    #expect(planner.targets[motor - 1] == Double(initial[motor - 1]))
    let deferred = try #require(try planner.approach(id: motor, target: target))
    #expect(deferred.packet == packet)
    planner.accept(proposal)
    #expect(planner.targets[motor - 1] == Double(target))
    #expect(try planner.approach(id: motor, target: target) == nil)
    for index in 0..<6 where index != motor - 1 {
        #expect(planner.targets[index] == Double(initial[index]))
    }
}

@Test func aimReachMotorsStayBelowTheirSlowerSpeedLimit() throws {
    var planner = try NexArmJogPlanner(positions: NexArmGesture.referenceHomeJoints)
    let start = Int(planner.targets[1])
    for _ in 0..<80 {
        guard
            let proposal = try planner.approach(
                id: 2, target: start - 300, speedLimit: NexArmJogPlanner.aimReachSpeed)
        else { break }
        planner.accept(proposal)
        #expect(abs(planner.velocities[1]) <= NexArmJogPlanner.aimReachSpeed)
    }
    #expect(planner.targets[1] < Double(start - 20))
    #expect(throws: NexArmExecutionError.invalidArguments) {
        try planner.approach(id: 2, target: start - 300, speedLimit: NexArmJogPlanner.maximumSpeed + 1)
    }
}

@Test func bluetoothJogShapesVelocityAndRejectsConfigurationWrites() throws {
    var planner = try NexArmJogPlanner(positions: NexArmGesture.referenceHomeJoints)
    var previousAcceleration = 0.0
    var duplicates = 0
    for input in Array(repeating: 0.3, count: 35) + Array(repeating: -0.3, count: 35) {
        let proposal = try #require(try planner.proposal(id: 1, deflection: input))
        if let packet = proposal.packet { #expect(packet.isLiveControl) } else { duplicates += 1 }
        planner.accept(proposal)
        #expect(abs(planner.accelerations[0]) <= NexArmJogPlanner.maximumAcceleration)
        #expect(abs(planner.accelerations[0] - previousAcceleration) <= NexArmJogPlanner.maximumJerk * 0.03 + 0.001)
        previousAcceleration = planner.accelerations[0]
    }
    #expect(duplicates > 0)
    #expect(planner.velocities[0] < -35)
    let stopped = planner.targets
    planner.stop(id: 1)
    #expect(planner.targets == stopped && planner.velocities[0] == 0)
    #expect(try !NexArmPacket(id: 1, command: 3, payload: [40, 0]).isLiveControl)
    #expect(try !NexArmPacket(id: 2, command: 3, payload: [40, 0]).isLiveControl)
    #expect(try !NexArmPacket(id: 1, command: 3, payload: [33, 2]).isLiveControl)
    #expect(try !NexArmPacket(command: 51, payload: [1, 0, 8, 20, 0]).isLiveControl)
}

@Test func bluetoothJogStickExtentControlsCruiseSpeedAndStallsDoNotCatchUp() throws {
    var slow = try NexArmJogPlanner(positions: NexArmGesture.referenceHomeJoints)
    var fast = slow
    for _ in 0..<40 {
        slow.accept(try #require(try slow.proposal(id: 1, deflection: 0.5)))
        fast.accept(try #require(try fast.proposal(id: 1, deflection: 1)))
    }
    #expect(slow.velocities[0] > 100 && slow.velocities[0] < 160)
    #expect(fast.velocities[0] > 590)
    #expect(fast.targets[0] > slow.targets[0] + 200)
    let stalled = try #require(try fast.proposal(id: 1, deflection: 1, elapsed: 2))
    #expect(stalled.target - fast.targets[0] <= 37)
}

@Test func bluetoothResponseTimeoutRetainsQueryAndSeparatesNotificationBytesFromPayload() {
    let missing = NexArmBluetoothFailure.responseTimeout(command: 11, expectedBytes: 24, receivedBytes: 0)
    #expect(
        BluetoothPresentation.failure(missing)
            == "Arm position query timed out (0x0B, expected 24 payload bytes, received 0 notification bytes)")
    let unmatched = NexArmBluetoothFailure.responseTimeout(command: 7, expectedBytes: 24, receivedBytes: 30)
    #expect(
        BluetoothPresentation.failure(unmatched)
            == "Device query timed out (0x07, expected 24 payload bytes, received 30 notification bytes)")
}

@Test func bluetoothProtocolFailuresAreNotNativeSystemErrorsOrExecutionTimeouts() {
    let invalid = NexArmBluetoothFailure(step: .response, error: NexArmError.invalidPacket)
    let overflow = NexArmBluetoothFailure(step: .response, error: NexArmError.overflow)
    #expect(invalid == .protocolViolation(.invalidPacket))
    #expect(overflow == .protocolViolation(.receiveOverflow))
    #expect(BluetoothPresentation.failure(invalid) == "Invalid Bluetooth response packet")
    #expect(BluetoothPresentation.failure(overflow) == "Bluetooth receive buffer overflow")
    #expect(NexArmBluetoothFailure(step: .response, error: NexArmError.timeout) == .timeout(.response))
}

@Test func bluetoothRecoveryRequiresKnownNativeEvidenceAndIgnoresBusinessErrors() {
    struct UnknownFailure: Error {}
    var snapshot = NexArmBluetoothSnapshot()
    snapshot.power = .poweredOn
    #expect(!BluetoothRecoveryPolicy.canRetry(UnknownFailure(), snapshot: snapshot))
    #expect(!BluetoothRecoveryPolicy.canRetry(NexArmExecutionError.feedbackTimeout, snapshot: snapshot))
    #expect(!BluetoothRecoveryPolicy.canRetry(NexArmError.busy, snapshot: snapshot))
    #expect(!BluetoothRecoveryPolicy.canRetry(NexArmError.sessionReplaced, snapshot: snapshot))
    #expect(BluetoothRecoveryPolicy.canRetry(NexArmError.timeout, snapshot: snapshot))
    #expect(!BluetoothRecoveryPolicy.canRetry(NexArmError.invalidPacket, snapshot: snapshot))
    snapshot.failure = .protocolViolation(.invalidPacket)
    #expect(BluetoothRecoveryPolicy.canRetry(NexArmError.invalidPacket, snapshot: snapshot))
    let system = NSError(domain: "NativeFixture", code: 17)
    #expect(!BluetoothRecoveryPolicy.canRetry(system, snapshot: snapshot))
    snapshot.failure = .native(step: .writing, domain: "NativeFixture", code: 17)
    #expect(BluetoothRecoveryPolicy.canRetry(system, snapshot: snapshot))
    #expect(!BluetoothRecoveryPolicy.canRetry(NSError(domain: "NativeFixture", code: 18), snapshot: snapshot))
    snapshot.power = .unauthorized
    #expect(!BluetoothRecoveryPolicy.canRetry(NexArmBluetoothError.unavailable, snapshot: snapshot))
}

@Test func bluetoothInterruptedQueryUsesOnlyTheCurrentNativeReason() {
    var snapshot = NexArmBluetoothSnapshot()
    snapshot.failure = .requestInterrupted(command: 7)
    let message = BluetoothPresentation.currentIssue(snapshot)
    #expect(message?.contains("0x07") == true)
    #expect(message?.contains("Action") == false)
    snapshot.failure = nil
    snapshot.feedbackHealthy = true
    #expect(BluetoothPresentation.currentIssue(snapshot) == nil)
}
