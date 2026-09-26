import Foundation

/// Sends one six-position frame per aim. `home()` refuses the provisional 2048 table.
public actor NexArmController {
    private let transport: any ExternalDeviceTransport

    public init(transport: any ExternalDeviceTransport) {
        self.transport = transport
    }

    public func aim(base: Double, pitch: Double) async throws {
        try await transport.send(try NexArmJointCommand.aimFrame(base: base, pitch: pitch))
    }

    public func home() async throws {
        throw NexArmControlError.provisionalHome
    }

    public func emergencyStop() async {
        await transport.emergencyStop()
    }
}
