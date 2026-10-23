import AgentCore
import CallRuntime
import ExecutionRuntime
import Foundation
import FunctionContracts
import StorageCore
import UI

/// Native device adaptation; typed command admission belongs to the canonical Device functions.
@MainActor public final class NexArmDeviceAdapter: DeviceControlCapability {
    public let bluetooth: BluetoothWorkflow
    public private(set) var fence = UUID().uuidString
    public var environment: (@Sendable () async throws -> String)?
    public var deliverActionResult: (@Sendable (ActionResult, ActionReport?) async -> Bool)?
    public var activity: (any ExecutionFailureReporting)?
    public func readEnvironment() async throws -> String {
        guard let environment else { throw DeviceControlError.unavailable }
        return try await environment()
    }
    public init(bluetooth: BluetoothWorkflow) { self.bluetooth = bluetooth }
    public func stopFence() -> String {
        fence = UUID().uuidString
        bluetooth.stopMotorControl()
        return fence
    }
    public func control(_ request: DeviceControlRequest, invocation: any FunctionInput) async throws {
        try Task.checkCancellation()
        if let expected = request.fence, expected != fence { throw DeviceControlError.stale }
        try bluetooth.validateControlAdmission(request)
        if request.operation == .preset || request.operation == .motorVelocity {
            let origin = NexArmControlOrigin(
                source: invocation.context.source, sessionID: invocation.context.sessionID,
                inputID: invocation.context.inputID, callID: invocation.executionID)
            bluetooth.manualOrigin = origin
            if let owner = ResourceExecutionContext.owner, let deliverActionResult, let activity {
                let executionID = invocation.executionID
                let path = invocation.call.actionPath
                let causality = SignalCausality(
                    inputID: invocation.context.inputID, rootID: invocation.context.inputID, hops: 0)
                bluetooth.manualFailureReporter = { failure in
                    await activity.recordFailure(
                        title: "手动机械臂操作失败", source: origin.source, message: failure.message, failureCode: failure.code,
                        context: .init(
                            workerID: failure.workerID, sessionID: origin.sessionID,
                            inputID: origin.inputID,
                            callID: origin.callID))
                    let result = ActionResult(
                        executionID: executionID, owner: owner,
                        path: .init(domain: path.domain, module: path.module, function: path.function),
                        causality: causality,
                        status: failure.report?.entries.contains(where: { $0.status == .succeeded }) == true
                            ? .partialFailure : .failed, effect: .unknown,
                        completion: nil,
                        failure: .handlerFailed)
                    let delivery = await deliverActionResult(result, failure.report)
                    if !delivery {
                        await activity.recordFailure(
                            title: "设备结果反馈失败", source: origin.source, message: "原始执行失败已保留，反馈未被接收",
                            failureCode: "device.feedback", context: nil)
                    }
                }
            }
        }
        switch request.operation {
        case .scan:
            guard bluetooth.state.phase != .connected else { throw DeviceControlError.unavailable }
            bluetooth.scan()
        case .stopScan: bluetooth.stopScan()
        case .connect, .reconnect:
            guard let id = request.id.flatMap(BusinessRecordID.parse) else { throw DeviceControlError.invalidRequest }
            if request.operation == .reconnect {
                bluetooth.reconnect(id)
            } else {
                bluetooth.connect(id)
            }
        case .disconnect: bluetooth.disconnect()
        case .forget: bluetooth.forget()
        case .refresh:
            guard bluetooth.state.phase == .connected else { throw DeviceControlError.unavailable }
            await bluetooth.refreshDevice()
        case .preset:
            guard bluetooth.state.canControl, let name = request.action, let action = BluetoothArmAction(rawValue: name)
            else { throw DeviceControlError.unavailable }
            bluetooth.tryAction(action)
        case .motorVelocity:
            guard let id = request.id.flatMap(Int.init), let value = request.value,
                value == 0 || bluetooth.state.canControl
            else { throw DeviceControlError.unavailable }
            bluetooth.setMotorVelocity(id: id, value: value)
        case .stopMotorControl: bluetooth.stopMotorControl()
        case .openPage: bluetooth.openPage()
        case .closePage: bluetooth.closePage()
        case .openSystemSettings: bluetooth.openSystemSettings()
        }
    }
    public func readStatus() throws -> String {
        let state = bluetooth.state
        let devices = state.nearby.map { ["id": $0.id, "name": $0.name] }
        guard devices.count <= 32 else { throw DeviceControlError.invalidRequest }
        return String(
            decoding: try JSONSerialization.data(
                withJSONObject: [
                    "connection": String(describing: state.phase), "recovery": String(describing: state.recoveryStage),
                    "availability": String(describing: state.availability), "canControl": state.canControl,
                    "issue": state.error ?? state.transportIssue ?? "",
                    "nearby": devices,
                ], options: [.sortedKeys]), as: UTF8.self)
    }
}
