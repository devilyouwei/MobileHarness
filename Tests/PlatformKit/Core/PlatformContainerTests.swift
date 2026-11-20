import Agents
import AppLifecycle
import AppStorage
import Foundation
import Gateway
import ModelKitDefaults
import PlatformKit
import Testing

@testable import PlatformKit
@testable import UI

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
    #expect(throws: PlatformFailure.self) { try root.start() }
    await #expect(throws: PlatformFailure.self) { try await root.setForeground(true) }
}

@Test @MainActor func platformMemoryWarningsAreRootLifetimeSignalsThatCoalesce() async throws {
    let center = NotificationCenter()
    let name = Notification.Name("test.memoryWarning")
    let root = PlatformContainer(
        makeConnectivity: { ConnectivityContainer(admission: $0) }, now: { Date() }, timeZone: { .current },
        memoryWarnings: NativeMemoryWarnings(center: center, name: name), onFailure: { _, _, _ in })
    #expect(throws: PlatformError.self) { try root.listenMemoryWarnings() }
    try root.start()
    let listener = try root.listenMemoryWarnings()
    #expect(listener.source.producer == "platform.system.memory")
    root.invalidate()
    center.post(name: name, object: nil)
    center.post(name: name, object: nil)
    var iterator = listener.makeAsyncIterator()
    #expect(try await iterator.next() != nil)
    try await root.stop()
    #expect(try await iterator.next() == nil)
    #expect(throws: PlatformError.self) { try root.listenMemoryWarnings() }
    center.post(name: name, object: nil)
}

private actor UnconfirmedPlatformLink: NexArmBluetoothLink {
    nonisolated func listenUpdates() throws -> PlatformKit.StateSignalListener<NexArmBluetoothSnapshot> {
        let broadcast = NativeInputBroadcast<NexArmBluetoothSnapshot>()
        let listener = try broadcast.listen(.latest, producer: "fixture.bluetooth")
        broadcast.finish()
        return listener
    }
    private(set) var disconnects = 0
    private var holdClose: Bool
    private let unconfirmed: Bool
    private var closeWaiter: CheckedContinuation<Void, Never>?
    init(holdClose: Bool = false, unconfirmed: Bool = true) {
        self.holdClose = holdClose
        self.unconfirmed = unconfirmed
    }
    func waitForClose() async { while closeWaiter == nil { await Task.yield() } }
    func releaseClose() {
        holdClose = false
        closeWaiter?.resume()
        closeWaiter = nil
    }
    func status() -> NexArmBluetoothSnapshot {
        var result = NexArmBluetoothSnapshot()
        result.failure = unconfirmed ? .disconnectUnconfirmed : nil
        result.phase = unconfirmed ? .connected : .disconnected
        return result
    }
    func disconnect() { disconnects += 1 }
    func close() async {
        disconnects += 1
        if holdClose { await withCheckedContinuation { closeWaiter = $0 } }
    }
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
    await #expect(throws: PlatformFailure.self) { try await root.setForeground(false) }
    await #expect(throws: PlatformFailure.self) { try await root.setForeground(true) }
    await #expect(throws: PlatformFailure.self) { try await root.stop() }
    await #expect(throws: PlatformFailure.self) { try await root.stop() }
    #expect(!root.isAvailable)
    #expect(await link.disconnects == 1)
    #expect(
        channel.snapshot().records.contains { $0.event.component == "connectivity" && $0.event.module == "platform" })
    await channel.stop()
}

@Test @MainActor func platformStateResumeCannotOutliveNewerInvalidation() async throws {
    let link = UnconfirmedPlatformLink(holdClose: true, unconfirmed: false)
    let root = PlatformContainer(makeConnectivity: { ConnectivityContainer(admission: $0, bluetooth: link) })
    try root.start()
    root.invalidate()
    await link.waitForClose()
    let ready = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let resume = Task { @MainActor in
        ready.continuation.yield(())
        try await root.setForeground(true)
    }
    var events = ready.stream.makeAsyncIterator()
    _ = await events.next()
    root.invalidate()
    await link.releaseClose()
    try await resume.value
    ready.continuation.finish()
    #expect(!root.isAvailable)
    #expect(throws: PlatformError.unavailable) { try root.snapshot(.time) }
    try await root.setForeground(true)
    #expect(root.isAvailable)
    try await root.stop()
}
