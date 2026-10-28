import Foundation
import FunctionContracts
import StorageCore

extension SystemActions {
    @Action(
        domain: "System", module: "Device", title: "control",
        doc:
            "Submit an explicit Bluetooth connection/discovery command. Accepted is not connected or physically completed. Read status to confirm actual state.",
        parameters: [
            .init(
                "operation", type: .string, required: true, description: "operation",
                constraints: "One of the supported device connection, page or motor control operations",
                values: [
                    "scan", "stopScan", "connect", "reconnect", "disconnect", "forget", "refresh", "preset",
                    "motorVelocity", "stopMotorControl", "openPage", "closePage", "openSystemSettings",
                ]),
            .init("id", type: .string, required: false, description: "id", constraints: ""),
            .init("value", type: .string, required: false, description: "Motor velocity", constraints: ""),
            .init("action", type: .string, required: false, description: "Preset action", constraints: ""),
            .init("fence", type: .string, required: false, description: "Device session fence UUID", constraints: ""),
        ], timeout: .seconds(60))
    public static func control(invocation: any FunctionInput, using device: any DeviceControlCapability) async throws
        -> String
    {
        let args = ActionArguments(invocation.call.parameters)
        try args.validateAllowedKeys(["operation", "id", "value", "action", "fence"])
        guard
            let operation = DeviceControlRequest.Operation(
                rawValue: try args.requiredString("operation", maximumUTF8Bytes: 32))
        else { throw DeviceControlError.invalidRequest }
        let id = [.connect, .reconnect, .motorVelocity].contains(operation) ? invocation.call.parameters["id"] : nil
        let value = operation == .motorVelocity ? invocation.call.parameters["value"].flatMap(Double.init) : nil
        let action = operation == .preset ? invocation.call.parameters["action"] : nil
        switch operation {
        case .connect, .reconnect:
            guard id.flatMap(BusinessRecordID.parse) != nil else {
                throw DeviceControlError.invalidRequest
            }
        case .motorVelocity:
            guard id.flatMap(Int.init).map({ (1...6).contains($0) }) == true, let value, value.isFinite,
                (-1...1).contains(value)
            else { throw DeviceControlError.invalidRequest }
        case .preset:
            guard let action, DeviceControlRequest.actions.contains(action) else {
                throw DeviceControlError.invalidRequest
            }
        default: break
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
    @Action(
        domain: "System", module: "Device", title: "readStatus",
        doc: "Read current Bluetooth power/connection and discovered device IDs. Does not scan or move a robot.",
        parameters: [])
    public static func readStatus(invocation: any FunctionInput, using device: any DeviceControlCapability) async throws
        -> String
    {
        try ActionArguments(invocation.call.parameters).validateAllowedKeys([])
        let result = try await device.readStatus()
        guard result.utf8.count <= 16_384 else { throw DeviceControlError.invalidRequest }
        return result
    }
}
