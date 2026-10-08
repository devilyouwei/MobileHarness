import Foundation
import FunctionContracts

public struct DeviceControlRequest: Sendable {
    public enum Operation: String, Sendable {
        case scan, stopScan, connect, reconnect, disconnect, forget, refresh, preset, motorVelocity, stopMotorControl,
            openPage, closePage, openSystemSettings
    }
    public static let actions: Set<String> = [
        "shakeBase", "nod", "shakeHead", "wave", "tiltLeft", "tiltRight", "lookAround", "celebrate", "dance", "reset",
    ]
    public let operation: Operation
    public let id: String?
    public let value: Double?
    public let action: String?
    public let fence: String?
    public init(
        operation: Operation, id: String? = nil, value: Double? = nil, action: String? = nil, fence: String? = nil
    ) {
        self.operation = operation
        self.id = id
        self.value = value
        self.action = action
        self.fence = fence
    }
}
public protocol DeviceControlCapability: Sendable {
    func control(_ request: DeviceControlRequest, invocation: any FunctionInput) async throws
    func readEnvironment() async throws -> String
    func readStatus() async throws -> String
}
public enum DeviceControlError: String, Error, Sendable, ActionExecutionFailureProviding {
    case invalidRequest = "device.request"
    case unavailable = "device.unavailable"
    case stale = "device.stale"
    public var executionFailureCode: ActionExecutionFailureCode { .init(rawValue: rawValue) }
}
public struct DeviceModule: CapabilityModule {
    private let device: any DeviceControlCapability
    public init(device: any DeviceControlCapability) { self.device = device }
    public var definitions: [ActionFunction] {
        [
            SystemActions.readEnvironmentDefinition(completing: { [device] in
                .value(try await SystemActions.readEnvironment(invocation: $0, using: device))
            }),
            SystemActions.controlDefinition(completing: { [device] in
                .value(try await SystemActions.control(invocation: $0, using: device))
            }),
            SystemActions.readStatusDefinition(completing: { [device] in
                .value(try await SystemActions.readStatus(invocation: $0, using: device))
            }),
        ]
    }
}

extension DeviceControlCapability {
    public func readEnvironment() async throws -> String { throw DeviceControlError.unavailable }
}
