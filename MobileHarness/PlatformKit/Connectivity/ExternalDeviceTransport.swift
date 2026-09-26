/// Transport contract; robot adapters must validate command limits and implement a hardware watchdog.
public protocol ExternalDeviceTransport: Actor {
    func connect() async throws
    func send(_ bytes: [UInt8]) async throws
    func emergencyStop() async
    func disconnect() async
}
