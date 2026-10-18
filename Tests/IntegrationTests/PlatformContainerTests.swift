import AppLifecycle
import AppStorage
import Foundation
import Gateway
import PlatformKit
import Testing

@testable import UI

@Test @MainActor func platformRegistrationIsRootLocal() async throws {
    let registry = ApplicationContainer(root: URL.temporaryDirectory)
    let root = registry.platform()
    #expect(root === registry.platform())
    #expect(root.audio === registry.audio())
    #expect(root.vision === registry.vision())
    #expect(root.connectivity === registry.connectivity())
    #expect(root !== ApplicationContainer(root: URL.temporaryDirectory).platform())
    #expect(!root.isAvailable)
    #expect(await root.connectivity.bluetooth.status().phase == .disconnected)
    try await root.stop()
}

@Test @MainActor func platformSuspensionAndStopFenceTheRoot() async throws {
    let root = PlatformContainer()
    try root.start()
    #expect(root.isAvailable)
    root.invalidate()
    #expect(!root.isAvailable)
    try root.start()
    #expect(!root.isAvailable)
    try await root.setForeground(false)
    try await root.setForeground(true)
    #expect(root.isAvailable)
    try await root.stop()
    try await root.stop()
    #expect(!root.isAvailable)
    #expect(throws: PlatformError.self) { try root.start() }
    await #expect(throws: PlatformError.self) { try await root.setForeground(true) }
}

private actor UnconfirmedPlatformLink: NexArmBluetoothLink {
    nonisolated let updates = AsyncStream<NexArmBluetoothSnapshot> { $0.finish() }
    private(set) var disconnects = 0
    func status() -> NexArmBluetoothSnapshot {
        var result = NexArmBluetoothSnapshot()
        result.failure = .disconnectUnconfirmed
        result.phase = .connected
        return result
    }
    func disconnect() { disconnects += 1 }
    func close() { disconnects += 1 }
    func scan() throws { throw NexArmError.disconnected }
    func stopScan() {}
    func clearDiscovery() {}
    func forgetDevice() {}
    func connect(_ id: String) throws { throw NexArmError.disconnected }
    func beginLiveControl() throws -> String { throw NexArmError.disconnected }
    func sendLive(_ packet: NexArmPacket, session: String) throws -> Bool { throw NexArmError.disconnected }
    func endLiveControl(_ session: String) {}
    func beginObservation() throws -> String { throw NexArmError.disconnected }
    func endObservation(_ session: String) {}
    func sendObserved(_ packet: NexArmPacket, session: String) throws -> Bool { throw NexArmError.disconnected }
    func latestObservation(after sequence: UInt64, session: String) throws -> NexArmTelemetry? {
        throw NexArmError.disconnected
    }
    func write(_ packet: NexArmPacket) throws { throw NexArmError.disconnected }
    func exchange(_ packet: NexArmPacket, replyID: UInt8, replyCommand: UInt8, replyCount: Int) throws -> NexArmPacket {
        throw NexArmError.disconnected
    }
}

@Test @MainActor func platformRetainsCleanupFailureAndDoesNotReopenOrRepeatDisconnect() async throws {
    let link = UnconfirmedPlatformLink()
    let channel = ContainerFailureChannel()
    let root = PlatformContainer(
        makeConnectivity: { ConnectivityContainer(admission: $0, bluetooth: link) },
        onFailure: channel.sink(module: "platform"))
    try root.start()
    root.invalidate()
    await #expect(throws: PlatformCleanupFailure.self) { try await root.setForeground(false) }
    await #expect(throws: PlatformCleanupFailure.self) { try await root.setForeground(true) }
    await #expect(throws: PlatformCleanupFailure.self) { try await root.stop() }
    await #expect(throws: PlatformCleanupFailure.self) { try await root.stop() }
    #expect(!root.isAvailable)
    #expect(await link.disconnects == 1)
    #expect(
        channel.snapshot().records.contains { $0.event.component == "connectivity" && $0.event.module == "platform" })
    await channel.stop()
}

@Test @MainActor func uiRegistrationSharesCameraWithItsRootAndIsolatesScopes() async throws {
    let registry = ApplicationContainer(root: URL.temporaryDirectory)
    let root = registry.ui()
    #expect(root === registry.ui())
    #expect(root.camera === registry.cameraPresentation())
    #expect(root.camera.state === registry.cameraPresentation().state)
    let next = ApplicationContainer(root: URL.temporaryDirectory).ui()
    #expect(root !== next)
    #expect(root.camera.state !== next.camera.state)
    #expect(!root.isAvailable)
    #expect(!root.camera.snapshot.isEnabled)
    try root.start()
    #expect(root.isAvailable)
    #expect(!next.isAvailable)
    await root.stop()
    await next.stop()
}

@MainActor private final class UIServiceTrace {
    var events: [String] = []
}

@Test @MainActor func uiLifecycleOrdersConsumersBeforeRootCleanup() async throws {
    let root = UI.UIContainer()
    let trace = UIServiceTrace()
    let lifecycle = try AppLifecycle.ApplicationLifecycle(services: [
        AppLifecycle.ManagedService(
            id: "consumer", dependencies: ["ui"],
            start: {
                #expect(root.isAvailable)
                trace.events.append("consumer.start")
            }, stop: { trace.events.append("consumer.stop") }),
        AppLifecycle.ManagedService(
            id: "ui",
            start: {
                try root.start()
                trace.events.append("ui.start")
            }, invalidate: root.invalidate, foreground: { try root.setForeground($0) },
            stop: {
                await root.stop()
                trace.events.append("ui.stop")
            }),
    ])
    try await lifecycle.start()
    try await lifecycle.waitForForeground()
    lifecycle.setForeground(false)
    #expect(!root.isAvailable)
    try await lifecycle.waitForForeground()
    lifecycle.setForeground(true)
    try await lifecycle.waitForForeground()
    #expect(root.isAvailable)
    try await lifecycle.stop()
    #expect(trace.events == ["ui.start", "consumer.start", "consumer.stop", "ui.stop"])
    #expect(!root.isAvailable)
    #expect(throws: UI.UIContainerError.stopped) { try root.start() }
}

private enum UIConsumerFailure: Error, Equatable { case start }
@Test @MainActor func uiLifecycleRollsBackAfterConsumerStartupFailure() async throws {
    let root = UI.UIContainer()
    let lifecycle = try AppLifecycle.ApplicationLifecycle(services: [
        AppLifecycle.ManagedService(
            id: "ui", start: { try root.start() }, invalidate: root.invalidate, stop: { await root.stop() }),
        AppLifecycle.ManagedService(
            id: "consumer", dependencies: ["ui"], start: { throw UIConsumerFailure.start }, stop: {}),
    ])
    do {
        try await lifecycle.start()
        Issue.record("Consumer startup must fail")
    } catch let failure as AppLifecycle.ApplicationLifecycleFailure {
        #expect(failure.primary as? UIConsumerFailure == .start)
        #expect(failure.cleanup.isEmpty)
    }
    #expect(!root.isAvailable)
    #expect(throws: UI.UIContainerError.stopped) { try root.start() }
}
