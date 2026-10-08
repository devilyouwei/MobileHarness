import Agents
import Foundation
import UI

/// Root-owned bounded intent adapter. Native recovery and accepted manual workers outlive pages.
@MainActor public final class BluetoothInteractionWorkflow: BluetoothControlling {
    private let state: BluetoothSettingsState
    private let perform: (AppInteractionIntent) async throws -> Void
    private let fenceStop: () -> UUID
    private var fence: UUID
    private var pending: [[String: String]] = []
    private var motors: [Int: Double] = [:]
    private var worker: Task<Void, Never>?
    private var closed = false
    public init(
        state: BluetoothSettingsState, initialFence: UUID, fenceStop: @escaping () -> UUID,
        perform: @escaping (AppInteractionIntent) async throws -> Void
    ) {
        self.state = state
        self.fence = initialFence
        self.fenceStop = fenceStop
        self.perform = perform
    }
    public func waitUntilIdle() async { await worker?.value }
    public func shutdown() async {
        closed = true
        replaceMotion()
        pending.removeAll()
        let task = worker
        task?.cancel()
        await task?.value
    }
    public func reconnect(_ id: UUID) { submit(["operation": "reconnect", "id": id.uuidString]) }
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
            state.error = "设备交互已关闭"
            return
        }
        guard (1...6).contains(id), value.isFinite, (-1...1).contains(value) else {
            state.error = "电机操作参数无效"
            return
        }
        motors[id] = value
        drain()
    }
    public func stopMotorControl() {
        replaceMotion()
        submit(["operation": "stopMotorControl"], priority: true)
    }
    public func openPage() { submit(["operation": "openPage"]) }
    public func closePage() {
        replaceMotion()
        submit(["operation": "closePage"], priority: true)
    }
    public func scan() { submit(["operation": "scan"]) }
    public func stopScan() { submit(["operation": "stopScan"], priority: true) }
    public func connect(_ id: UUID) { submit(["operation": "connect", "id": id.uuidString]) }
    public func disconnect() {
        replaceMotion()
        submit(["operation": "disconnect"], priority: true)
    }
    public func forget() {
        replaceMotion()
        submit(["operation": "forget"], priority: true)
    }
    public func openSystemSettings() { submit(["operation": "openSystemSettings"]) }
    private func replaceMotion() {
        fence = fenceStop()
        motors.removeAll()
        pending.removeAll { $0["operation"] == "preset" || $0["operation"] == "motorVelocity" }
    }
    private func submit(_ request: [String: String], priority: Bool = false) {
        guard !closed else {
            state.error = "设备交互已关闭"
            return
        }
        var request = request
        request["fence"] = fence.uuidString
        if pending.contains(request) { return }
        guard pending.count < 16 else {
            state.error = "设备操作过多，请稍后重试"
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
                        "fence": fence.uuidString,
                    ]
                } else {
                    break
                }
                do { try await perform(.init(kind: .device, parameters: request)) } catch {
                    if request["fence"] == fence.uuidString { state.error = "设备操作失败：" + error.localizedDescription }
                }
            }
        }
    }
}
