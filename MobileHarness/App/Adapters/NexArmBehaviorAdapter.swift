import Actions
import AgentCore
import AppWorkflows
import CallRuntime
import ExecutionRuntime
import Foundation
import FunctionContracts
import Gateway
import UI

/// Host adaptation only; gesture/execution business policy remains in Actions.
@MainActor
struct NexArmBehaviorAdapter {
    let bluetooth: BluetoothWorkflow
    let activity: ActionActivityWorkflow
    func aim(_ base: Double, _ pitch: Double, _ invocation: any FunctionInput) async throws {
        do {
            try await bluetooth.aim(
                base: base, pitch: pitch,
                origin: .init(
                    source: invocation.context.source, sessionID: invocation.context.sessionID,
                    inputID: invocation.context.inputID, callID: invocation.executionID)
            ) { [activity] failure in
                await activity.recordFailure(
                    title: "NexArm.Tracking.aim", source: failure.origin?.source ?? "持续控制", message: failure.message,
                    failureCode: failure.code,
                    context: .init(
                        workerID: failure.workerID, sessionID: failure.origin?.sessionID,
                        inputID: failure.origin?.inputID, callID: failure.origin?.callID))
            }
        } catch let error as NexArmExecutionError {
            throw ActionExecutionFailure(
                code: .init(rawValue: error.actionExecutionFailure.rawValue),
                message: ActionReport.description(for: error))
        }
    }
    func gesture(_ request: NexArmActions.GestureRequest, _ invocation: any FunctionInput) async throws {
        let reports = ActionReportStore()
        do {
            switch request.gesture {
            case .reset:
                try await bluetooth.resetArm(
                    speed: request.speed, acceleration: request.acceleration,
                    recordReport: { try await reports.record($0) })
            case .moveMotor, .resetMotor:
                guard let motor = request.motor else { throw NexArmExecutionError.invalidArguments }
                try await bluetooth.moveMotor(
                    id: motor, target: request.target, speed: request.speed,
                    acceleration: request.acceleration, recordReport: { try await reports.record($0) })
            default:
                let gesture: NexArmGesture
                switch request.gesture {
                case .nod: gesture = .nod
                case .shakeHead: gesture = .shakeHead
                case .wave: gesture = .wave
                case .tiltLeft: gesture = .tiltLeft
                case .tiltRight: gesture = .tiltRight
                case .lookAround: gesture = .lookAround
                case .celebrate: gesture = .celebrate
                case .dance: gesture = .dance
                default: throw NexArmExecutionError.invalidArguments
                }
                try await bluetooth.performGesture(
                    gesture, repetitions: request.repetitions,
                    speed: request.speed, acceleration: request.acceleration,
                    recordReport: { try await reports.record($0) })
            }
        } catch {
            if let report = await reports.snapshot() {
                try await invocation.results.record(report.recordingFailure(error))
                if error is CancellationError { throw error }
                return
            }
            throw error
        }
        if let report = await reports.snapshot() { try await invocation.results.record(report) }
    }
    func shakeBase(_ cycles: Int, _ invocation: any FunctionInput) async throws {
        let reports = ActionReportStore()
        do {
            let args = ActionArguments(invocation.call.parameters)
            let speed =
                try invocation.call.parameters["speed"] == nil
                ? 1400 : args.requiredInt("speed", range: 1...1400)
            let acceleration =
                try invocation.call.parameters["acceleration"] == nil
                ? 30 : args.requiredInt("acceleration", range: 1...254)
            try await bluetooth.performGesture(
                .baseSway, repetitions: cycles, speed: speed, acceleration: acceleration,
                recordReport: { try await reports.record($0) })
        } catch {
            if let report = await reports.snapshot() {
                try await invocation.results.record(report.recordingFailure(error))
                if error is CancellationError { throw error }
                return
            }
            throw error
        }
        if let report = await reports.snapshot() { try await invocation.results.record(report) }
    }
}

/// Native device adaptation; typed command admission belongs to the canonical Device functions.
@MainActor final class DeviceControlAdapter: DeviceControlCapability {
    let bluetooth: BluetoothWorkflow
    private(set) var fence = UUID()
    var environment: (@Sendable () async throws -> String)?
    var input: InputGateway?
    var activity: ActionActivityWorkflow?
    func readEnvironment() async throws -> String {
        guard let environment else { throw DeviceControlError.unavailable }
        return try await environment()
    }
    init(bluetooth: BluetoothWorkflow) { self.bluetooth = bluetooth }
    func stopFence() -> UUID {
        fence = UUID()
        bluetooth.stopMotorControl()
        return fence
    }
    func control(_ request: DeviceControlRequest, invocation: any FunctionInput) async throws {
        try Task.checkCancellation()
        if let expected = request.fence, expected != fence.uuidString { throw DeviceControlError.stale }
        try bluetooth.validateControlAdmission(request)
        if request.operation == .preset || request.operation == .motorVelocity {
            let origin = NexArmControlOrigin(
                source: invocation.context.source, sessionID: invocation.context.sessionID,
                inputID: invocation.context.inputID, callID: invocation.executionID)
            bluetooth.manualOrigin = origin
            if let owner = ResourceExecutionContext.owner, let input, let activity {
                let executionID = invocation.executionID
                let path = invocation.call.actionPath
                let causality = SignalCausality(
                    inputID: invocation.context.inputID, rootID: invocation.context.inputID, hops: 0)
                bluetooth.manualFailureReporter = { failure in
                    await activity.recordFailure(
                        title: "手动机械臂操作失败", source: origin.source, message: failure.message, failureCode: failure.code,
                        context: .init(
                            workerID: failure.workerID, sessionID: origin.sessionID, inputID: origin.inputID,
                            callID: origin.callID))
                    let result = ActionResult(
                        executionID: executionID, owner: owner,
                        path: .init(domain: path.domain, module: path.module, function: path.function),
                        causality: causality,
                        status: failure.report?.entries.contains(where: { $0.status == .succeeded }) == true
                            ? .partialFailure : .failed, effect: .unknown,
                        completion: failure.report.map { .report($0.agentValue) },
                        failure: .handlerFailed)
                    let delivery = await input.deliverActionResult(result)
                    if delivery != .accepted {
                        await activity.recordFailure(
                            title: "设备结果反馈失败", source: origin.source, message: "原始执行失败已保留，反馈未被接收",
                            failureCode: "device.feedback")
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
            guard let id = request.id.flatMap(UUID.init(uuidString:)) else { throw DeviceControlError.invalidRequest }
            if request.operation == .reconnect { bluetooth.reconnect(id) } else { bluetooth.connect(id) }
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
    func readStatus() throws -> String {
        let state = bluetooth.state
        let devices = state.nearby.map { ["id": $0.id.uuidString, "name": $0.name] }
        guard devices.count <= 32 else { throw DeviceControlError.invalidRequest }
        return String(
            decoding: try JSONSerialization.data(
                withJSONObject: [
                    "connection": String(describing: state.phase),
                    "availability": String(describing: state.availability), "canControl": state.canControl,
                    "issue": state.error ?? state.transportIssue ?? "",
                    "nearby": devices,
                ], options: [.sortedKeys]), as: UTF8.self)
    }
}
