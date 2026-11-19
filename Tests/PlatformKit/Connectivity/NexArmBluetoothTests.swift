import Foundation
import Testing

@testable import PlatformKit

@Test func bluetoothReplyRequiresACKAndMatchingReassembledPacket() throws {
    var reply = NexArmBLEReply(id: 255, command: 1, count: 6)
    let packet = try NexArmPacket(command: 1, payload: [1, 0, 2, 1, 0, 2])
    try reply.receive(try NexArmPacket(command: 11, payload: [1, 2]).bytes)
    try reply.receive(Array(packet.bytes.prefix(4)))
    #expect(reply.completed == nil)
    try reply.receive(Array(packet.bytes.dropFirst(4)))
    #expect(reply.completed == nil)
    reply.acknowledged = true
    #expect(reply.completed == packet)
    var wrong = NexArmBLEReply(id: 255, command: 1, count: 6, acknowledged: true)
    try wrong.receive(try NexArmPacket(id: 1, command: 1, payload: packet.payload).bytes)
    #expect(wrong.completed == nil)
    #expect(throws: NexArmError.overflow) { try wrong.receive(Array(repeating: 0, count: 16_385)) }
}

@Test func bluetoothWriteAcknowledgmentDoesNotMasqueradeAsPositionFeedback() throws {
    let outgoing = try NexArmPacket(command: 54, payload: [0xD0, 0x07])
    var reply = NexArmBLEReply(id: 255, command: 54, count: 0, acknowledgmentOnly: true, response: outgoing)
    try reply.receive(try NexArmPacket(command: 11, payload: Array(repeating: 0, count: 24)).bytes)
    #expect(reply.completed == nil)
    reply.acknowledged = true
    #expect(reply.completed == outgoing)  // Private ACK token, not public position data.
}

@Test func bluetoothSharedBudgetBoundsMixedProducerBurstsAndDoesNotCatchUp() {
    let start = ContinuousClock.now
    var budget = NexArmBLETrafficBudget(started: start)
    var accepted: [ContinuousClock.Instant] = []
    // Six competing motor/query producers try every millisecond for one second.
    for tick in 0..<1000 {
        let now = start.advanced(by: .milliseconds(tick))
        for _ in 0..<6 where budget.canSend(at: now, systemReady: true) {
            accepted.append(now)
            budget.sent(bytes: 14, at: now)
        }
    }
    #expect(accepted.count == 34)
    #expect(zip(accepted, accepted.dropFirst()).allSatisfy { $1 - $0 >= .milliseconds(30) })
    let afterStall = start.advanced(by: .seconds(10))
    let resumedAdmission = budget.canSend(at: afterStall, systemReady: true)
    #expect(resumedAdmission)
    budget.sent(bytes: 14, at: afterStall)
    let burstAdmission = budget.canSend(at: afterStall, systemReady: true)
    #expect(!burstAdmission)
    #expect(budget.statistics.sentBytes == 35 * 14)
}

@Test func bluetoothSystemBackpressurePreservesBudgetForTheNextAcceptedWrite() {
    let now = ContinuousClock.now
    var budget = NexArmBLETrafficBudget(started: now)
    for _ in 0..<100 {
        let admission = budget.canSend(at: now, systemReady: false)
        #expect(!admission)
    }
    #expect(budget.nextWrite == nil)
    #expect(budget.statistics.sentPackets == 0)
    budget.resumed()
    let firstAdmission = budget.canSend(at: now, systemReady: true)
    #expect(firstAdmission)
    budget.sent(bytes: 14, at: now)
    #expect(budget.statistics.systemDeferrals == 100)
    #expect(budget.statistics.flowControlResumptions == 1)
    let earlyAdmission = budget.canSend(at: now.advanced(by: .milliseconds(29)), systemReady: true)
    let nextAdmission = budget.canSend(at: now.advanced(by: .milliseconds(30)), systemReady: true)
    #expect(!earlyAdmission && nextAdmission)
}

@Test func bluetoothDiagnosticsDistinguishNotificationTrafficFromValidFeedback() {
    let start = ContinuousClock.now
    var budget = NexArmBLETrafficBudget(started: start)
    budget.received(bytes: 30, feedbackSamples: 1, at: start)
    // Incoming fragments/unrelated packets must not count as a fresh position sample.
    budget.received(bytes: 6, feedbackSamples: 0, at: start.advanced(by: .milliseconds(1900)))
    let stalled = budget.diagnostics(at: start.advanced(by: .seconds(2)))
    #expect(stalled.notificationBytes == 36 && stalled.feedbackSamples == 1)
    #expect(stalled.notificationGapMilliseconds == 100)
    #expect(stalled.feedbackGapMilliseconds == 2000)
    budget.received(bytes: 60, feedbackSamples: 2, at: start.advanced(by: .milliseconds(2100)))
    let recovered = budget.diagnostics(at: start.advanced(by: .milliseconds(2100)))
    #expect(recovered.feedbackSamples == 3 && recovered.feedbackGapMilliseconds == 0)
    #expect(recovered.longestFeedbackGapMilliseconds == 2100)
    #expect(NexArmBLETrafficBudget(started: start).statistics.sentPackets == 0)
}

@Test func bluetoothNativeBlockingResetsWithoutBusinessTimeouts() {
    let now = ContinuousClock.now
    var budget = NexArmBLETrafficBudget(started: now)
    let blocked = budget.canSend(at: now, systemReady: false)
    #expect(!blocked)
    #expect(!budget.isSendBlocked(at: now.advanced(by: .milliseconds(1999))))
    #expect(budget.isSendBlocked(at: now.advanced(by: .seconds(2))))
    budget.cancelBlockedWrite()
    #expect(!budget.isSendBlocked(at: now.advanced(by: .seconds(3))))
    let blockedAgain = budget.canSend(at: now.advanced(by: .seconds(4)), systemReady: false)
    #expect(!blockedAgain)
    budget.resumed()
    #expect(!budget.isSendBlocked(at: now.advanced(by: .seconds(8))))
}

@Test func bluetoothWriteCapabilitySelectionAndAcknowledgmentWindowAreBounded() throws {
    #expect(
        try NexArmBLEWriteMode.select(withResponse: true, withoutResponse: false, preferred: .unacknowledged)
            == .acknowledged)
    #expect(
        try NexArmBLEWriteMode.select(withResponse: false, withoutResponse: true, preferred: .acknowledged)
            == .unacknowledged)
    #expect(
        try NexArmBLEWriteMode.select(withResponse: true, withoutResponse: true, preferred: .unacknowledged)
            == .unacknowledged)
    #expect(
        try NexArmBLEWriteMode.select(withResponse: true, withoutResponse: true, preferred: .acknowledged)
            == .acknowledged)
    #expect(throws: NexArmBluetoothError.incompatibleService) {
        try NexArmBLEWriteMode.select(withResponse: false, withoutResponse: false, preferred: .unacknowledged)
    }
    var window = NexArmBLEControlWriteWindow()
    let initialReservation = window.reserve()
    let first = try #require(initialReservation)
    let blockedReservation = window.reserve()
    #expect(blockedReservation == nil)
    #expect(window.token == first)
    window.complete()
    let nextReservation = window.reserve()
    #expect(try #require(nextReservation) != first)
}
