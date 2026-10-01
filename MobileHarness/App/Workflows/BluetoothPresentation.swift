import Foundation
import PlatformKit

/// App presentation policy, independent of packet admission and motion execution.
public enum BluetoothPresentation {
    public static func discoveryOrder(_ lhs: NexArmBluetoothDevice, _ rhs: NexArmBluetoothDevice) -> Bool {
        func preferred(_ name: String) -> Bool {
            name.lowercased().filter { $0.isLetter || $0.isNumber }.contains("nexarm")
        }
        if preferred(lhs.name) != preferred(rhs.name) { return preferred(lhs.name) }
        if lhs.rssi != rhs.rssi { return lhs.rssi > rhs.rssi }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    public static func deviceName(_ value: String) -> String? {
        guard let name = NexArmBluetoothDevice.discoveryName(advertised: value, cached: nil),
            name != "未命名设备"
        else { return nil }
        return name
    }
    public static func failure(_ value: NexArmBluetoothFailure) -> String {
        func title(_ step: NexArmBluetoothStep) -> String {
            switch step {
            case .connecting: "建立蓝牙连接"
            case .services: "发现设备服务"
            case .characteristics: "发现读写通道"
            case .notifications: "开启设备通知"
            case .writing: "发送设备指令"
            case .response: "等待设备回复"
            }
        }
        switch value {
        case .timeout(let step): return "\(title(step))超时"
        case .incompatibleService(let step): return "\(title(step))失败：蓝牙服务不兼容"
        case .native(let step, let domain, let code): return "\(title(step))失败（\(domain) \(code)）"
        case .disconnectUnconfirmed: return "蓝牙断开尚未确认，请关闭系统蓝牙后重试"
        }
    }
}
