import Foundation

public enum ConnectivityCleanupError: Error { case disconnectUnconfirmed }

@MainActor public final class ConnectivityContainer {
    public func stateSnapshot() async throws -> PlatformStateSnapshot {
        try Task.checkCancellation()
        return .init(
            path: "platform.connectivity", business: ["bluetoothAuthorization": .text(try bluetoothAuthorization)],
            runtime: ["available": .flag(admission.isOpen)], children: [.init(path: "platform.connectivity.nexarm")])
    }
    public func stateReaders() async throws -> [String: PlatformStateSnapshot.Reader] {
        var readers: [String: PlatformStateSnapshot.Reader] = [
            "platform.connectivity": PlatformStateSnapshot.reader(of: self) { try await $0.stateSnapshot() },
            "platform.connectivity.nexarm": PlatformStateSnapshot.reader(of: self) {
                try await $0.nativeStateSnapshot()
            },
        ]
        for motor in 1...6 {
            readers["platform.connectivity.nexarm.motor" + String(motor)] = PlatformStateSnapshot.reader(of: self) {
                try await $0.nativeStateSnapshot(motor: motor)
            }
        }
        return readers
    }
    private func nativeStateSnapshot(motor: Int? = nil) async throws -> PlatformStateSnapshot {
        try Task.checkCancellation()
        let observed = bluetooth.reflectedState?.snapshot()
        try Task.checkCancellation()
        let path = "platform.connectivity.nexarm" + (motor.map { ".motor" + String($0) } ?? "")
        guard let value = observed else {
            return .init(
                path: path, runtime: ["available": .flag(false)],
                children: motor == nil ? (1...6).map { .init(path: path + ".motor" + String($0)) } : [])
        }
        let age = value.feedbackReceivedAt.map { $0.duration(to: .now) }
        let seconds = age.map { max(0, Double($0.components.seconds) + Double($0.components.attoseconds) / 1e18) }
        let joints = value.phase == .connected ? value.feedbackPacket?.observedMotorPositions : nil
        let valid = joints != nil
        if let motor {
            return .init(
                path: path,
                business: [
                    "positionCounts": joints.map { .count($0[motor - 1]) } ?? .unknown,
                    "feedbackAgeSeconds": seconds.map { .number($0) } ?? .unknown,
                    "fresh": .flag(valid && seconds.map { $0 <= 2 } == true),
                ],
                runtime: ["connectionID": .text(value.connectionID)],
                meanings: [
                    "business.positionCounts": "Latest native receipt for this connection; not a commanded target"
                ],
                units: ["business.positionCounts": "encoder counts", "business.feedbackAgeSeconds": "seconds"])
        }
        let level: PlatformStateSnapshot.Health =
            value.failure != nil
            ? .fault
            : value.phase == .connected
                && (!value.feedbackHealthy || value.queriesQuarantined || seconds.map { $0 > 2 } == true)
                ? .limited
                : value.phase == .connected && valid && seconds.map { $0 <= 2 } == true ? .healthy : .unknown
        return .init(
            path: path,
            business: [
                "phase": .text(value.phase.rawValue), "power": .text(value.power.rawValue),
                "scanning": .flag(value.scanning),
                "positionsCounts": joints.map { .integers($0) } ?? .unknown,
                "feedbackAgeSeconds": seconds.map { .number($0) } ?? .unknown,
                "feedbackFresh": .flag(valid && seconds.map { $0 <= 2 } == true),
                "problem": value.phase == .connected && (!valid || seconds.map { $0 > 2 } == true)
                    ? .text("positionFeedbackUnavailable") : .unknown,
            ],
            runtime: [
                "connectionID": .text(value.connectionID), "revision": .unsigned(value.revision),
                "feedbackHealthy": value.feedbackReceivedAt == nil ? .unknown : .flag(value.feedbackHealthy),
                "queriesQuarantined": .flag(value.queriesQuarantined),
            ], health: level,
            issues: level == .fault || level == .limited
                ? [.init(code: "nativeConnection", impact: "connectionIntegrityUnconfirmed")] : [],
            children: (1...6).map { .init(path: path + ".motor" + String($0)) },
            meanings: [
                "business.phase": "Native link phase, not robot motion or control authorization",
                "business.feedbackFresh": "Connected-session position receipt age is at most two seconds",
                "business.problem": "Missing or stale position evidence; not inferred from query quarantine",
            ],
            units: ["business.positionsCounts": "encoder counts", "business.feedbackAgeSeconds": "seconds"],
            stateValues: [
                "business.phase": NexArmBluetoothPhase.allCases.map(\.rawValue),
                "business.power": NexArmBluetoothPower.allCases.map(\.rawValue),
            ])
    }
    private let admission: PlatformAdmission
    private let networkState = NativeNetworkState()
    func startStateObservation() { networkState.start() }
    func invalidateStateObservation() { networkState.invalidate() }
    func networkSnapshot() throws -> Data { try networkState.snapshot() }
    var readBluetoothAuthorization: () throws -> String = { "unknown" }
    var bluetoothAuthorization: String { get throws { try readBluetoothAuthorization() } }
    #if os(macOS)
        private var serial: NexArmSerial?
        public func openSerial(path: String) throws -> any NexArmObservableLink {
            do {
                try admission.check()
                guard serial == nil else { throw PlatformError.busy }
                let value = try NexArmSerial(path: path, admission: admission)
                serial = value
                return value
            } catch {
                admission.report("connectivity", "openSerial", error)
                throw error
            }
        }
    #endif
    public let bluetooth: any NexArmBluetoothLink
    public init(admission: PlatformAdmission, bluetooth: (any NexArmBluetoothLink)? = nil) {
        self.admission = admission
        self.bluetooth = bluetooth ?? NexArmBluetooth(admission: admission)
    }
    func stop() async throws {
        await networkState.stop()
        do {
            #if os(macOS)
                await serial?.close()
                serial = nil
            #endif
            await bluetooth.close()
            let snapshot = await bluetooth.status()
            if snapshot.failure == .disconnectUnconfirmed || snapshot.phase != .disconnected {
                throw ConnectivityCleanupError.disconnectUnconfirmed
            }
        } catch {
            admission.report("connectivity", "stop", error)
            throw error
        }
    }
}
