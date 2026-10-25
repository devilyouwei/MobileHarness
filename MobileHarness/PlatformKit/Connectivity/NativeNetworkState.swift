import CoreBluetooth
import Foundation
import Network
import Synchronization

/// One event snapshot. It says nothing about a particular remote service's availability.
struct NativeNetworkSnapshot: Sendable {
    var status = "unknown"
    var interfaces: [String] = []
    var expensive: Bool?
    var constrained: Bool?
    var observedAt: Date?
    func encoded() throws -> Data {
        try NativeSystemState.encode([
            "status": status, "interfaces": interfaces,
            "expensive": expensive as Any? ?? NSNull(), "constrained": constrained as Any? ?? NSNull(),
            "observedAt": observedAt.map { ISO8601DateFormatter().string(from: $0) } as Any? ?? NSNull(),
        ])
    }
}

/// The callback stores one value; generation fencing rejects late work from a retired monitor.
final class NativeNetworkObservation: Sendable {
    private struct State: Sendable {
        var generation: UUID?
        var snapshot = NativeNetworkSnapshot()
    }
    private let state = Mutex(State())
    func begin() -> UUID {
        state.withLock {
            let generation = UUID()
            $0 = State(generation: generation)
            return generation
        }
    }
    func accept(_ snapshot: NativeNetworkSnapshot, generation: UUID) {
        state.withLock { if $0.generation == generation { $0.snapshot = snapshot } }
    }
    func end() { state.withLock { $0 = State() } }
    func snapshot() -> NativeNetworkSnapshot { state.withLock { $0.snapshot } }
}

@MainActor final class NativeNetworkState {
    private let observation = NativeNetworkObservation()
    private let queue = DispatchQueue(label: "dev.mobileharness.platform.network-facts")
    private var monitor: NWPathMonitor?
    func start() {
        guard monitor == nil else { return }
        let generation = observation.begin()
        let observation = observation
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            let status: String
            switch path.status {
            case .satisfied: status = "satisfied"
            case .unsatisfied: status = "unsatisfied"
            case .requiresConnection: status = "requiresConnection"
            @unknown default: status = "unknown"
            }
            let types: [(NWInterface.InterfaceType, String)] = [
                (.wifi, "wifi"), (.cellular, "cellular"), (.wiredEthernet, "wiredEthernet"),
                (.loopback, "loopback"), (.other, "other"),
            ]
            observation.accept(
                NativeNetworkSnapshot(
                    status: status, interfaces: types.filter { path.usesInterfaceType($0.0) }.map(\.1).sorted(),
                    expensive: path.isExpensive, constrained: path.isConstrained, observedAt: Date()),
                generation: generation)
        }
        self.monitor = monitor
        monitor.start(queue: queue)
    }
    func invalidate() {
        observation.end()
        monitor?.cancel()
        monitor = nil
    }
    func stop() async {
        invalidate()
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }
    func snapshot() throws -> Data { try observation.snapshot().encoded() }
    static var bluetoothAuthorization: String {
        switch CBManager.authorization {
        case .notDetermined: "notDetermined"
        case .restricted: "restricted"
        case .denied: "denied"
        case .allowedAlways: "authorized"
        @unknown default: "unknown"
        }
    }
}
