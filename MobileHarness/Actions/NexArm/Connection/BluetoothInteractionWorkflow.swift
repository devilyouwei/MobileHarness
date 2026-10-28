import Foundation
import PlatformKit
import StorageCore
import UI

/// Root-owned bounded intent adapter. Native recovery and accepted manual workers outlive pages.
@MainActor public final class BluetoothInteractionWorkflow: BluetoothControlling {
    private let state: any DeviceSettingsPresenting
    private let perform: ([String: String]) async throws -> Void
    private let pageVisibility: (Bool) -> Void
    private let openSettings: () -> Void
    private let fenceStop: () -> String
    private var fence: String
    private var pending: [[String: String]] = []
    private var motors: [Int: Double] = [:]
    private var worker: Task<Void, Never>?
    private var controlWorker: Task<Void, Never>?
    private var closed = false
    public init(
        state: any DeviceSettingsPresenting, initialFence: String, fenceStop: @escaping () -> String,
        pageVisibility: @escaping (Bool) -> Void, openSettings: @escaping () -> Void,
        perform: @escaping ([String: String]) async throws -> Void
    ) {
        self.state = state
        self.fence = initialFence
        self.fenceStop = fenceStop
        self.pageVisibility = pageVisibility
        self.openSettings = openSettings
        self.perform = perform
    }
    public func waitUntilIdle() async {
        await worker?.value
        await controlWorker?.value
    }
    public func shutdown() async {
        closed = true
        replaceMotion()
        pending.removeAll()
        let task = worker
        let control = controlWorker
        task?.cancel()
        control?.cancel()
        await task?.value
        await control?.value
    }
    public func reconnect(_ id: String) { submit(["operation": "reconnect", "id": id]) }
    public func refreshDevice() async {
        submit(["operation": "refresh"])
        await worker?.value
    }
    public func tryAction(_ action: BluetoothArmAction) {
        replaceMotion()
        submit(["operation": "preset", "action": action.rawValue], priority: action == .reset)
    }
    public func setMotorVelocity(id: Int, value: Double) {
        guard !closed else {
            state.present(.error("设备交互已关闭"))
            return
        }
        guard NexArmDeviceLimits.motorIDs.contains(id), value.isFinite, (-1...1).contains(value) else {
            state.present(.error("电机操作参数无效"))
            return
        }
        motors[id] = value
        drain()
    }
    public func stopMotorControl() {
        replaceMotion()
    }
    public func openPage() { pageVisibility(true) }
    public func closePage() {
        replaceMotion()
        pageVisibility(false)
    }
    public func scan() { submit(["operation": "scan"]) }
    public func stopScan() { submit(["operation": "stopScan"], priority: true) }
    public func connect(_ id: String) { submit(["operation": "connect", "id": id]) }
    public func disconnect() {
        replaceMotion()
        submit(["operation": "disconnect"], priority: true)
    }
    public func forget() {
        replaceMotion()
        submit(["operation": "forget"], priority: true)
    }
    public func openSystemSettings() { openSettings() }
    private func replaceMotion() {
        fence = fenceStop()
        motors.removeAll()
        pending.removeAll { $0["operation"] == "preset" || $0["operation"] == "motorVelocity" }
    }
    private func submit(_ request: [String: String], priority: Bool = false) {
        guard !closed else {
            state.present(.error("设备交互已关闭"))
            return
        }
        var request = request
        request["fence"] = fence
        if ["stopScan", "disconnect", "forget"].contains(request["operation"] ?? "") {
            guard controlWorker == nil else {
                state.present(.error("设备控制正在执行，请稍后重试"))
                return
            }
            controlWorker = Task {
                defer { controlWorker = nil }
                do { try await perform(request) } catch {
                    if request["fence"] == fence { state.present(.error("设备操作失败：" + error.localizedDescription)) }
                }
            }
            return
        }
        if pending.contains(request) { return }
        guard pending.count < 16 else {
            state.present(.error("设备操作过多，请稍后重试"))
            return
        }
        if priority { pending.insert(request, at: 0) } else { pending.append(request) }
        drain()
    }
    private func drain() {
        guard worker == nil else { return }
        worker = Task {
            defer { worker = nil }
            while !closed, !Task.isCancelled, !pending.isEmpty || !motors.isEmpty {
                let request: [String: String]
                if !pending.isEmpty {
                    request = pending.removeFirst()
                } else if let id = motors.keys.min(), let value = motors.removeValue(forKey: id) {
                    request = [
                        "operation": "motorVelocity", "id": String(id), "value": String(value),
                        "fence": fence,
                    ]
                } else {
                    break
                }
                do { try await perform(request) } catch {
                    if request["fence"] == fence { state.present(.error("设备操作失败：" + error.localizedDescription)) }
                }
            }
        }
    }
}
