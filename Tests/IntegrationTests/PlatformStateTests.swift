import AgentCore
import AppStorage
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

@Test @MainActor func platformNativeStateSeedsBeforeReadingAndReconcilesClockEvents() async throws {
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
            #expect(Set(value.keys) == source.stateFields.business.union(source.stateFields.runtime))
            #expect(source.stateFields.business.isDisjoint(with: source.stateFields.runtime))
            #expect(value["uid"] == nil && value["ssid"] == nil && value["deviceName"] == nil)
        }
        #expect(try nativeObject(root.snapshot(.time))["weekday"] as? String == "Sunday")
        time.update { $0.addTimeInterval(1) }
        #expect(try nativeObject(root.snapshot(.time))["weekday"] as? String == "Sunday")
        NotificationCenter.default.post(name: .NSSystemTimeZoneDidChange, object: nil)
        try await waitForNativeState { try nativeObject(root.snapshot(.time))["weekday"] as? String == "Monday" }
        zone.update { $0 = TimeZone(secondsFromGMT: 0) ?? $0 }
        NotificationCenter.default.post(name: .NSSystemTimeZoneDidChange, object: nil)
        try await waitForNativeState {
            try nativeObject(root.snapshot(.time))["localDateTime"] as? String == "2026-10-25T16:00:00Z"
        }
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

@Test @MainActor func assistantPlatformContextReadsResidentStateUpdatedBySubscription() async throws {
    let time = FixtureFactCell(try #require(ISO8601DateFormatter().date(from: "2026-10-25T15:59:59Z")))
    let zone = try #require(TimeZone(secondsFromGMT: 0))
    let root = PlatformContainer(now: { time.read() }, timeZone: { zone })
    try root.start()
    let inspection = ApplicationStateInspection()
    try inspection.registerRoot("platform", readers: { try await root.stateReaders() })
    let context = AgentStateContext()
    try AssistantStateBindings.register(in: context) { path in try await inspection.snapshot(path: path) }
    try context.open(session: "state-session")
    let before = try await context.snapshot(
        session: "state-session", names: ["platform.system.time", "platform.system.network"])
    #expect(before.contains("2026-10-25T15:59:59Z"))
    #expect(!before.contains("observedAt") && !before.contains("runtime") && !before.contains("health"))
    time.update { $0.addTimeInterval(1) }
    NotificationCenter.default.post(name: .NSSystemTimeZoneDidChange, object: nil)
    try await waitForNativeState {
        try nativeObject(root.snapshot(.time))["localDateTime"] as? String == "2026-10-25T16:00:00Z"
    }
    let after = try await context.snapshot(session: "state-session", names: ["platform.system.time"])
    #expect(after.contains("2026-10-25T16:00:00Z") && !after.contains("15:59:59"))
    root.invalidate()
    let unavailable = try await context.snapshot(session: "state-session", names: ["platform.system.time"])
    #expect(unavailable.contains("\"availability\":\"unknown\""))
    try await root.stop()
    context.close()
}

@Test func assistantPlatformContextMarksMalformedUnknownAndRejectsOversizeOrClosedReads() async throws {
    let mode = FixtureFactCell(0)
    let context = AgentStateContext()
    try AssistantStateBindings.register(in: context) { _ in
        if mode.read() == 0 { return [true] }
        return String(repeating: "x", count: 256 * 1024 + 1)
    }
    try context.open(session: "state-session")
    #expect(
        try await context.snapshot(session: "state-session", names: ["platform.system.time"]).contains(
            "stateUnavailable"))
    mode.update { $0 = 1 }
    await #expect(throws: ContainerContextError.capacityExceeded) {
        try await context.snapshot(session: "state-session", names: ["platform.system.network"])
    }
    context.close(session: "state-session")
    await #expect(throws: ContainerContextError.closed) {
        try await context.snapshot(session: "state-session", names: ["platform.system.time"])
    }
}

@Test func basicSkillAlwaysSelectsTheEightPassiveNativeSources() throws {
    let basic = try AgentConfigurations.skill("basic-skill")
    #expect(
        basic.useStates.sorted() == [
            "agents.applicationcontrol", "agents.writer", "platform.system.accessibility", "platform.system.audio",
            "platform.system.locale", "platform.system.network",
            "platform.system.permissions", "platform.system.power", "platform.system.thermal", "platform.system.time",
            "ui.navigation", "ui.windows",
        ])
    #expect(!basic.useStates.contains("platform.location") && !basic.useStates.contains("platform.magneticAttachment"))
}

@MainActor private func waitForNativeState(_ ready: () throws -> Bool) async throws {
    // MainActor notification delivery shares the host with the full integration suite.
    let deadline = ContinuousClock.now.advanced(by: .seconds(15))
    while try !ready() {
        guard ContinuousClock.now < deadline else { throw PlatformStateError.invalidSnapshot }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@Test @MainActor func residentNativeStateSeedsOnceAndReadsNeverSampleSources() async throws {
    let center = NotificationCenter()
    let collection = NativeStateCollection(notificationCenter: center, clockInterval: nil)
    var reads: [PlatformStateSource: Int] = [:]
    var value = 1
    #expect(throws: PlatformError.unavailable) { try collection.snapshot(.power) }
    collection.start { source in
        reads[source, default: 0] += 1
        return try NativeSystemState.encode(["value": value])
    }
    #expect(reads.count == 7 && reads.values.allSatisfy { $0 == 1 })
    value = 2
    for _ in 0..<20 {
        #expect(try nativeObject(collection.snapshot(.power))["value"] as? Int == 1)
    }
    #expect(reads[.power] == 1)
    for _ in 0..<100 {
        center.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
    }
    try await waitForNativeState { reads[.power] == 2 }
    #expect(try nativeObject(collection.snapshot(.power))["value"] as? Int == 2)
    #expect(reads[.thermal] == 1)
    await collection.invalidate()?.value
    #expect(throws: PlatformError.unavailable) { try collection.snapshot(.power) }
}

@Test @MainActor func residentNativeStateFencesQueuedEventsAndReseedsReplacement() async throws {
    let center = NotificationCenter()
    let collection = NativeStateCollection(notificationCenter: center, clockInterval: nil)
    var oldReads = 0
    collection.start { _ in
        oldReads += 1
        return try NativeSystemState.encode(["value": "old"])
    }
    center.post(name: NativeStateCollection.permissionsDidChange, object: nil)
    let retired = collection.invalidate()
    var newReads = 0
    collection.start { _ in
        newReads += 1
        return try NativeSystemState.encode(["value": "new"])
    }
    await retired?.value
    #expect(oldReads == 7 && newReads == 7)
    #expect(try nativeObject(collection.snapshot(.permissions))["value"] as? String == "new")
    center.post(name: NativeStateCollection.permissionsDidChange, object: nil)
    try await waitForNativeState { newReads == 8 }
    #expect(oldReads == 7)
    await collection.invalidate()?.value
}

@Test @MainActor func residentNativeStatePreservesFailuresAndRecoversOnObservation() async throws {
    let center = NotificationCenter()
    let collection = NativeStateCollection(notificationCenter: center, clockInterval: nil)
    var failing = true
    collection.start { source in
        if source == .permissions && failing { throw PlatformStateError.invalidSnapshot }
        return try NativeSystemState.encode(["value": "observed"])
    }
    #expect(throws: PlatformStateError.invalidSnapshot) { try collection.snapshot(.permissions) }
    #expect(try nativeObject(collection.snapshot(.thermal))["value"] as? String == "observed")
    failing = false
    center.post(name: NativeStateCollection.permissionsDidChange, object: nil)
    try await waitForNativeState { (try? collection.snapshot(.permissions)) != nil }
    #expect(try nativeObject(collection.snapshot(.permissions))["value"] as? String == "observed")
    await collection.invalidate()?.value
}

@Test @MainActor func residentNativeStateClockAdvancesWithoutAReadAndStopsWithOwner() async throws {
    let collection = NativeStateCollection(notificationCenter: NotificationCenter())
    var clockSamples = 0
    collection.start { source in
        if source == .time { clockSamples += 1 }
        return try NativeSystemState.encode(["sample": clockSamples])
    }
    try await waitForNativeState { clockSamples >= 2 }
    #expect(try nativeObject(collection.snapshot(.time))["sample"] as? Int == clockSamples)
    await collection.invalidate()?.value
    let stoppedSamples = clockSamples
    try await Task.sleep(for: .milliseconds(1100))
    #expect(clockSamples == stoppedSamples)
}

@Test @MainActor func platformAuthorizationChildrenShareTheSeedAndInvalidateTogether() async throws {
    let root = PlatformContainer()
    #expect(try await root.audio.stateSnapshot().business["microphoneAuthorization"] == .text("unknown"))
    try root.start()
    let permissions = try nativeObject(root.snapshot(.permissions))
    #expect(
        try await root.audio.stateSnapshot().business["microphoneAuthorization"]
            == .text(try #require(permissions["microphone"] as? String)))
    #expect(
        try await root.vision.stateSnapshot().business["camera"]
            == .text(try #require(permissions["camera"] as? String)))
    #expect(
        try await root.connectivity.stateSnapshot().business["bluetoothAuthorization"]
            == .text(try #require(permissions["bluetooth"] as? String)))
    root.invalidate()
    #expect(try await root.audio.stateSnapshot().business["microphoneAuthorization"] == .text("unknown"))
    try await root.setForeground(false)
    try await root.setForeground(true)
    #expect(try nativeObject(root.snapshot(.permissions))["camera"] as? String == permissions["camera"] as? String)
    try await root.stop()
}

@Test @MainActor func residentNativeStateObservationDuringSeedingWinsOverTheBaseline() async throws {
    let center = NotificationCenter()
    let collection = NativeStateCollection(notificationCenter: center, clockInterval: nil)
    var permissionReads = 0
    collection.start { source in
        if source == .permissions {
            permissionReads += 1
            if permissionReads == 1 {
                center.post(name: NativeStateCollection.permissionsDidChange, object: nil)
                return try NativeSystemState.encode(["permission": "baseline"])
            }
            return try NativeSystemState.encode(["permission": "newer"])
        }
        return try NativeSystemState.encode(["value": "observed"])
    }
    try await waitForNativeState { permissionReads == 2 }
    #expect(try nativeObject(collection.snapshot(.permissions))["permission"] as? String == "newer")
    await collection.invalidate()?.value
}

@Test @MainActor func platformPermissionChildReadsPropagateCachedSourceFailure() async throws {
    let root = PlatformContainer()
    try root.start()
    root.audio.readMicrophoneAuthorization = { throw PlatformStateError.invalidSnapshot }
    root.vision.readAuthorization = { throw PlatformStateError.invalidSnapshot }
    root.connectivity.readBluetoothAuthorization = { throw PlatformStateError.invalidSnapshot }
    await #expect(throws: PlatformStateError.invalidSnapshot) { _ = try await root.audio.stateSnapshot() }
    await #expect(throws: PlatformStateError.invalidSnapshot) { _ = try await root.vision.stateSnapshot() }
    await #expect(throws: PlatformStateError.invalidSnapshot) { _ = try await root.connectivity.stateSnapshot() }
    try await root.stop()
}

@Test func platformAudioScopeStateHasStableRawValues() {
    #expect(AudioContainer.Scope.allCases.map(\.rawValue) == ["voice", "diagnostic", "detection", "camera"])
}

@Test func typedSystemStatusPreservesNativeUnknownPowerAndNetworkMeaning() throws {
    let unknownPower = Data(#"{"batteryLevel":null,"batteryState":"unknown","lowPowerMode":false}"#.utf8)
    let knownPower = Data(#"{"batteryLevel":0.85,"batteryState":"charging","lowPowerMode":true}"#.utf8)
    let cases: [(String, [String], PlatformSystemStatus.Network)] = [
        ("unknown", [], .unknown), ("unsatisfied", ["wifi"], .offline),
        ("requiresConnection", ["cellular"], .offline), ("satisfied", ["wifi"], .wifi),
        ("satisfied", ["cellular"], .cellular), ("satisfied", ["wiredEthernet"], .wired),
        ("satisfied", ["other"], .other),
    ]
    for (status, interfaces, expected) in cases {
        let network = try NativeNetworkSnapshot(status: status, interfaces: interfaces).encoded()
        let unknown = try PlatformSystemStatus(power: unknownPower, network: network)
        #expect(unknown.batteryLevel == nil && !unknown.charging && unknown.network == expected)
        let known = try PlatformSystemStatus(power: knownPower, network: network)
        #expect(known.batteryLevel == 0.85 && known.charging && known.lowPower)
    }
    let network = try NativeNetworkSnapshot().encoded()
    #expect(throws: (any Error).self) {
        try PlatformSystemStatus(
            power: Data(#"{"batteryLevel":2,"batteryState":"charging","lowPowerMode":false}"#.utf8), network: network)
    }
}
