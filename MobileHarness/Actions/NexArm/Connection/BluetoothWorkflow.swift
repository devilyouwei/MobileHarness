import Foundation
import FunctionContracts
import Observation
import PlatformKit
import StorageDevices
import UI

#if os(iOS)
    import UIKit
#endif

/// UI control/presentation adapter. Connection and motion state belong to NexArmControlService.
@MainActor public final class BluetoothWorkflow: BluetoothControlling {
    public let state: any DeviceSettingsPresenting
    public let service: NexArmControlService
    private var projectionTask: Task<Void, Never>?
    public init(
        state: any DeviceSettingsPresenting, link: any NexArmBluetoothLink,
        makeDeviceRepository: @escaping @Sendable () throws -> any DeviceRepository
    ) {
        self.state = state
        service = NexArmControlService(
            state: NexArmConnectionState(), link: link, makeDeviceRepository: makeDeviceRepository)
        observe()
    }
    deinit { projectionTask?.cancel() }
    public var trackingAvailable: Bool { service.trackingAvailable }
    public var lastManualFailure: NexArmControlFailure? { service.lastManualFailure }
    public var manualOrigin: NexArmControlOrigin? {
        get { service.manualOrigin }
        set { service.manualOrigin = newValue }
    }
    public var manualFailureReporter: (@Sendable (NexArmControlFailure) async -> Void)? {
        get { service.manualFailureReporter }
        set { service.manualFailureReporter = newValue }
    }
    public var trackingInputAvailable: @Sendable () async -> Bool {
        get { service.trackingInputAvailable }
        set { service.trackingInputAvailable = newValue }
    }
    public var withMotorResources:
        (@Sendable (Set<Int>, @escaping @Sendable () async throws -> Void) async throws -> Void)?
    {
        get { service.withMotorResources }
        set { service.withMotorResources = newValue }
    }
    private func observe() {
        withObservationTracking {
            project()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.projectionTask == nil else { return }
                self.projectionTask = Task { [weak self] in
                    guard let self else { return }
                    self.projectionTask = nil
                    self.observe()
                }
            }
        }
    }
    private func project() {
        let source = service.state
        var snapshot = BluetoothViewSnapshot()
        switch source.availability {
        case .unknown: snapshot.availability = .unknown
        case .available: snapshot.availability = .available
        case .poweredOff: snapshot.availability = .poweredOff
        case .denied: snapshot.availability = .denied
        case .unsupported: snapshot.availability = .unsupported
        }
        switch source.phase {
        case .idle: snapshot.phase = .idle
        case .connecting: snapshot.phase = .connecting
        case .connected: snapshot.phase = .connected
        case .disconnecting: snapshot.phase = .disconnecting
        case .failed: snapshot.phase = .failed
        }
        snapshot.scanning = source.scanning
        snapshot.remembered = source.remembered.map { .init(id: $0.id, name: $0.name) }
        snapshot.nearby = source.nearby.map { .init(id: $0.id, name: $0.name) }
        snapshot.selected = source.selected.map { .init(id: $0.id, name: $0.name) }
        switch source.recoveryStage {
        case .idle: snapshot.recoveryStage = .idle
        case .cleaning: snapshot.recoveryStage = .cleaning
        case .waiting: snapshot.recoveryStage = .waiting
        case .connecting: snapshot.recoveryStage = .connecting
        case .waitingForBluetooth: snapshot.recoveryStage = .waitingForBluetooth
        case .suspended: snapshot.recoveryStage = .suspended
        case .failed: snapshot.recoveryStage = .failed
        }
        snapshot.recoveryDeviceID = source.recoveryDeviceID
        snapshot.recoveryAttempt = source.recoveryAttempt
        snapshot.transportIssue = source.transportIssue
        snapshot.error = source.error
        snapshot.notice = source.notice
        snapshot.jogging = source.jogging
        snapshot.joints = source.joints
        snapshot.pose = source.pose
        snapshot.sampledAt = source.sampledAt
        state.apply(snapshot)
    }
    public func shutdown() async throws {
        defer { project() }
        try await service.shutdown()
    }
    public func run() async {
        await service.run()
        project()
    }
    public func waitUntilIdle() async {
        await service.waitUntilIdle()
        project()
    }
    public func setForeground(_ value: Bool) {
        service.setForeground(value)
        project()
    }
    public func validateControlAdmission(_ request: DeviceControlRequest) throws {
        try service.validateControlAdmission(request)
    }
    public func openPage() {
        service.openPage()
        project()
    }
    public func closePage() {
        service.closePage()
        project()
    }
    public func scan() {
        service.scan()
        project()
    }
    public func stopScan() {
        service.stopScan()
        project()
    }
    public func connect(_ id: String) {
        service.connect(id)
        project()
    }
    public func reconnect(_ id: String) {
        service.reconnect(id)
        project()
    }
    public func disconnect() {
        service.disconnect()
        project()
    }
    public func forget() {
        service.forget()
        project()
    }
    public func refreshDevice() async {
        await service.refreshDevice()
        project()
    }
    public func tryAction(_ action: BluetoothArmAction) {
        guard let value = NexArmManualAction(rawValue: action.rawValue) else { return }
        service.tryAction(value)
        project()
    }
    public func setMotorVelocity(id: Int, value: Double) {
        service.setMotorVelocity(id: id, value: value)
        project()
    }
    public func stopMotorControl() {
        service.stopMotorControl()
        project()
    }
    public func stopActions() async {
        await service.stopActions()
        project()
    }
    public func stopAgentActions() async {
        await service.stopAgentActions()
        project()
    }
    public func shakeBase(cycles: Int, recordReport: @escaping @Sendable (ActionReport) async throws -> Void = { _ in })
        async throws
    {
        try await service.shakeBase(cycles: cycles, recordReport: recordReport)
        project()
    }
    public func resetArm(
        speed: Int = NexArmDeviceLimits.defaultSpeed, acceleration: Int = NexArmDeviceLimits.defaultAcceleration,
        recordReport: @escaping @Sendable (ActionReport) async throws -> Void = { _ in }
    ) async throws {
        try await service.resetArm(speed: speed, acceleration: acceleration, recordReport: recordReport)
        project()
    }
    public func performGesture(
        _ gesture: NexArmGesture, repetitions: Int, speed: Int = NexArmDeviceLimits.defaultSpeed,
        acceleration: Int = NexArmDeviceLimits.defaultAcceleration,
        recordReport: @escaping @Sendable (ActionReport) async throws -> Void = { _ in }
    ) async throws {
        try await service.performGesture(
            gesture, repetitions: repetitions, speed: speed, acceleration: acceleration, recordReport: recordReport)
        project()
    }
    public func moveMotor(
        id: Int, target: Int?, deltaDegrees: Double? = nil, speed: Int, acceleration: Int,
        recordReport: @escaping @Sendable (ActionReport) async throws -> Void = { _ in }
    ) async throws {
        try await service.moveMotor(
            id: id, target: target, deltaDegrees: deltaDegrees, speed: speed, acceleration: acceleration,
            recordReport: recordReport)
        project()
    }
    public func aim(
        base: Double, pitch: Double, origin: NexArmControlOrigin? = nil,
        failed: @escaping @Sendable (NexArmControlFailure) async -> Void = { _ in }
    ) async throws {
        try await service.aim(base: base, pitch: pitch, origin: origin, failed: failed)
        project()
    }
    public func openSystemSettings() {
        #if os(iOS)
            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
            UIApplication.shared.open(url)
        #endif
    }
}
