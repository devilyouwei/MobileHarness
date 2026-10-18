import Foundation

public enum ConnectivityCleanupError: Error { case disconnectUnconfirmed }

@MainActor public final class ConnectivityContainer {
    private let admission: PlatformAdmission
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
