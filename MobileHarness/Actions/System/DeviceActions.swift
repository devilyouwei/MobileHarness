import Foundation
import FunctionContracts

extension SystemActions {
    @Action(domain: "System", module: "Device", title: "control", timeout: .seconds(60))
    public static func control(invocation: any FunctionInput, using device: any DeviceControlCapability) async throws
        -> String
    {
        let args = ActionArguments(invocation.call.parameters)
        try args.validateAllowedKeys(["operation", "id", "value", "action", "fence"])
        guard
            let operation = DeviceControlRequest.Operation(
                rawValue: try args.requiredString("operation", maximumUTF8Bytes: 32))
        else { throw DeviceControlError.invalidRequest }
        let id = invocation.call.parameters["id"]
        let value = invocation.call.parameters["value"].flatMap(Double.init)
        let action = invocation.call.parameters["action"]
        guard invocation.call.parameters["value"] == nil || value != nil else {
            throw DeviceControlError.invalidRequest
        }
        switch operation {
        case .connect, .reconnect:
            guard id.flatMap(UUID.init(uuidString:)) != nil, value == nil, action == nil else {
                throw DeviceControlError.invalidRequest
            }
        case .motorVelocity:
            guard id.flatMap(Int.init).map({ (1...6).contains($0) }) == true, let value, value.isFinite,
                (-1...1).contains(value), action == nil
            else { throw DeviceControlError.invalidRequest }
        case .preset:
            guard let action, DeviceControlRequest.actions.contains(action), id == nil, value == nil else {
                throw DeviceControlError.invalidRequest
            }
        default: guard id == nil, value == nil, action == nil else { throw DeviceControlError.invalidRequest }
        }
        if let fence = invocation.call.parameters["fence"], UUID(uuidString: fence) == nil {
            throw DeviceControlError.invalidRequest
        }
        try Task.checkCancellation()
        try await device.control(
            .init(
                operation: operation, id: id, value: value, action: action, fence: invocation.call.parameters["fence"]),
            invocation: invocation)
        return "{\"status\":\"accepted\",\"operation\":\"\(operation.rawValue)\"}"
    }
    @Action(domain: "System", module: "Device", title: "readEnvironment")
    public static func readEnvironment(invocation: any FunctionInput, using device: any DeviceControlCapability)
        async throws -> String
    {
        try ActionArguments(invocation.call.parameters).validateAllowedKeys([])
        let value = try await device.readEnvironment()
        guard value.utf8.count <= 65_536 else { throw DeviceControlError.invalidRequest }
        return value
    }
    @Action(domain: "System", module: "Device", title: "readStatus")
    public static func readStatus(invocation: any FunctionInput, using device: any DeviceControlCapability) async throws
        -> String
    {
        try ActionArguments(invocation.call.parameters).validateAllowedKeys([])
        let result = try await device.readStatus()
        guard result.utf8.count <= 16_384 else { throw DeviceControlError.invalidRequest }
        return result
    }
}
