import AgentCore
import Foundation
import ModelKit
import Testing

@testable import Agents
@testable import PlatformKit

private func nativeObject(_ data: Data) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

@Test func nativeLocalTimeUsesOneInstantZoneAndGregorianWeekday() throws {
    let date = try #require(ISO8601DateFormatter().date(from: "2026-10-25T15:59:59Z"))
    let shanghai = try #require(TimeZone(identifier: "Asia/Shanghai"))
    let before = try nativeObject(NativeSystemState.localTime(at: date, zone: shanghai))
    let after = try nativeObject(NativeSystemState.localTime(at: date.addingTimeInterval(1), zone: shanghai))
    #expect(before["localDateTime"] as? String == "2026-10-25T23:59:59+08:00")
    #expect(before["weekday"] as? String == "Sunday")
    #expect(after["localDateTime"] as? String == "2026-10-26T00:00:00+08:00")
    #expect(after["weekday"] as? String == "Monday")
    #expect(after["timeZone"] as? String == "Asia/Shanghai")
    let utc = try #require(TimeZone(secondsFromGMT: 0))
    let otherZone = try nativeObject(NativeSystemState.localTime(at: date, zone: utc))
    #expect(otherZone["localDateTime"] as? String == "2026-10-25T15:59:59Z")
}

@Test func nativeLocalTimePreservesLeapDayAndRepeatedDSTHourOffsets() throws {
    let utc = try #require(TimeZone(secondsFromGMT: 0))
    let leap = try #require(ISO8601DateFormatter().date(from: "2024-02-29T01:02:03Z"))
    let leapData = try nativeObject(NativeSystemState.localTime(at: leap, zone: utc))
    #expect(leapData["localDateTime"] as? String == "2024-02-29T01:02:03Z")
    #expect(leapData["weekday"] as? String == "Thursday")
    let zone = try #require(TimeZone(identifier: "America/New_York"))
    let first = try #require(ISO8601DateFormatter().date(from: "2024-11-03T05:30:00Z"))
    let second = first.addingTimeInterval(3600)
    #expect(
        try nativeObject(NativeSystemState.localTime(at: first, zone: zone))["localDateTime"] as? String
            == "2024-11-03T01:30:00-04:00")
    #expect(
        try nativeObject(NativeSystemState.localTime(at: second, zone: zone))["localDateTime"] as? String
            == "2024-11-03T01:30:00-05:00")
    #expect(throws: PlatformStateError.invalidTime) {
        try NativeSystemState.localTime(at: Date(timeIntervalSince1970: .infinity), zone: utc)
    }
}

@Test func nativeNetworkFactsAreLatestOnlyAndFenceRetiredCallbacks() throws {
    let observation = NativeNetworkObservation()
    #expect(observation.snapshot().status == "unknown")
    let first = observation.begin()
    observation.accept(
        NativeNetworkSnapshot(status: "satisfied", interfaces: ["wifi"], expensive: false, constrained: true),
        generation: first)
    observation.accept(
        NativeNetworkSnapshot(status: "unsatisfied", expensive: false, constrained: false), generation: first)
    #expect(observation.snapshot().status == "unsatisfied")
    observation.end()
    observation.accept(NativeNetworkSnapshot(status: "satisfied"), generation: first)
    #expect(observation.snapshot().status == "unknown")
    let second = observation.begin()
    observation.accept(NativeNetworkSnapshot(status: "satisfied"), generation: first)
    #expect(observation.snapshot().status == "unknown")
    observation.accept(
        NativeNetworkSnapshot(status: "requiresConnection", expensive: true, constrained: true), generation: second)
    let value = try nativeObject(observation.snapshot().encoded())
    #expect(value["status"] as? String == "requiresConnection")
    #expect(value["expensive"] as? Bool == true && value["constrained"] as? Bool == true)
    #expect(value["observedAt"] is NSNull)
}

@Test func nativeAudioInterruptionKeepsUnknownAndRejectsOldSessionEvents() {
    let observation = NativeAudioInterruption()
    #expect(observation.snapshot() == nil)
    let first = observation.begin()
    observation.accept(true, generation: first)
    #expect(observation.snapshot() == true)
    observation.accept(false, generation: first)
    #expect(observation.snapshot() == false)
    observation.accept(nil, generation: first)
    #expect(observation.snapshot() == nil)
    observation.end()
    let second = observation.begin()
    observation.accept(true, generation: first)
    #expect(observation.snapshot() == nil)
    observation.accept(true, generation: second)
    #expect(observation.snapshot() == true)
}

@Test @MainActor func platformNativeStateRequiresLiveRootAndRereadsInjectedClock() async throws {
    let time = FixtureFactCell(try #require(ISO8601DateFormatter().date(from: "2026-10-25T15:59:59Z")))
    let zone = FixtureFactCell(try #require(TimeZone(identifier: "Asia/Shanghai")))
    let root = PlatformContainer(now: { time.read() }, timeZone: { zone.read() })
    #expect(throws: PlatformError.unavailable) { try root.snapshot(.time) }
    try root.start()
    do {
        for source in PlatformStateSource.allCases {
            let data = try root.snapshot(source)
            #expect(data.count < 2048)
            let value = try nativeObject(data)
            #expect(!value.isEmpty)
            #expect(value["uid"] == nil && value["ssid"] == nil && value["deviceName"] == nil)
        }
        #expect(try nativeObject(root.snapshot(.time))["weekday"] as? String == "Sunday")
        time.update { $0.addTimeInterval(1) }
        #expect(try nativeObject(root.snapshot(.time))["weekday"] as? String == "Monday")
        zone.update { $0 = TimeZone(secondsFromGMT: 0) ?? $0 }
        #expect(try nativeObject(root.snapshot(.time))["localDateTime"] as? String == "2026-10-25T16:00:00Z")
        root.invalidate()
        #expect(throws: PlatformError.unavailable) { try root.snapshot(.permissions) }
        try await root.setForeground(false)
        try await root.setForeground(true)
        #expect(try !nativeObject(root.snapshot(.permissions)).isEmpty)
        try await root.stop()
        try await root.stop()
        #expect(throws: PlatformError.unavailable) { try root.snapshot(.time) }
    } catch {
        try await root.stop()
        throw error
    }
}

@MainActor private struct ChangingPlatformState: PlatformStateReading {
    let data: FixtureFactCell<Data>
    nonisolated init(_ data: FixtureFactCell<Data>) { self.data = data }
    func snapshot(_ source: PlatformStateSource) throws -> Data { data.read() }
}

@Test @MainActor func agentPlatformContextWrapsObjectsAndRefreshesWithoutCaching() async throws {
    let value = FixtureFactCell(Data(#"{"permission":"denied","second":1}"#.utf8))
    let context = AgentStateContext()
    try AgentPlatformState.register(in: context, reading: ChangingPlatformState(value))
    try context.open(session: "state-session")
    let before = try nativeObject(
        Data(try await context.snapshot(session: "state-session", names: ["platform.time"]).utf8))
    let envelope = try #require(before["platform.time"] as? [String: Any])
    #expect(envelope["availability"] as? String == "available")
    #expect((envelope["value"] as? [String: Any])?["second"] as? Int == 1)
    #expect((envelope["value"] as? [String: Any])?["permission"] as? String == "denied")
    value.update { $0 = Data(#"{"second":2}"#.utf8) }
    let after = try await context.snapshot(session: "state-session", names: ["platform.time"])
    #expect(after.contains("\"second\":2") && !after.contains("\"second\":1"))
    context.close()
}

@Test @MainActor func agentPlatformContextRejectsInvalidOversizedAndRetiredReads() async throws {
    let value = FixtureFactCell(Data("[]".utf8))
    let context = AgentStateContext()
    try AgentPlatformState.register(in: context, reading: ChangingPlatformState(value))
    try context.open(session: "state-session")
    await #expect(throws: ContainerContextError.invalidSnapshot) {
        try await context.snapshot(session: "state-session", names: ["platform.time"])
    }
    value.update { $0 = Data(repeating: 32, count: 8193) }
    await #expect(throws: ContainerContextError.capacityExceeded) {
        try await context.snapshot(session: "state-session", names: ["platform.network"])
    }
    context.close(session: "state-session")
    await #expect(throws: ContainerContextError.closed) {
        try await context.snapshot(session: "state-session", names: ["platform.time"])
    }
}

@Test func basicSkillAlwaysSelectsTheEightPassiveNativeSources() throws {
    let basic = try AgentConfigurations.skill("basic-skill")
    #expect(
        basic.useStates.sorted() == [
            "agents.application", "platform.accessibility", "platform.audio", "platform.locale", "platform.network",
            "platform.permissions", "platform.power", "platform.thermal", "platform.time", "ui.navigation",
        ])
    #expect(!basic.useStates.contains("platform.location") && !basic.useStates.contains("platform.magneticAttachment"))
}
