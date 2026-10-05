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
    /// Latest native state only; no execution result or history is accepted.
    static func currentIssue(_ snapshot: NexArmBluetoothSnapshot) -> String? {
        if let fault = snapshot.failure { return String(failure(fault).prefix(512)) }
        if snapshot.phase == .connected && !snapshot.feedbackHealthy {
            return "暂未收到新的机械臂位置反馈"
        }
        return nil
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
        case .responseTimeout(let command, let expectedBytes, let receivedBytes):
            let query: String
            switch command {
            case 11: query = "读取机械臂位置"
            case 1: query = "读取固件版本"
            default: query = "设备查询"
            }
            let code = String(format: "0x%02X", command)
            return "\(query)回复超时（\(code)，期望载荷\(expectedBytes)字节，收到通知\(receivedBytes)字节）"
        case .timeout(let step): return "\(title(step))超时"
        case .incompatibleService(let step): return "\(title(step))失败：蓝牙服务不兼容"
        case .native(let step, let domain, let code): return "\(title(step))失败（\(domain) \(code)）"
        case .protocolViolation(.invalidPacket): return "蓝牙回包格式无效"
        case .protocolViolation(.receiveOverflow): return "蓝牙接收数据超过缓冲上限"
        case .requestInterrupted(let command):
            return "在途设备查询等待已终止（\(String(format: "0x%02X", command))），为隔离迟到回包已关闭旧连接"
        case .sendBlocked: return "蓝牙原生发送持续阻塞"
        case .disconnectUnconfirmed: return "蓝牙断开尚未确认，请关闭系统蓝牙后重试"
        }
    }
}
